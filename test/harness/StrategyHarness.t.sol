// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Strategy, AccessControl} from "../../src/Strategy.sol";
import {ICauldron} from "@yield-protocol/vault-v2/src/interfaces/ICauldron.sol";
import {ILadle} from "@yield-protocol/vault-v2/src/interfaces/ILadle.sol";
import {IFYToken} from "@yield-protocol/vault-v2/src/interfaces/IFYToken.sol";
import {IPool} from "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";
import {IERC20} from "@yield-protocol/utils-v2/src/token/IERC20.sol";
import {IERC20Metadata} from "@yield-protocol/utils-v2/src/token/IERC20Metadata.sol";
import { TestConstants } from "./../utils/TestConstants.sol";
import { TestExtensions } from "./../utils/TestExtensions.sol";
import "@yield-protocol/vault-v2/src/interfaces/DataTypes.sol";

/// @dev This test harness tests that a deployed and invested strategy is functional.

abstract contract ZeroState is Test, TestConstants, TestExtensions {
    using stdStorage for StdStorage;

    bool ci; // Skip the tests on CI

    address deployer = address(bytes20(keccak256("deployer")));
    address alice = address(bytes20(keccak256("alice")));
    address bob = address(bytes20(keccak256("bob")));
    address hole = address(bytes20(keccak256("hole")));

    address timelock;
    ICauldron cauldron;
    ILadle ladle;

    Strategy strategy;
    IPool pool;
    IFYToken fyToken;
    IERC20Metadata baseToken;
    IERC20Metadata sharesToken;


    modifier onlyEjected() {
        if (strategy.state() != Strategy.State.EJECTED) {
            console2.log("Strategy not ejected, skipping...");
            return;
        }
        _;
    }

    modifier onlyDrained() {
        if (strategy.state() != Strategy.State.DRAINED) {
            console2.log("Strategy not drained, skipping...");
            return;
        }
        _;
    }

    modifier skipOnCI() {
        if (ci == true) {
            console2.log("On CI, skipping...");
            return;
        }
        _;
    }

    function setUp() public virtual {
        if (!(ci = vm.envOr(CI, true))) {
            string memory rpc = vm.envOr(RPC, HARNESS);
            vm.createSelectFork(rpc);

            string memory network = vm.envOr(NETWORK, MAINNET);
            timelock = addresses[network][TIMELOCK];
            cauldron = ICauldron(addresses[network][LADLE]);
            ladle = ILadle(addresses[network][CAULDRON]);

            strategy = Strategy(vm.envAddress(STRATEGY));
            baseToken = IERC20Metadata(address(strategy.base()));

            // Alice has privileged roles
            vm.startPrank(timelock);
            strategy.grantRole(Strategy.init.selector, alice);
            strategy.grantRole(Strategy.invest.selector, alice);
            strategy.grantRole(Strategy.eject.selector, alice);
            strategy.grantRole(Strategy.restart.selector, alice);
            vm.stopPrank();

            vm.label(deployer, "deployer");
            vm.label(alice, "alice");
            vm.label(bob, "bob");
            vm.label(hole, "hole");
            vm.label(address(strategy), "strategy");
        }     
    }
}

contract ZeroStateTest is ZeroState {
    function testHarnessIsInvested() public skipOnCI skipOnCI {
        assertTrue(strategy.state() == Strategy.State.INVESTED);
    } 
}

abstract contract InvestedState is ZeroState {

    function setUp() public virtual override {
        super.setUp();

        if (!ci) {
            fyToken = strategy.fyToken();
            pool = strategy.pool();
            sharesToken = pool.sharesToken();

            vm.label(address(pool), "pool");
            vm.label(address(sharesToken), "sharesToken");
            vm.label(address(baseToken), "baseToken");
            vm.label(address(fyToken), "fyToken");
        }
    } 
}


