// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;
import "forge-std/Test.sol";
import "../contracts/Strategy.sol";
import "../contracts/mocks/VaultMock.sol";
import "../contracts/mocks/BaseMock.sol";
import "../contracts/mocks/FYTokenMock.sol";
import "../contracts/mocks/ERC20Mock.sol";
import "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";
import "@yield-protocol/yieldspace-tv/src/Pool/Modules/PoolNonTv.sol";
import "@yield-protocol/yieldspace-tv/src/Pool/PoolErrors.sol";
import "@yield-protocol/yieldspace-tv/src/YieldMath.sol";
import "@yield-protocol/yieldspace-tv/src/YieldMathExtensions.sol";
import "@yield-protocol/yieldspace-tv/src/test/mocks/ERC4626TokenMock.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/DataTypes.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/ILadle.sol";
import "@yield-protocol/utils-v2/contracts/token/SafeERC20Namer.sol";
import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";

abstract contract ZeroTest is Test {
    using Math64x64 for int128;
    using Math64x64 for uint256;
    address ownerAcc;
    address user1Acc;
    address user2Acc;

    Strategy strategy;
    VaultMock vault;
    VaultMock vault2;
    BaseMock base;
    FYTokenMock fyTokenMock1;
    FYTokenMock fyTokenMock2;
    PoolNonTv pool1;
    PoolNonTv pool2;
    PoolNonTv badPool;
    int128 constant ONE = 0x10000000000000000;
    uint32 maturity1 = 1664550000;
    uint32 maturity2 = 1664550000;
    int128 ts = ONE.div(uint256(25 * 365 * 24 * 60 * 60 * 10).fromUInt());
    uint16 g1 = 9500;
    uint16 g2 = 9500;
    bytes6 baseId;
    bytes6 series1Id;
    bytes6 series2Id;

    // SafeERC20Namer safeERC20Namer;
    // YieldMath yieldMath;
    // YieldMathExtensions yieldMathExtensions;
    constructor() {
        ownerAcc = address(
            uint160(uint256(keccak256(abi.encodePacked(block.timestamp))))
        );
        user1Acc = address(
            uint160(uint256(keccak256(abi.encodePacked(block.timestamp + 2))))
        );
        user2Acc = address(
            uint160(uint256(keccak256(abi.encodePacked(block.timestamp + 3))))
        );
    }

    function setUp() public virtual {
        vault = new VaultMock();
        vault2 = new VaultMock();
        base = vault.base();
        baseId = vault.baseId();

        series1Id = vault.addSeries(maturity1);
        (IFYToken fyToken, , ) = vault.series(series1Id);
        fyTokenMock1 = FYTokenMock(address(fyToken));

        series2Id = vault.addSeries(maturity2);
        (IFYToken fyToken2, , ) = vault.series(series2Id);
        fyTokenMock2 = FYTokenMock(address(fyToken2));

        pool1 = new PoolNonTv(address(base), address(fyTokenMock1), ts, g1);
        pool2 = new PoolNonTv(address(base), address(fyTokenMock2), ts, g1);
        badPool = new PoolNonTv(
            address(vault2.base()),
            address(fyTokenMock2),
            ts,
            g1
        );

        AccessControl(address(pool1)).grantRole(
            bytes4(pool1.init.selector),
            ownerAcc
        );
        AccessControl(address(pool2)).grantRole(
            bytes4(pool1.init.selector),
            ownerAcc
        );
        base.mint(address(pool1), 1000000e18);
        base.mint(address(pool2), 1000000e18);
        vm.startPrank(ownerAcc);
        pool1.init(ownerAcc, ownerAcc);
        pool2.init(ownerAcc, ownerAcc);
        vm.stopPrank();

        fyTokenMock1.mint(address(pool1), 10000e18);
        fyTokenMock2.mint(address(pool2), 10000e18);
        pool1.sellFYToken(address(0), 0);
        pool2.sellFYToken(address(0), 0);
        strategy = new Strategy(
            "Strategy Token",
            "STR",
            ILadle(address(vault)),
            IERC20(address(base)),
            baseId,
            address(vault.joins(baseId))
        );

        AccessControl(address(strategy)).grantRole(
            bytes4(strategy.setNextPool.selector),
            ownerAcc
        );
        AccessControl(address(strategy)).grantRole(
            bytes4(strategy.startPool.selector),
            ownerAcc
        );
    }
}

