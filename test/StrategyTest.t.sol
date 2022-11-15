// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import { Strategy } from "../contracts/Strategy.sol";
import { ICauldron } from "@yield-protocol/vault-v2/contracts/interfaces/ICauldron.sol";
import { ILadle } from "@yield-protocol/vault-v2/contracts/interfaces/ILadle.sol";
import { IFYToken } from "@yield-protocol/vault-v2/contracts/interfaces/IFYToken.sol";
import { IPool } from "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";
import { IERC20 } from "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import { IERC20Metadata } from "@yield-protocol/utils-v2/contracts/token/IERC20Metadata.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/DataTypes.sol";

interface DonorStrategy {
    function seriesId() external view returns (bytes6);
    function pool() external view returns (IPool);
}

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

    address deployer = address(bytes20(keccak256("deployer")));
    address alice = address(bytes20(keccak256("alice")));
    address bob = address(bytes20(keccak256("bob")));
    address hole = address(bytes20(keccak256("hole")));

    address timelock = 0x3b870db67a45611CF4723d44487EAF398fAc51E3;
    ICauldron cauldron = ICauldron(0xc88191F8cb8e6D4a668B047c1C8503432c3Ca867);
    ILadle ladle = ILadle(0x6cB18fF2A33e981D1e38A663Ca056c0a5265066A);
    DonorStrategy donorStrategy = DonorStrategy(0x7ACFe277dEd15CabA6a8Da2972b1eb93fe1e2cCD); // We use this strategy as the source for the pool and fyToken addresses.

    bytes6 seriesId;
    IPool pool;
    IFYToken fyToken;
    IERC20Metadata baseToken;
    IERC20Metadata sharesToken;
    Strategy strategy;

    mapping(string => uint256) tracked;

    function cash(IERC20 token, address user, uint256 amount) public {
        uint256 start = token.balanceOf(user);
        deal(address(token), user, start + amount);
    }

    function track(string memory id, uint256 amount) public {
        tracked[id] = amount;
    }

    function assertTrackPlusEq(string memory id, uint256 plus, uint256 amount) public {
        assertEq(tracked[id] + plus, amount);
    }

    function assertTrackMinusEq(string memory id, uint256 minus, uint256 amount) public {
        assertEq(tracked[id] - minus, amount);
    }

    function assertTrackPlusApproxEqAbs(string memory id, uint256 plus, uint256 amount, uint256 delta) public {
        assertApproxEqAbs(tracked[id] + plus, amount, delta);
    }

    function assertTrackMinusApproxEqAbs(string memory id, uint256 minus, uint256 amount, uint256 delta) public {
        assertApproxEqAbs(tracked[id] - minus, amount, delta);
    }

    function setUp() public virtual {
        vm.createSelectFork("mainnet", 15741300);

        seriesId = donorStrategy.seriesId();
        pool = donorStrategy.pool();
        fyToken = IFYToken(address(pool.fyToken()));
        baseToken = pool.baseToken();
        sharesToken = pool.sharesToken();

        // Strategy V2
        strategy = new Strategy("StrategyTest.t.sol", "test", baseToken.decimals(), ladle, fyToken);

        // Alice has privileged roles
        strategy.grantRole(Strategy.init.selector, alice);
        strategy.grantRole(Strategy.invest.selector, alice);
        strategy.grantRole(Strategy.eject.selector, alice);

        vm.label(deployer, "deployer");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(hole, "hole");
        vm.label(address(strategy), "strategy");
        vm.label(address(pool), "pool");
        vm.label(address(sharesToken), "sharesToken");
        vm.label(address(baseToken), "baseToken");
        vm.label(address(fyToken), "fyToken");
    }
}

contract ZeroStateTest is ZeroState {
    function testInit() public {
        console2.log("strategy.init()");
        uint256 initAmount = 10 ** baseToken.decimals();

        cash(baseToken, address(strategy), initAmount);
        track("bobStrategyTokens", strategy.balanceOf(bob));

        vm.prank(alice);
        strategy.init(bob);

        // Test the strategy can add the dstStrategy as the next pool
        assertEq(strategy.cachedBase(), initAmount);
        assertEq(strategy.totalSupply(), strategy.balanceOf(bob));
        assertTrackPlusEq("bobStrategyTokens", initAmount, strategy.balanceOf(bob));
    }

    function testNoEmptyInit() public {
        console2.log("strategy.init()");

        vm.expectRevert(bytes("Not enough base in"));
        vm.prank(alice);
        strategy.init(hole);
    }

    function testNoEmptyInvest() public {
        console2.log("strategy.invest()");

        vm.expectRevert(bytes("Init Strategy first"));
        vm.prank(alice);
        strategy.invest(seriesId, 0, type(uint256).max);
    }
}