contract InvestedStateTest is InvestedState {

    function testHarnessMintInvested() public skipOnCI {
        console2.log("strategy.mint()");

        uint256 poolIn = pool.totalSupply() / 1000;
        assertGt(poolIn, 0);

        track("bobStrategyTokens", strategy.balanceOf(bob));
        track("poolCached", strategy.poolCached());
        track("strategyPoolBalance", pool.balanceOf(address(strategy)));
        uint256 expected = (poolIn * strategy.totalSupply()) / strategy.poolCached();

        cash(pool, address(strategy), poolIn);
        uint256 minted = strategy.mint(bob);

        assertEq(minted, expected);
        assertTrackPlusEq("bobStrategyTokens", minted, strategy.balanceOf(bob));
        assertTrackPlusEq("poolCached", poolIn, strategy.poolCached());
        assertTrackPlusEq("strategyPoolBalance", poolIn, pool.balanceOf(address(strategy)));
    }

    function testHarnessBurnInvested() public skipOnCI {
        console2.log("strategy.burn()");

        uint256 poolIn = pool.totalSupply() / 1000;
        cash(pool, address(strategy), poolIn);
        uint256 minted = strategy.mint(bob);
        uint256 burnAmount = minted / 2;
        vm.prank(bob);
        strategy.transfer(address(strategy), burnAmount);

        track("poolCached", strategy.poolCached());
        track("bobPoolTokens", pool.balanceOf(bob));
        track("strategySupply", strategy.totalSupply());
        uint256 poolExpected = (burnAmount * strategy.poolCached()) / strategy.totalSupply();

        uint256 poolObtained = strategy.burn(bob);

        assertEq(poolObtained, poolExpected);
        assertTrackPlusEq("bobPoolTokens", poolObtained, pool.balanceOf(bob));
        assertTrackMinusEq("poolCached", poolObtained, strategy.poolCached());
    }

    function testHarnessEjectAuthInvested() public skipOnCI {
        console2.log("strategy.eject()");

        vm.expectRevert(bytes("Access denied"));
        vm.prank(bob);
        strategy.eject();
    }

    function testHarnessEjectInvested() public skipOnCI {
        console2.log("strategy.eject()");

        uint256 expectedBase = pool.balanceOf(address(strategy)) * pool.getBaseBalance() / pool.totalSupply();

        vm.prank(alice);
        strategy.eject();

        assertTrue(strategy.state() == Strategy.State.DIVESTED ||strategy.state() == Strategy.State.EJECTED || strategy.state() == Strategy.State.DRAINED);
    } // --> Divested, Ejected or Drained

    function testHarnessNoDivestBeforeMaturityInvested() public skipOnCI {
        console2.log("strategy.divest()");

        vm.expectRevert(bytes("Only after maturity"));
        strategy.divest();
    }
}

abstract contract EjectedOrDrainedState is InvestedState {
    
    function setUp() public virtual override {
        super.setUp();

        if (!ci) {
            vm.prank(alice);
            strategy.eject();
        }
    }
}

contract TestEjectedOrDrained is EjectedOrDrainedState {
    function testHarnessBuyFYTokenEjected() public skipOnCI onlyEjected {
        console2.log("strategy.buyFYToken()");

        uint256 fyTokenAvailable = fyToken.balanceOf(address(strategy));
        track("aliceFYTokens", fyToken.balanceOf(alice));
        track("strategyFYToken", fyTokenAvailable);
        assertEq(baseToken.balanceOf(address(strategy)), strategy.baseCached());
        track("strategyBaseTokens", baseToken.balanceOf(address(strategy)));
        track("baseCached", strategy.baseCached());

        // initial buy - half of ejected fyToken balance
        uint initialBuy = fyTokenAvailable / 2;
        cash(baseToken, address(strategy), initialBuy);
        (uint256 bought,) = strategy.buyFYToken(alice, bob);

        assertEq(bought, initialBuy);
        assertTrackPlusEq("aliceFYTokens", initialBuy, fyToken.balanceOf(alice));
        assertTrackMinusEq("strategyFYToken", initialBuy, fyToken.balanceOf(address(strategy)));
        assertTrackPlusEq("strategyBaseTokens", initialBuy, baseToken.balanceOf(address(strategy)));
        assertTrackPlusEq("baseCached", initialBuy, strategy.baseCached());

        // second buy - transfer in double the remaining fyToken and expect refund of base
        track("bobBaseTokens", baseToken.balanceOf(address(bob)));
        uint remainingFYToken = fyToken.balanceOf(address(strategy));
        uint secondBuy = remainingFYToken * 2;
        uint returned;
        cash(baseToken, address(strategy), secondBuy);
        (bought, returned) = strategy.buyFYToken(alice, bob);

        assertEq(bought, remainingFYToken);
        assertEq(returned, remainingFYToken);
        assertEq(initialBuy + remainingFYToken, fyTokenAvailable);
        assertTrackPlusEq("aliceFYTokens", fyTokenAvailable, fyToken.balanceOf(alice));
        assertTrackMinusEq("strategyFYToken", fyTokenAvailable, fyToken.balanceOf(address(strategy)));
        assertTrackPlusEq("strategyBaseTokens", fyTokenAvailable, baseToken.balanceOf(address(strategy)));
        assertTrackPlusEq("bobBaseTokens", secondBuy - remainingFYToken, baseToken.balanceOf(address(bob)));
        assertTrackPlusEq("baseCached", fyTokenAvailable, strategy.baseCached());

        // State variables are reset
        assertEq(address(strategy.fyToken()), address(0));
        assertEq(uint256(strategy.maturity()), 0);
        assertEq(address(strategy.pool()), address(0));
        assertEq(uint256(strategy.state()), 1);
    } // --> Divested

    function testHarnessRestartDrained() public skipOnCI onlyDrained {
        console2.log("strategy.restart()");
        uint256 restartAmount = 10 ** baseToken.decimals();

        cash(baseToken, address(strategy), restartAmount);

        vm.prank(alice);
        strategy.restart();

        // Test we are now divested
        assertEq(strategy.baseCached(), restartAmount);
        assertEq(uint256(strategy.state()), 1);
    } // --> Divested
}

