// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;
import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../contracts/Strategy.sol";
import "../contracts/interfaces/IStrategy.sol";
import "../contracts/deprecated/IStrategyV1.sol";
import "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/IFYToken.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/ILadle.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20Metadata.sol";

abstract contract ZeroState is Test {
    using stdStorage for StdStorage;

    // YSDAI6MMS: 0x7ACFe277dEd15CabA6a8Da2972b1eb93fe1e2cCD
    // YSDAI6MJD: 0x1144e14E9B0AA9e181342c7e6E0a9BaDB4ceD295
    // YSUSDC6MMS: 0xFBc322415CBC532b54749E31979a803009516b5D
    // YSUSDC6MJD: 0x8e8D6aB093905C400D583EfD37fbeEB1ee1c0c39
    // YSETH6MMS: 0xcf30A5A994f9aCe5832e30C138C9697cda5E1247
    // YSETH6MJD: 0x831dF23f7278575BA0b136296a285600cD75d076
    // YSFRAX6MMS: 0x1565F539E96c4d440c38979dbc86Fd711C995DD6
    // YSFRAX6MJD: 0x47cC34188A2869dAA1cE821C8758AA8442715831

    // TODO: Pin to block 15741300 on 2022 September to March roll, so that the March pool exists, is initialized and has no fyToken.
    // Roll tx: https://etherscan.io/tx/0x26eb4d44a310d953db5bcf2fdd47350fadac8be60d0f7c00313a0f83c4ff8d6b
    // Pool: 0xbdc7bdae87dfe602e91fdd019c4c0334c38f6a46
    // fyTokenReserves: 223191199910816266762851
    // totalSupply:     223191199910816266762851

    address timelock = 0x3b870db67a45611CF4723d44487EAF398fAc51E3;
    // We will warp to the December to June roll, and migrate the MJD strategy to a contract impersonating the March series.
    ILadle ladle = ILadle(0x6cB18fF2A33e981D1e38A663Ca056c0a5265066A);
    IStrategyV1 srcStrategy = IStrategyV1(0x1144e14E9B0AA9e181342c7e6E0a9BaDB4ceD295);
    address srcStrategyHolder = 0x9185Df15078547055604F5c0B02fc1C8D93594A5;
    IStrategyV1 donorStrategy = IStrategyV1(0x7ACFe277dEd15CabA6a8Da2972b1eb93fe1e2cCD); // We use this strategy as the source for the pool and fyToken addresses.
    IPool srcPool;
    IFYToken srcFYToken;
    bytes6 srcSeriesId;
    IPool dstPool;
    IFYToken dstFYToken;
    bytes6 dstSeriesId;

    IERC20Metadata sharesToken;
    IERC20Metadata baseToken;
    IFYToken fyToken;
    Strategy dstStrategy;

    function setUp() public virtual {
        vm.createSelectFork('mainnet', 15741300);

        srcSeriesId = srcStrategy.seriesId();
        srcPool = srcStrategy.pool();
        srcFYToken = IFYToken(address(srcPool.fyToken()));
        
        dstSeriesId = donorStrategy.seriesId();
        dstPool = donorStrategy.pool();
        dstFYToken = IFYToken(address(dstPool.fyToken()));

        baseToken = srcPool.baseToken();
        sharesToken = srcPool.sharesToken();

        dstStrategy = new Strategy("", "", baseToken.decimals(), ladle, dstFYToken);

        dstStrategy.grantRole(StrategyMigrator.mint.selector, address(srcStrategy));

        vm.label(address(srcStrategy), "srcStrategy");
        vm.label(address(srcPool), "srcPool");
        vm.label(address(sharesToken), "sharesToken");
        vm.label(address(baseToken), "baseToken");
        vm.label(address(fyToken), "fyToken");
        vm.label(address(dstStrategy), "dstStrategy");

        // Warp to maturity of srcFYToken
        vm.warp(uint32(srcFYToken.maturity()) + 1);

        // srcStrategy divests
        srcStrategy.endPool();

        // Init dstStrategy
        stdstore
            .target(address(baseToken))
            .sig(baseToken.balanceOf.selector)
            .with_key(address(dstStrategy))
            .checked_write(1);
    }
}

