// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;
import "forge-std/Test.sol";
import "../contracts/Strategy.sol";
import "../contracts/draft/Migrator.sol";
import "../contracts/draft/Exchange.sol";
import "../contracts/mocks/FYTokenMock.sol";
import "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";
import "@yield-protocol/yieldspace-tv/src/Pool/Modules/PoolNonTv.sol";
import "@yield-protocol/yieldspace-tv/src/Pool/PoolErrors.sol";
import "@yield-protocol/yieldspace-tv/src/YieldMath.sol";
import "@yield-protocol/yieldspace-tv/src/YieldMathExtensions.sol";
import "@yield-protocol/yieldspace-tv/src/test/mocks/ERC4626TokenMock.sol";
import "@yield-protocol/vault-v2/contracts/FYToken.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/DataTypes.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/ILadle.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/IJoin.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/IOracle.sol";
import "@yield-protocol/utils-v2/contracts/token/SafeERC20Namer.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20Metadata.sol";
import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";

interface ICauldronAddSeries {
    function addSeries(bytes6, bytes6, IFYToken) external;
}

abstract contract ZeroTest is Test {
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
    Strategy dstStrategy;
    uint32 srcMaturity;
    uint32 dstMaturity;
    IFYToken dstFYToken;
    bytes6 dstSeriesId;
    IPool srcPool;
    Pool dstPool;
    IERC20Metadata sharesToken;
    IERC20Metadata baseToken;
    bytes6 baseId;
    IJoin baseJoin;
    ICauldron cauldron;
    Exchange exchange;
    Migrator migrator;

    function setUp() public virtual {
        vm.createSelectFork('tenderly');
        vm.startPrank(timelock);

        srcMaturity = uint32(srcStrategy.fyToken().maturity());
        dstMaturity = srcMaturity + (3 * 30 * 24 * 60 * 60);
        baseId = srcStrategy.baseId();
        baseJoin = IJoin(srcStrategy.baseJoin());
        srcPool = srcStrategy.pool();
        cauldron = srcStrategy.cauldron();

        baseToken = srcPool.baseToken();
        sharesToken = srcPool.sharesToken();
        (,,, uint16 g1Fee) = srcPool.getCache();

        dstFYToken = new FYToken(baseId, IOracle(address(0)), baseJoin, dstMaturity, "", "");
        AccessControl(address(baseJoin)).grantRole(
            bytes4(baseJoin.join.selector),
            address(dstFYToken)
        );
        AccessControl(address(baseJoin)).grantRole(
            bytes4(baseJoin.exit.selector),
            address(dstFYToken)
        );
        
        dstPool = new PoolNonTv(address(baseToken), address(dstFYToken), srcPool.ts(), g1Fee);
        AccessControl(address(dstPool)).grantRole(
            bytes4(dstPool.init.selector),
            address(timelock)
        );

        dstStrategy = new Strategy("", "", srcStrategy.ladle(), baseToken, baseId, address(baseJoin));
        AccessControl(address(dstStrategy)).grantRole(
            bytes4(dstStrategy.setNextPool.selector),
            address(timelock)
        );
        AccessControl(address(dstStrategy)).grantRole(
            bytes4(dstStrategy.startPool.selector),
            address(timelock)
        );
        
        migrator = new Migrator(cauldron);
        AccessControl(address(migrator)).grantRole(
            bytes4(migrator.prepare.selector),
            address(timelock)
        );
        AccessControl(address(migrator)).grantRole(
            bytes4(migrator.mint.selector),
            address(srcStrategy)
        );

        exchange = new Exchange();
        AccessControl(address(exchange)).grantRole(
            bytes4(exchange.register.selector),
            address(migrator)
        );

        vm.label(address(srcStrategy), "srcStrategy");
        vm.label(address(dstStrategy), "dstStrategy");
        vm.label(address(dstFYToken), "dstFYToken");
        vm.label(address(srcPool), "srcPool");
        vm.label(address(dstPool), "dstPool");
        vm.label(address(sharesToken), "sharesToken");
        vm.label(address(baseToken), "baseToken");
        vm.label(address(baseJoin), "baseJoin");
        vm.label(address(cauldron), "cauldron");
        vm.label(address(exchange), "exchange");
        vm.label(address(migrator), "migrator");

        // Warp to maturity of srcStrategy
        vm.warp(srcMaturity + 1);

        // srcStrategy divests
        srcStrategy.endPool();

        // Add dst series
        dstSeriesId = bytes6(uint48(srcStrategy.seriesId()) + 1);
        ICauldronAddSeries(address(cauldron)).addSeries(dstSeriesId, srcStrategy.baseId(), dstFYToken);

        // Init migrator
        stdstore
            .target(address(baseToken))
            .sig(baseToken.balanceOf.selector)
            .with_key(address(migrator))
            .checked_write(1);

        // Init dstPool
        stdstore
            .target(address(baseToken))
            .sig(baseToken.balanceOf.selector)
            .with_key(address(dstPool))
            .checked_write(100 * 10**baseToken.decimals());
        dstPool.init(address(0));

        // Init dstStrategy
        dstStrategy.setNextPool(dstPool, dstSeriesId);
        stdstore
            .target(address(baseToken))
            .sig(baseToken.balanceOf.selector)
            .with_key(address(dstStrategy))
            .checked_write(100 * 10**baseToken.decimals());
        dstStrategy.startPool(0, type(uint256).max);

        vm.stopPrank();

        // --- STATES ---
        // srcStrategy invests -> migrates
        // srcStrategy divests
    }
}