abstract contract DivestedState is ZeroState {
    function setUp() public virtual override {
        super.setUp();
        uint256 initAmount = 100 * 10 ** baseToken.decimals();
        cash(baseToken, address(strategy), initAmount);

        vm.prank(alice);
        strategy.init(hole);
    }
}

contract DivestedStateTest is DivestedState {
    function testNoRepeatedInit() public {
        console2.log("strategy.init()");
        uint256 initAmount = 1e18;

        vm.expectRevert(bytes("Already initialized"));
        vm.prank(alice);
        strategy.init(hole);
    }

    function testMintDivested() public {
        console2.log("strategy.mint()");
        uint256 baseIn = strategy.cachedBase() / 1000;
        uint256 expectedMinted = (baseIn * strategy.totalSupply()) / strategy.cachedBase();

        track("bobStrategyTokens", strategy.balanceOf(bob));
        track("cachedBase", strategy.cachedBase());

        cash(baseToken, address(strategy), baseIn);
        vm.prank(alice);
        uint256 minted = strategy.mint(bob, 0, type(uint256).max);

        assertEq(minted, expectedMinted);
        assertTrackPlusEq("bobStrategyTokens", minted, strategy.balanceOf(bob));
        assertTrackPlusEq("cachedBase", baseIn, strategy.cachedBase());
    }

    function testBurnDivested() public {
        console2.log("strategy.burn()");
        uint256 burnAmount = strategy.balanceOf(bob) / 2;
        assertGt(burnAmount, 0);

        track("aliceBaseTokens", baseToken.balanceOf(alice));
        vm.prank(bob);
        strategy.transfer(address(strategy), burnAmount);
        strategy.burn(alice, alice, 0);

        assertTrackPlusEq("aliceBaseTokens", burnAmount, baseToken.balanceOf(alice));
    }

    function testNoAuthInvest() public {
        console2.log("strategy.invest()");

        vm.expectRevert(bytes("Access denied"));
        vm.prank(bob);
        strategy.invest(seriesId, 0, type(uint256).max);
    }

    function testInvest() public {
        console2.log("strategy.invest()");

        uint256 strategyBaseFunds = baseToken.balanceOf(address(strategy));
        track("poolBaseBalance", pool.getBaseBalance());
        track("strategyPoolBalance", pool.balanceOf(address(strategy)));
        uint256 poolTotalSupplyBefore = pool.totalSupply();
        assertGt(strategyBaseFunds, 0);

        vm.prank(alice);
        strategy.invest(seriesId, 0, type(uint256).max);

        // A vault for the series is built
        bytes12 vaultId = strategy.vaultId();
        assertFalse(vaultId == bytes12(0));
        DataTypes.Vault memory vault = cauldron.vaults(vaultId);
        assertEq(vault.seriesId, strategy.seriesId());
        assertEq(vault.ilkId, strategy.baseId()); // The vaults that the strategy creates have the same asset for base and for ilk
        assertEq(vault.owner, address(strategy));
        
        // The vault balances stay at zero
        DataTypes.Balances memory balances = cauldron.balances(vaultId);
        assertEq(balances.ink, 0);
        assertEq(balances.art, 0);

        // Base makes it to the pool
        assertTrackPlusApproxEqAbs("poolBaseBalance", strategyBaseFunds, pool.getBaseBalance(), 100); // We allow some room because Euler conversions might not be perfect

        // Strategy gets the pool increase in total supply
        assertTrackPlusEq("strategyPoolBalance", pool.totalSupply() - poolTotalSupplyBefore, pool.balanceOf(address(strategy)));

        // State variables are set
        assertEq(strategy.seriesId(), seriesId);
        assertEq(address(strategy.fyToken()), address(fyToken));
        assertEq(uint256(strategy.maturity()), uint256(pool.maturity()));
        assertEq(address(strategy.pool()), address(pool));
    }

    function testInvestOnTiltedPool() public {
        console2.log("strategy.invest()");

        // Tilt the pool
        cash(IERC20(address(fyToken)), address(pool), pool.getBaseBalance() / 10);
        pool.sellFYToken(hole, 0);

        uint256 strategyBaseFunds = baseToken.balanceOf(address(strategy));
        assertGt(strategyBaseFunds, 0);
        
        track("poolBaseBalance", pool.getBaseBalance());
        track("strategyPoolBalance", pool.balanceOf(address(strategy)));
        uint256 poolTotalSupplyBefore = pool.totalSupply();
        uint256 poolFYTokenBalanceBefore = pool.getFYTokenBalance() - poolTotalSupplyBefore;


        vm.prank(alice);
        strategy.invest(seriesId, 0, type(uint256).max);
        // Reverts on `pool_.mint` -> `_mint` -> `_unwrapPreview` -> `IEToken(address(sharesToken)).convertBalanceToUnderlying(sharesInBaseDecimals * scaleFactor)`
        // https://github.com/yieldprotocol/yieldspace-tv/blob/fc7d8a387761f3f432a569bd56712cc3f91d73cd/src/Pool/Modules/PoolEuler.sol#L122
   
//        // Base makes it to the pool
//        assertTrackPlusApproxEqAbs("poolBaseBalance", strategyBaseFunds, pool.getBaseBalance(), 100); // We allow some room because Euler conversions might not be perfect
//
//        // FYToken makes it to the pool
//        uint256 poolFYTokenBalanceAfter = pool.getFYTokenBalance() - pool.totalSupply();
//        uint256 fyTokenToPool = poolFYTokenBalanceAfter - poolFYTokenBalanceBefore;
//        assertGt(fyTokenToPool, 0);
//
//        // The vault balances equal the fyToken added to the pool
//        DataTypes.Balances memory balances = cauldron.balances(vaultId);
//        assertEq(balances.ink, fyTokenToPool);
//        assertEq(balances.art, fyTokenToPool);
//
//        // Strategy gets the pool increase in total supply
//        assertTrackPlusEq("strategyPoolBalance", pool.totalSupply() - poolTotalSupplyBefore, pool.balanceOf(address(strategy)));
    }
}