contract BasicTest is ZeroTest {
    function testMismatchBase() public {
        vm.prank(ownerAcc);
        vm.expectRevert(bytes("Mismatched base"));
        strategy.setNextPool(IPool(address(badPool)), series1Id);
    }

    function testMismatchSeriesId() public {
        vm.prank(ownerAcc);
        vm.expectRevert(bytes("Mismatched seriesId"));
        strategy.setNextPool(IPool(address(pool2)), series1Id);
    }

    function testCantStartPool() public {
        vm.prank(ownerAcc);
        vm.expectRevert(bytes("Next pool not set"));
        strategy.startPool(0, type(uint256).max);
    }

    function testSetNextPool() public {
        vm.prank(ownerAcc);
        strategy.setNextPool(IPool(address(pool1)), series1Id);
        assertEq(address(strategy.nextPool()), address(pool1));
        assertEq(strategy.nextSeriesId(), series1Id);
    }
}

contract AfterNextPool is ZeroTest {
    function setUp() public override {
        super.setUp();
        vm.prank(ownerAcc);
        strategy.setNextPool(IPool(address(pool1)), series1Id);
    }

    function testNoFundsStart() public {
        vm.prank(ownerAcc);
        vm.expectRevert(bytes("No funds to start with"));
        strategy.startPool(0, type(uint256).max);
    }

    // function testSlippageDuringMint() public {
    //     base.mint(address(strategy), 1e18);
    //     vm.prank(ownerAcc);
    //     vm.expectRevert(PoolNonTv.SlippageDuringMint.selector);
    //     strategy.startPool(0, 0);
    // }

    function testStartNextPool() public {
        base.mint(address(strategy), 1e18);

        uint256 poolSupplyBefore = pool1.totalSupply();
        uint256 poolBaseBefore = base.balanceOf(address(pool1)); // Works because it's non-tv
        uint256 poolFYTokenBefore = fyTokenMock1.balanceOf(address(pool1));
        uint256 joinBaseBefore = base.balanceOf(address(vault)); // In the mock the vault is also the base join

        vm.prank(ownerAcc);
        strategy.startPool(0, type(uint256).max);

        // Sets the new variables
        assertEq(address(strategy.pool()), address(pool1));
        assertEq(address(strategy.fyToken()), address(fyTokenMock1));
        assertEq(strategy.seriesId(), series1Id);

        // Deletes the next* variables
        assertEq(address(strategy.nextPool()), address(0));
        assertEq(strategy.nextSeriesId(), bytes6(0));
        assertEq(address(strategy.nextPool()), address(0));
        assertEq(strategy.nextSeriesId(), bytes6(0));

        // Receives LP tokens
        assertEq(
            pool1.balanceOf(address(strategy)),
            pool1.totalSupply() - poolSupplyBefore
        );
        assertGt(pool1.balanceOf(address(strategy)), 0);

        // Didn't waste (much). All base are converted into shares, and any unused shares sent to the strategy contract,
        // where they will be locked.
        uint256 baseRemainder = pool1.sharesToken().balanceOf(
            address(strategy)
        );
        assertLt(baseRemainder, 100);

        // The Strategy used part of the base to mint fyToken
        uint256 joinBaseDelta = base.balanceOf(address(vault)) - joinBaseBefore;
        uint256 poolBaseDelta = base.balanceOf(address(pool1)) - poolBaseBefore;
        uint256 poolFYTokenDelta = fyTokenMock1.balanceOf(address(pool1)) -
            poolFYTokenBefore;
        assertGt(joinBaseDelta, 0); // FYToken was minted
        assertGt(poolBaseDelta, 0); // The pool received base
        assertEq(poolFYTokenDelta, joinBaseDelta); // The pool received fyToken
        assertEq(1e18, baseRemainder + joinBaseDelta + poolBaseDelta); // All the base is accounted for
    }
}

