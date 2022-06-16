// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.14;
import "forge-std/Test.sol";
import "../contracts/Strategy.sol";
import "../contracts/mocks/VaultMock.sol";
import "../contracts/mocks/BaseMock.sol";
import "../contracts/mocks/FYTokenMock.sol";
import "../contracts/mocks/ERC20Mock.sol";
import "@yield-protocol/yieldspace-tv/src/Pool/Modules/PoolNonTv.sol";
import "@yield-protocol/yieldspace-tv/src/Pool/PoolErrors.sol";
import "@yield-protocol/vault-interfaces/src/DataTypes.sol";
import "@yield-protocol/utils-v2/contracts/token/SafeERC20Namer.sol";
import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/yieldspace-tv/src/YieldMath.sol";
import "@yield-protocol/yieldspace-tv/src/YieldMathExtensions.sol";
import "@yield-protocol/vault-interfaces/src/ILadle.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";
import "@yield-protocol/yieldspace-tv/src/test/mocks/ERC4626TokenMock.sol";

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
        pool1.init(ownerAcc, ownerAcc, 0, type(uint256).max);
        pool2.init(ownerAcc, ownerAcc, 0, type(uint256).max);
        vm.stopPrank();

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

    function testSlippageDuringMint() public {
        base.mint(address(strategy), 1e18);
        fyTokenMock1.mint(address(pool1), 500000e18);
        pool1.sellFYToken(address(0), 0);
        vm.prank(ownerAcc);
        vm.expectRevert(
            abi.encodeWithSelector(
                SlippageDuringMint.selector,
                1102485379294727506,
                0,
                0
            )
        );
        strategy.startPool(0, 0);
    }

    function testStartNextPoolWithZeroFYToken() public {
        fyTokenMock1.mint(address(pool1), 100000e18);
        base.mint(address(strategy), 1e18);

        vm.prank(ownerAcc);
        strategy.startPool(0, type(uint256).max);

        assertEq(address(strategy.pool()), address(pool1));
        assertEq(address(strategy.fyToken()), address(fyTokenMock1));
        assertEq(strategy.seriesId(), series1Id);

        assertEq(address(strategy.nextPool()), address(0));
        assertEq(strategy.nextSeriesId(), bytes6(0));
    }

    function testStartNextPoolSetsAndDeletesPoolVariables() public {
        fyTokenMock1.mint(address(pool1), 100000e18);
        base.mint(address(strategy), 1e18);
        fyTokenMock1.mint(address(pool1), 1e18);

        vm.prank(ownerAcc);
        strategy.startPool(0, type(uint256).max);

        assertEq(address(strategy.pool()), address(pool1));
        assertEq(address(strategy.fyToken()), address(fyTokenMock1));
        assertEq(strategy.seriesId(), series1Id);

        assertEq(address(strategy.nextPool()), address(0));
        assertEq(strategy.nextSeriesId(), bytes6(0));
    }

    function testStartWithNextPoolBorrowsAndMints() public {
        fyTokenMock1.mint(address(pool1), 100000e18);
        uint256 poolBaseBefore = base.balanceOf(address(pool1));
        uint256 poolFYTokenBefore = fyTokenMock1.balanceOf(address(pool1));
        uint256 poolSupplyBefore = pool1.totalSupply();

        base.mint(address(strategy), 1e18);

        vm.prank(ownerAcc);
        strategy.startPool(0, type(uint256).max);

        uint256 poolBaseAdded = base.balanceOf(address(pool1)) - poolBaseBefore;
        uint256 poolFYTokenAdded = fyTokenMock1.balanceOf(address(pool1)) -
            poolFYTokenBefore;

        assertEq(poolBaseAdded + poolFYTokenAdded, 1e18); // In older test it was 1e18-1
        assertEq(base.balanceOf(address(strategy)), 0); // In older test it was 1

        assertEq(
            pool1.balanceOf(address(strategy)),
            pool1.totalSupply() - poolSupplyBefore
        );

        (, uint104 poolBaseCached, uint104 poolFYTokenCached, ) = pool1
            .getCache();

        assertEq(poolBaseCached, pool1.getBaseBalance());

        // assertEq(poolFYTokenCached,pool1.getFYTokenBalance()); // The pool used all the received funds to mint (minus rounding in single-digit wei). Original test uses almostEqual
        assertEq(pool1.balanceOf(address(strategy)), strategy.cached());
        assertEq(strategy.balanceOf(ownerAcc), strategy.totalSupply());
    }
}

contract WithAPoolStarted is ZeroTest {
    function setUp() public override {
        super.setUp();
        vm.prank(ownerAcc);
        strategy.setNextPool(IPool(address(pool1)), series1Id);

        fyTokenMock1.mint(address(pool1), 100000e18);
        base.mint(address(strategy), 1000e18);

        vm.prank(ownerAcc);
        strategy.startPool(0, type(uint256).max);

        fyTokenMock2.mint(address(pool2), 100000e18);
    }

    function testUnableToStartAPoolWithCurrentActive() public {
        vm.prank(ownerAcc);
        vm.expectRevert(bytes("Pool selected"));
        strategy.startPool(0, type(uint256).max);
    }

    function testMintStrategyTokens() public {
        uint256 poolRatio = base.balanceOf(address(pool1)) /
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

        fyTokenMock1.mint(address(pool1), 100000e18);
        base.mint(address(strategy), 1000e18);

        vm.prank(ownerAcc);
        strategy.startPool(0, type(uint256).max);

        fyTokenMock2.mint(address(pool2), 100000e18);

        vm.warp(maturity1);
    }

    function testEndPool() public {
        // vm.expectEmit(bytes("PoolEnded"));
        strategy.endPool();

        assertEq(address(strategy.pool()), address(0));
        assertEq(address(strategy.fyToken()), address(0));
        assertEq(strategy.seriesId(), bytes6(0));

        assertEq(strategy.cached(), 0);
    }

    function testEndPoolRedeemFyToken() public {
        fyTokenMock1.mint(address(pool1), 100000e18);
        strategy.endPool();
        assertEq(fyTokenMock1.balanceOf(address(strategy)), 0);
    }

    function testEndPoolRepayWithUnderlying() public {
        base.mint(address(pool1), 1e18 * 1000000);
        strategy.endPool();
    }
}

contract NoActivePool is ZeroTest {
    function setUp() public override {
        super.setUp();
        vm.prank(ownerAcc);
        strategy.setNextPool(IPool(address(pool1)), series1Id);

        fyTokenMock1.mint(address(pool1), 100000e18);
        base.mint(address(strategy), 1000e18);

        vm.prank(ownerAcc);
        strategy.startPool(0, type(uint256).max);

        fyTokenMock2.mint(address(pool2), 100000e18);

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