abstract contract InvestedState is DivestedState {
    function setUp() public virtual override {
        super.setUp();
        vm.prank(alice);
        strategy.invest(seriesId, 0, type(uint256).max);
    }
}

contract InvestedStateTest is InvestedState {
    function testMintInvested() public {
        console2.log("strategy.mint()");
        uint256 baseIn = pool.getBaseBalance() / 1000;

        track("bobStrategyTokens", strategy.balanceOf(bob));
        track("cachedBase", strategy.cachedBase());
        track("poolBaseBalance", pool.getBaseBalance());
        track("strategyPoolBalance", pool.balanceOf(address(strategy)));
        uint256 poolMinted = (baseIn * pool.totalSupply()) / pool.getBaseBalance();

        cash(baseToken, address(strategy), baseIn);
        vm.prank(alice);
        uint256 minted = strategy.mint(bob, 0, type(uint256).max);

        assertEq(minted, baseIn);
        assertTrackPlusEq("bobStrategyTokens", baseIn, strategy.balanceOf(bob));
        assertTrackPlusEq("cachedBase", baseIn, strategy.cachedBase());
        assertTrackPlusApproxEqAbs("poolBaseBalance", baseIn, pool.getBaseBalance(), 100);
        assertTrackPlusApproxEqAbs("strategyPoolBalance", poolMinted, pool.balanceOf(address(strategy)), 100);
    }

    function testMintOnTiltedPool() public {}

    function testBurnInvested() public {
        console2.log("strategy.burn()");
        uint256 burnAmount = strategy.balanceOf(hole) / 2;
        assertGt(burnAmount, 0);

        // Let's dig some tokens out of the hole
        vm.prank(hole);
        strategy.transfer(bob, burnAmount);

        track("cachedBase", strategy.cachedBase());
        track("bobBaseTokens", baseToken.balanceOf(bob));
        track("strategySupply", strategy.totalSupply());
        uint256 baseExpected = (burnAmount * strategy.cachedBase()) / strategy.totalSupply();

        vm.prank(bob);
        strategy.transfer(address(strategy), burnAmount);
        uint256 baseObtained = strategy.burn(bob, bob, 0);

        assertTrackMinusEq("strategySupply", burnAmount, strategy.totalSupply());
        assertApproxEqAbs(baseExpected, baseObtained, 100);
        assertTrackPlusEq("bobBaseTokens", baseObtained, baseToken.balanceOf(bob));
        assertTrackMinusApproxEqAbs("cachedBase", baseExpected, strategy.totalSupply(), 100);
    }

    function testBurnOnTiltedPool() public {}

    // TODO: Move to its own state (InvestedTiltedMature)
    function testDivestOnTiltedPool() public {
        console2.log("strategy.divest()");

        // Tilt the pool
        cash(IERC20(address(fyToken)), address(pool), pool.getBaseBalance() / 10);
        pool.sellFYToken(hole, 0);

        vm.warp(pool.maturity());

        uint256 expectedBase = pool.balanceOf(address(strategy)) * pool.getBaseBalance() / pool.totalSupply();
        uint256 expectedFYToken = pool.balanceOf(address(strategy)) * (pool.getFYTokenBalance() - pool.totalSupply()) / pool.totalSupply();

        strategy.divest();

        assertEq(pool.balanceOf(address(strategy)), 0);
        assertApproxEqAbs(baseToken.balanceOf(address(strategy)), expectedBase + expectedFYToken, 100);
        assertEq(strategy.cachedBase(), baseToken.balanceOf(address(strategy)));
    }

    function testEjectAuth() public {
        console2.log("strategy.eject()");

        vm.expectRevert(bytes("Access denied"));
        vm.prank(bob);
        strategy.eject(0, type(uint256).max);
    }

    function testEject() public {
        console2.log("strategy.eject()");

        uint256 expectedBase = pool.balanceOf(address(strategy)) * pool.getBaseBalance() / pool.totalSupply();

        vm.prank(alice);
        strategy.eject(0, type(uint256).max);

        assertEq(pool.balanceOf(address(strategy)), 0);
        assertApproxEqAbs(baseToken.balanceOf(address(strategy)), expectedBase, 100);
        assertEq(strategy.cachedBase(), baseToken.balanceOf(address(strategy)));

        // State variables are reset
        assertEq(strategy.seriesId(), bytes6(0));
        assertEq(address(strategy.fyToken()), address(0));
        assertEq(uint256(strategy.maturity()), 0);
        assertEq(address(strategy.pool()), address(0));
        assertEq(bytes12(strategy.vaultId()), bytes12(0));
    }

    function testEjectOnTiltedPool() public {
        console2.log("strategy.divest()");

        // Tilt the pool
        cash(IERC20(address(fyToken)), address(pool), pool.getBaseBalance() / 10);
        pool.sellFYToken(hole, 0);

        uint256 expectedBase = pool.balanceOf(address(strategy)) * pool.getBaseBalance() / pool.totalSupply();
        uint256 expectedFYToken = pool.balanceOf(address(strategy)) * (pool.getFYTokenBalance() - pool.totalSupply()) / pool.totalSupply();

        vm.prank(alice);
        strategy.eject(0, type(uint256).max);

        assertEq(pool.balanceOf(address(strategy)), 0);
        assertApproxEqAbs(baseToken.balanceOf(address(strategy)), expectedBase, 100);
        assertEq(strategy.cachedBase(), baseToken.balanceOf(address(strategy)));

        (bytes6 ejectedSeriesId, uint256 ejectedCached) = strategy.ejected();
        assertEq(ejectedSeriesId, seriesId);
        assertApproxEqAbs(ejectedCached, expectedFYToken, 100);
        assertGt(ejectedCached, 0);
    }
}

