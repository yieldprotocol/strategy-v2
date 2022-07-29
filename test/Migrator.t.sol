// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;
import "forge-std/Test.sol";
import "../contracts/Strategy.sol";
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
import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20Metadata.sol";

interface ICauldronAddSeries {
    function addSeries(bytes6, bytes6, IFYToken) external;
}

abstract contract ZeroTest is Test {

    uint32 maturity;
    IERC20Metadata baseToken;
    bytes6 baseId;
    IJoin baseJoin;
    IERC20Metadata sharesToken;
    IFYToken dstFYToken;
    IPool srcPool;
    Pool dstPool;
    IStrategy srcStrategy;
    Strategy dstStrategy;
    Exchange exchange;

    function setUp() public virtual {
        vm.createSelectFork('tenderly');

        maturity = uint32(srcStrategy.fyToken().maturity() + (3 * 30 * 24 * 60 * 60));
        baseId = srcStrategy.baseId();
        baseJoin = IJoin(srcStrategy.baseJoin());
        srcPool = srcStrategy.pool();

        baseToken = srcPool.baseToken();
        sharesToken = srcPool.sharesToken();
        (,,, uint16 g1Fee) = srcPool.getCache();

        dstFYToken = new FYToken(baseId, IOracle(address(0)), baseJoin, maturity, "", "");
        dstPool = new Pool(address(sharesToken), address(dstFYToken), srcPool.ts(), g1Fee);
        dstStrategy = new Strategy("", "", srcStrategy.ladle(), baseToken, baseId, address(baseJoin));
        exchange = new Exchange();

        // Warp to maturity of srcStrategy
        vm.warp(maturity + 1);

        // srcStrategy divests
        srcStrategy.endPool();

        // Add dst series
        bytes6 dstSeriesId = srcStrategy.seriesId();
        ICauldronAddSeries(address(srcStrategy.cauldron())).addSeries(dstSeriesId, srcStrategy.baseId(), dstFYToken);

        // Init dstPool
        // stdstore
        //     .target(address(baseToken))
        //     .sig(baseToken.balanceOf.selector)
        //     .with_key(address(dstPool))
        //     .checked_write(100 * 10**baseToken.decimals());
        // dstPool.init(address(0));

        // // Init dstStrategy
        // dstStrategy.setNextPool(address(dstPool));
        // stdstore
        //     .target(address(baseToken))
        //     .sig(baseToken.balanceOf.selector)
        //     .with_key(address(dstStrategy))
        //     .checked_write(100 * 10**baseToken.decimals());
        // dstStrategy.startPool(0, type(uint256).max);

        // --- STATES ---
        // Set migrator as next pool in srcStrategy
        // srcStrategy invests -> migrates
        // srcStrategy divests


        // AccessControl(address(pool1)).grantRole(
        //     bytes4(pool1.init.selector),
        //     ownerAcc
        // );
    }
}

contract BasicTest is ZeroTest {
//    function testMismatchBase() public {
//        vm.prank(ownerAcc);
//        vm.expectRevert(bytes("Mismatched base"));
//        strategy.setNextPool(IPool(address(badPool)), series1Id);
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