contract BasicTest is ZeroTest {
    function testSetNextPool() public {
        console2.log("srcStrategy.setNextPool(IPool(address(migrator)), dstStrategy.seriesId())");
        vm.startPrank(timelock);
        migrator.prepare(dstStrategy.seriesId());
        srcStrategy.setNextPool(IPool(address(migrator)), dstStrategy.seriesId());
        srcStrategy.startPool(
            uint256(bytes32(bytes20(address(dstStrategy)))),
            uint256(bytes32(bytes20(address(exchange))))
        );
        vm.stopPrank();
    }
    
//    function testPrepare() public {
//        console2.log("migrator.prepare");
//        migrator.prepare(dstSeriesId);
//    }
//
//    function testMismatchSeriesId() public {
//        vm.prank(ownerAcc);
//        vm.expectRevert(bytes("Mismatched seriesId"));
//        strategy.setNextPool(IPool(address(pool2)), series1Id);
//    }
//
//    function testCantStartPool() public {
//        vm.prank(ownerAcc);
//        vm.expectRevert(bytes("Next pool not set"));
//        strategy.startPool(0, type(uint256).max);
//    }
//
//    function testSetNextPool() public {
//        vm.prank(ownerAcc);
//        strategy.setNextPool(IPool(address(pool1)), series1Id);
//        assertEq(address(strategy.nextPool()), address(pool1));
//        assertEq(strategy.nextSeriesId(), series1Id);
//    }
}

contract AfterNextPool is ZeroTest {
//    function setUp() public override {
//        // super.setUp();
//        // vm.prank(ownerAcc);
//        // strategy.setNextPool(IPool(address(pool1)), series1Id);
//    }
//
//    function testNoFundsStart() public {
//        vm.prank(ownerAcc);
//        vm.expectRevert(bytes("No funds to start with"));
//        strategy.startPool(0, type(uint256).max);
//    }
//
//    // function testSlippageDuringMint() public {
//    //     base.mint(address(strategy), 1e18);
//    //     vm.prank(ownerAcc);
//    //     vm.expectRevert(PoolNonTv.SlippageDuringMint.selector);
//    //     strategy.startPool(0, 0);
//    // }
//
//    function testStartNextPool() public {
//        base.mint(address(strategy), 1e18);
//
//        uint256 poolSupplyBefore = pool1.totalSupply();
//        uint256 poolBaseBefore = base.balanceOf(address(pool1)); // Works because it's non-tv
//        uint256 poolFYTokenBefore = fyTokenMock1.balanceOf(address(pool1));
//        uint256 joinBaseBefore = base.balanceOf(address(vault)); // In the mock the vault is also the base join
//
//        vm.prank(ownerAcc);
//        strategy.startPool(0, type(uint256).max);
//
//        // Sets the new variables
//        assertEq(address(strategy.pool()), address(pool1));
//        assertEq(address(strategy.fyToken()), address(fyTokenMock1));
//        assertEq(strategy.seriesId(), series1Id);
//
//        // Deletes the next* variables
//        assertEq(address(strategy.nextPool()), address(0));
//        assertEq(strategy.nextSeriesId(), bytes6(0));
//        assertEq(address(strategy.nextPool()), address(0));
//        assertEq(strategy.nextSeriesId(), bytes6(0));
//
//        // Receives LP tokens
//        assertEq(
//            pool1.balanceOf(address(strategy)),
//            pool1.totalSupply() - poolSupplyBefore
//        );
//        assertGt(pool1.balanceOf(address(strategy)), 0);
//
//        // Didn't waste (much). All base are converted into shares, and any unused shares sent to the strategy contract,
//        // where they will be locked.
//        uint256 baseRemainder = pool1.sharesToken().balanceOf(
//            address(strategy)
//        );
//        assertLt(baseRemainder, 100);
//
//        // The Strategy used part of the base to mint fyToken
//        uint256 joinBaseDelta = base.balanceOf(address(vault)) - joinBaseBefore;
//        uint256 poolBaseDelta = base.balanceOf(address(pool1)) - poolBaseBefore;
//        uint256 poolFYTokenDelta = fyTokenMock1.balanceOf(address(pool1)) -
//            poolFYTokenBefore;
//        assertGt(joinBaseDelta, 0); // FYToken was minted
//        assertGt(poolBaseDelta, 0); // The pool received base
//        assertEq(poolFYTokenDelta, joinBaseDelta); // The pool received fyToken
//        assertEq(1e18, baseRemainder + joinBaseDelta + poolBaseDelta); // All the base is accounted for
//    }
}