contract ZeroStateTest is ZeroState {
    function testSetNextPool() public {
        console2.log("srcStrategy.setNextPool(IPool(address(dstStrategy)), dstSeriesId)");
        vm.prank(timelock);
        srcStrategy.setNextPool(IPool(address(dstStrategy)), dstSeriesId);

        // Test the strategy can add the dstStrategy as the next pool
        assertEq(address(srcStrategy.nextPool()), address(dstStrategy));
        assertEq(srcStrategy.nextSeriesId(), dstSeriesId);
    }
}

abstract contract SetNextPoolState is ZeroState {
    function setUp() public override virtual {
        super.setUp();
        vm.prank(timelock);
        srcStrategy.setNextPool(IPool(address(dstStrategy)), dstSeriesId);
    }
}

contract SetNextPoolStateTest is SetNextPoolState {
    function testStartPool() public {
        console2.log("srcStrategy.startPool(,,,)");
        uint256 migratedBase = baseToken.balanceOf(address(srcStrategy));

        vm.prank(timelock);
        srcStrategy.startPool(0,0);

        // srcStrategy has no base
        assertEq(baseToken.balanceOf(address(srcStrategy)), 0);
        // dstStrategy has the base
        assertEq(baseToken.balanceOf(address(dstStrategy)), migratedBase + 1); // TODO: This might be because of Euler
    }
}

abstract contract MigratedState is SetNextPoolState {
    function setUp() public override virtual {
        super.setUp();
        vm.prank(timelock);
        srcStrategy.startPool(0,0);
    }
}

contract MigratedStateTest is MigratedState {
    function testBurn() public {
        console2.log("srcStrategy.burn()");
        uint256 srcStrategySupply = srcStrategy.totalSupply();
        uint256 dstStrategySupply = dstStrategy.totalSupply();
        uint256 srcStrategyHolderBalance = srcStrategy.balanceOf(srcStrategyHolder);
        uint256 expectedDstStrategyBalance = (srcStrategyHolderBalance * dstStrategySupply) / srcStrategySupply;
        assertGe(expectedDstStrategyBalance, 0);

        vm.prank(srcStrategyHolder);
        srcStrategy.transfer(address(srcStrategy), srcStrategyHolderBalance);
        srcStrategy.burn(srcStrategyHolder);

        // srcStrategyHolder has no srcStrategy tokens
        assertEq(srcStrategy.balanceOf(address(srcStrategyHolder)), 0);
        // srcStrategyHolder has the same proportion of dstStrategy than he had of srcStrategy
        assertEq(dstStrategy.balanceOf(address(srcStrategyHolder)), expectedDstStrategyBalance);
    }

    function testMint() public {
        console2.log("srcStrategy.mint()");
        uint256 srcStrategyHolderBalance = srcStrategy.balanceOf(srcStrategyHolder);
        assertGe(srcStrategyHolderBalance, 0);

        // We burn strategy v1 to get strategy v2 tokens
        vm.prank(srcStrategyHolder);
        srcStrategy.transfer(address(srcStrategy), srcStrategyHolderBalance);
        uint256 withdrawal = srcStrategy.burn(srcStrategyHolder);

        // Now we should be able to undo the burn using mint
        vm.prank(srcStrategyHolder);
        dstStrategy.transfer(address(srcStrategy), withdrawal);
        srcStrategy.mint(srcStrategyHolder);

        // srcStrategyHolder has no dstStrategy tokens
        assertEq(dstStrategy.balanceOf(address(srcStrategyHolder)), 0);
        // srcStrategyHolder has the same srcStrategy tokens he had before
        assertEq(srcStrategy.balanceOf(address(srcStrategyHolder)), srcStrategyHolderBalance - 1); // TODO: Do the conversions rounding down to get to this value
    }
}