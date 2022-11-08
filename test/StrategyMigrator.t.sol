// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;
import "forge-std/Test.sol";
import "../contracts/StrategyMigrator.sol";
import "../contracts/interfaces/IStrategy.sol";
import "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/IFYToken.sol";
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

    address timelock = 0x3b870db67a45611CF4723d44487EAF398fAc51E3;
    IStrategy srcStrategy = IStrategy(0x1144e14E9B0AA9e181342c7e6E0a9BaDB4ceD295);
    IPool srcPool;
    bytes6 srcSeriesId;
    IERC20Metadata sharesToken;
    IERC20Metadata baseToken;
    IFYToken fyToken;
    StrategyMigrator migrator;

    function setUp() public virtual {
        vm.createSelectFork('mainnet');

        srcPool = srcStrategy.pool();
        srcSeriesId = srcStrategy.seriesId();
        baseToken = srcPool.baseToken();
        fyToken = IFYToken(address(srcPool.fyToken()));
        sharesToken = srcPool.sharesToken();

        migrator = new StrategyMigrator(baseToken, fyToken);

        vm.label(address(srcStrategy), "srcStrategy");
        vm.label(address(srcPool), "srcPool");
        vm.label(address(sharesToken), "sharesToken");
        vm.label(address(baseToken), "baseToken");
        vm.label(address(fyToken), "fyToken");
        vm.label(address(migrator), "migrator");

        // Warp to maturity of srcStrategy
        vm.warp(uint32(srcStrategy.fyToken().maturity()) + 1);

        // srcStrategy divests
        srcStrategy.endPool();

        // Init migrator
        stdstore
            .target(address(baseToken))
            .sig(baseToken.balanceOf.selector)
            .with_key(address(migrator))
            .checked_write(1);
    }
}

contract ZeroStateTest is ZeroState {
    function testSetNextPool() public {
        console2.log("srcStrategy.setNextPool(IPool(address(migrator)), dstStrategy.seriesId())");
        vm.prank(timelock);
        srcStrategy.setNextPool(IPool(address(migrator)), srcSeriesId);

        // Test the strategy can add the migrator as the next pool
        assertEq(address(srcStrategy.nextPool()), address(migrator));
        assertEq(srcStrategy.nextSeriesId(), srcStrategy.seriesId());
    }
}

abstract contract SetNextPoolState is ZeroState {
    function setUp() public override virtual {
        super.setUp();
        vm.prank(timelock);
        srcStrategy.setNextPool(IPool(address(migrator)), srcStrategy.seriesId());
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
        // migrator has the base
        assertEq(baseToken.balanceOf(address(migrator)), migratedBase);
    }
}