contract WithAPoolStarted is ZeroTest {
    function setUp() public override {
        super.setUp();
        vm.prank(ownerAcc);
        strategy.setNextPool(IPool(address(pool1)), series1Id);

        base.mint(address(strategy), 1000e18);

        vm.prank(ownerAcc);
        strategy.startPool(0, type(uint256).max);
    }

    function testUnableToStartAPoolWithCurrentActive() public {
        vm.prank(ownerAcc);
        vm.expectRevert(bytes("Pool selected"));
        strategy.startPool(0, type(uint256).max);
    }

    function testMintStrategyTokens() public {
        uint256 poolRatio = 1 +
            base.balanceOf(address(pool1)) / // Round up on the ratio
            fyTokenMock1.balanceOf(address(pool1));
        uint256 poolSupplyBefore = pool1.totalSupply();
        uint256 strategyReservesBefore = pool1.balanceOf(address(strategy));
        uint256 strategySupplyBefore = strategy.totalSupply();
        uint256 userStrategyBalanceBefore = strategy.balanceOf(ownerAcc);

        base.mint(address(pool1), 1e18 * poolRatio);
        fyTokenMock1.mint(address(pool1), 1e18);

        pool1.mint(address(strategy), address(0), 0, type(uint256).max);
        // vm.expectEmit();
        strategy.mint(ownerAcc);

        uint256 lpMinted = pool1.totalSupply() - poolSupplyBefore;
        uint256 strategyMinted = strategy.totalSupply() - strategySupplyBefore;

        assertEq(strategy.cached(), strategyReservesBefore + lpMinted);
        assertEq(
            strategy.balanceOf(ownerAcc) - userStrategyBalanceBefore,
            strategyMinted
        );
    }

    function testBurnStrategyTokens() public {
        uint256 strategyReservesBefore = pool1.balanceOf(address(strategy));
        uint256 strategySupplyBefore = strategy.totalSupply();
        uint256 strategyBalance = strategy.balanceOf(ownerAcc);
        uint256 strategyBurnt = strategyBalance / 2;

        vm.prank(ownerAcc);
        strategy.transfer(address(strategy), strategyBurnt);

        strategy.burn(user1Acc);

        uint256 lpObtained = strategyReservesBefore -
            pool1.balanceOf(address(strategy));
        assertEq(strategy.cached(), strategyReservesBefore - lpObtained);
        assertEq(pool1.balanceOf(user1Acc), lpObtained);

        assertEq(
            (1e18 * strategyBurnt) / strategySupplyBefore,
            (1e18 * lpObtained) / strategyReservesBefore
        );

        // Sanity check
        assertGt(lpObtained, 0);
    }

    function testEndPoolBeforeMaturity() public {
        vm.prank(ownerAcc);
        vm.expectRevert(bytes("Only after maturity"));
        strategy.endPool();
    }
}

contract AfterMaturityOfPool is ZeroTest {
    function setUp() public override {
        super.setUp();
        vm.prank(ownerAcc);
        strategy.setNextPool(IPool(address(pool1)), series1Id);

        base.mint(address(strategy), 1000e18);

        vm.prank(ownerAcc);
        strategy.startPool(0, type(uint256).max);

        vm.warp(maturity1);
    }

    function testEndPool() public {
        uint256 beforeBalance = base.balanceOf(address(strategy));
        // vm.expectEmit(bytes("PoolEnded"));

        uint256 balanceofpooltokens = strategy.pool().balanceOf(
            address(strategy)
        );

        (uint104 baseCached, uint104 fyTokenCached, , ) = strategy
            .pool()
            .getCache();
        uint256 sharesOut = (balanceofpooltokens * baseCached) /
            strategy.pool().totalSupply();
        uint256 realFYTokenCached_ = fyTokenCached -
            strategy.pool().totalSupply();
        uint256 fyTokenOut = (balanceofpooltokens * realFYTokenCached_) /
            strategy.pool().totalSupply();

        uint256 sharesBalance = baseCached - sharesOut;
        strategy.endPool();

        assertEq(address(strategy.pool()), address(0));
        assertEq(address(strategy.fyToken()), address(0));
        assertEq(strategy.seriesId(), bytes6(0));

        assertEq(strategy.cached(), 0);

        // Work out how many base and fyToken should be received from the strategy LP tokens,
        // and then verify that the strategy received base + fyToken in base
        assertEq(
            base.balanceOf(address(strategy)) - beforeBalance,
            baseCached - sharesBalance + fyTokenOut
        );
    }
}

contract NoActivePool is ZeroTest {
    function setUp() public override {
        super.setUp();
        vm.prank(ownerAcc);
        strategy.setNextPool(IPool(address(pool1)), series1Id);

        base.mint(address(strategy), 1000e18);

        vm.prank(ownerAcc);
        strategy.startPool(0, type(uint256).max);

        vm.warp(maturity1);
        strategy.endPool();
    }

    function testBurnsStrategyTokensForBase() public {
        uint256 strategyReservesBefore = base.balanceOf(address(strategy));
        uint256 strategySupplyBefore = strategy.totalSupply();
        uint256 strategyBalance = strategy.balanceOf(ownerAcc);
        uint256 strategyBurnt = strategyBalance / 2;

        vm.prank(ownerAcc);
        strategy.transfer(address(strategy), strategyBurnt);

        strategy.burnForBase(user1Acc);

        uint256 baseObtained = strategyReservesBefore -
            base.balanceOf(address(strategy));
        assertEq(base.balanceOf(user1Acc), baseObtained);

        // almostEqual(
        //     WAD.mul(strategyBurnt).div(strategySupplyBefore),
        //     WAD.mul(baseObtained).div(strategyReservesBefore),
        //     BigNumber.from(10)
        // )

        // Sanity check
        assertGt(baseObtained, 0);
    }
}