abstract contract DivestedAndEjectedState is InvestedState {
    function setUp() public virtual override {
        super.setUp();

        // Tilt the pool
        cash(IERC20(address(fyToken)), address(pool), pool.getBaseBalance() / 10);
        pool.sellFYToken(hole, 0);

        vm.prank(alice);
        strategy.eject(0, type(uint256).max);
    }
}

contract TestDivestedAndEjected is DivestedAndEjectedState {
    function testMintDivestedAndEjected() public {
        console2.log("strategy.mint()");
        uint256 baseIn = strategy.cachedBase() / 1000;
        (, uint256 ejectedCached) = strategy.ejected();
        uint256 expectedMinted = (baseIn * strategy.totalSupply()) / (strategy.cachedBase() + ejectedCached);

        track("bobStrategyTokens", strategy.balanceOf(bob));
        track("cachedBase", strategy.cachedBase());

        cash(baseToken, address(strategy), baseIn);
        vm.prank(alice);
        uint256 minted = strategy.mint(bob, 0, type(uint256).max);

        assertEq(minted, expectedMinted);
        assertTrackPlusEq("bobStrategyTokens", minted, strategy.balanceOf(bob));
        assertTrackPlusEq("cachedBase", baseIn, strategy.cachedBase());
    }

    function testBurnDivestedAndEjected() public {
        console2.log("strategy.burn()");
        uint256 burnAmount = strategy.balanceOf(hole) / 2;
        assertGt(burnAmount, 0);

        // Let's dig some tokens out of the hole
        vm.prank(hole);
        strategy.transfer(bob, burnAmount);

        (, uint256 ejectedCached) = strategy.ejected();

        uint256 expectedBaseObtained = (burnAmount * strategy.totalSupply()) / strategy.cachedBase();
        uint256 expectedFYTokenObtained = (burnAmount * strategy.totalSupply()) / ejectedCached;

        track("aliceBaseTokens", baseToken.balanceOf(alice));
        track("bobFYTokens", fyToken.balanceOf(bob));
        vm.prank(bob);
        strategy.transfer(address(strategy), burnAmount);
        uint256 baseObtained = strategy.burn(alice, bob, 0);

//        assertTrackPlusEq("aliceBaseTokens", expectedBaseObtained, baseToken.balanceOf(alice));
//        assertTrackPlusEq("bobFYTokens", expectedFYTokenObtained, fyToken.balanceOf(bob));
        assertTrackMinusEq("cachedBase", baseObtained, strategy.cachedBase());
    }

    function testInvestDivestedAndEjected() public {
        // TODO: Failing
        console2.log("strategy.invest()");
        vm.prank(alice);
        strategy.invest(seriesId, 0, type(uint256).max);
    }
}