abstract contract InvestedAfterMaturity is InvestedState {

    function setUp() public virtual override {
        super.setUp();

       if (!ci) vm.warp(pool.maturity());
    }
}

contract InvestedAfterMaturityTest is InvestedAfterMaturity {
    function testHarnessDivestAfterMaturity() public skipOnCI {
        console2.log("strategy.divest()");

        uint256 poolTokens = pool.balanceOf(address(strategy));
        uint256 poolSupply = pool.totalSupply();

        assertEq(baseToken.balanceOf(address(strategy)), 0);

        uint256 expectedBase = poolTokens * pool.getBaseBalance() / poolSupply;
        uint256 expectedFYToken = poolTokens * (pool.getFYTokenBalance() - poolSupply) / poolSupply;

        strategy.divest();

        assertEq(pool.balanceOf(address(strategy)), 0);
        assertApproxEqRel(baseToken.balanceOf(address(strategy)), expectedBase + expectedFYToken, 1e12); // 0.0001%, `getBaseBalance` is not exact
        assertEq(strategy.baseCached(), baseToken.balanceOf(address(strategy)));
    } // --> Divested
}

abstract contract DivestedState is InvestedAfterMaturity {

    function setUp() public virtual override {
        super.setUp();

        if (!ci) strategy.divest();
    }
}
contract DivestedStateTest is DivestedState {
    function testHarnessNoRepeatedInit() public skipOnCI {
        console2.log("strategy.init()");
        uint256 initAmount = 1e18;

        vm.expectRevert(bytes("Not allowed in this state"));
        vm.prank(alice);
        strategy.init(hole);
    }

    function testHarnessMintDivested() public skipOnCI {
        console2.log("strategy.mint()");
        uint256 baseIn = strategy.baseCached() / 1000;
        uint256 expectedMinted = (baseIn * strategy.totalSupply()) / strategy.baseCached();

        track("bobStrategyTokens", strategy.balanceOf(bob));
        track("baseCached", strategy.baseCached());

        cash(baseToken, address(strategy), baseIn);
        uint256 minted = strategy.mintDivested(bob);

        assertEq(minted, expectedMinted);
        assertTrackPlusEq("bobStrategyTokens", minted, strategy.balanceOf(bob));
        assertTrackPlusEq("baseCached", baseIn, strategy.baseCached());
    }

    function testHarnessBurnDivested() public skipOnCI {
        console2.log("strategy.burn()");
        // Let's get some tokens
        uint256 baseIn = strategy.baseCached() / 1000;
        cash(baseToken, address(strategy), baseIn);
        uint256 minted = strategy.mintDivested(bob);

        uint256 burnAmount = minted / 2;
        vm.prank(bob);
        strategy.transfer(address(strategy), burnAmount);
        uint256 expectedBaseObtained = burnAmount * strategy.baseCached() / strategy.totalSupply();
        assertGt(burnAmount, 0);

        track("aliceBaseTokens", baseToken.balanceOf(alice));

        // Burn, baby, burn
        uint256 baseObtained = strategy.burnDivested(alice);

        assertEq(baseObtained, expectedBaseObtained);
        assertTrackPlusEq("aliceBaseTokens", baseObtained, baseToken.balanceOf(alice));
    }
}

// Invested
//   mint ✓
//   burn ✓
//   eject -> Divested ✓
//   eject -> Ejected ✓
//   eject -> Drained ✓
//   time passes -> InvestedAfterMaturity  ✓
// Ejected
//   buyFYToken -> Divested ✓
// Drained
//   restart -> Divested ✓
// InvestedAfterMaturity
//   divest -> Divested ✓
//   eject -> Divested ✓
// Divested
//   mintDivested ✓
//   burnDivested ✓