abstract contract InvestedAfterMaturity is InvestedState {
    function setUp() public virtual override {
        super.setUp();
        vm.warp(pool.maturity());
    }
}

contract TestInvestedAfterMaturity is InvestedAfterMaturity {
    function testDivest() public {
        console2.log("strategy.divest()");
        vm.warp(pool.maturity());

        uint256 expectedBase = pool.balanceOf(address(strategy)) * pool.getBaseBalance() / pool.totalSupply();

        strategy.divest();

        assertEq(pool.balanceOf(address(strategy)), 0);
        assertApproxEqAbs(baseToken.balanceOf(address(strategy)), expectedBase, 100);
        assertEq(strategy.cachedBase(), baseToken.balanceOf(address(strategy)));

        // State variables are reset
        assertEq(strategy.seriesId(), bytes6(0));
        assertEq(address(strategy.fyToken()), address(0));
        assertEq(uint256(strategy.maturity()), 0);
        assertEq(address(strategy.pool()), address(0));
        assertEq(bytes12(strategy.vaultId()), bytes12(0));
    }
}


// }
// Deployed
//   mint(4) -> init -> Divested ✓ (Tested on StrategyMigrator.t.sol)
//   init -> Divested ✓
// Divested
//   mintDivested ✓
//   burnDivested ✓
//   invest -> Invested ✓  TODO: Tilted pool
// Invested
//   mint ✓
//   burn ✓
//   eject -> DivestedAndEjected ✓
//   time passes -> InvestedAfterMaturity
//   sell fyToken into pool -> InvestedTilted
// InvestedTilted
//   mint ✓
//   burn ✓
//   eject -> DivestedAndEjected ✓
//   time passes -> InvestedTiltedAfterMaturity
// DivestedAndEjected
//   mintDivested  - ✓
//   burnDivested  - TODO: Failing
//   buyEjected - TODO: Code function
//   invest -> Invested
//   time passes -> DivestedAndEjectedAfterMaturity
// DivestedAndEjectedAfterMaturity
//   redeemEjected
// InvestedAfterMaturity
//   mint
//   burn
//   divest -> Divested ✓
// InvestedTiltedAfterMaturity
//   divest -> Divested ✓ TODO: Move test to state.
//   mint
//   burn

