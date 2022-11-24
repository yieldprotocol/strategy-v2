// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Strategy, AccessControl} from "../contracts/Strategy.sol";
import {ICauldron} from "@yield-protocol/vault-v2/contracts/interfaces/ICauldron.sol";
import {ILadle} from "@yield-protocol/vault-v2/contracts/interfaces/ILadle.sol";
import {IFYToken} from "@yield-protocol/vault-v2/contracts/interfaces/IFYToken.sol";
import {IPool} from "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";
import {IERC20} from "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import {IERC20Metadata} from "@yield-protocol/utils-v2/contracts/token/IERC20Metadata.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/DataTypes.sol";

/// @dev This test harness tests that a deployed and invested strategy is functional.

abstract contract ZeroState is Test {
    using stdStorage for StdStorage;

    address deployer = address(bytes20(keccak256("deployer")));
    address alice = address(bytes20(keccak256("alice")));
    address bob = address(bytes20(keccak256("bob")));
    address hole = address(bytes20(keccak256("hole")));

    string network = "tenderly";

    address timelock;
    ICauldron cauldron;
    ILadle ladle;

    Strategy strategy;
    IPool pool;
    IFYToken fyToken;
    IERC20Metadata baseToken;
    IERC20Metadata sharesToken;

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

    function assertApproxGeAbs(uint256 a, uint256 b, uint256 delta) public {
        assertGe(a, b);
        assertApproxEqAbs(a, b, delta);
    }

    function assertTrackPlusApproxGeAbs(string memory id, uint256 plus, uint256 amount, uint256 delta) public {
        assertGe(tracked[id] + plus, amount);
        assertApproxEqAbs(tracked[id] + plus, amount, delta);
    }

    function assertTrackMinusApproxGeAbs(string memory id, uint256 minus, uint256 amount, uint256 delta) public {
        assertGe(tracked[id] - minus, amount);
        assertApproxEqAbs(tracked[id] - minus, amount, delta);
    }

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

    function equal(string memory a, string memory b) public returns(bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }

    function setUp() public virtual {
        vm.createSelectFork(network);

        if (equal(vm.envString("NETWORK"), "MAINNET")) {
            timelock = 0x3b870db67a45611CF4723d44487EAF398fAc51E3;
            cauldron = ICauldron(0xc88191F8cb8e6D4a668B047c1C8503432c3Ca867);
            ladle = ILadle(0x6cB18fF2A33e981D1e38A663Ca056c0a5265066A);
        } else if (equal(vm.envString("NETWORK"), "ARBITRUM")) {
            timelock = 0xd0a22827Aed2eF5198EbEc0093EA33A4CD641b6c;
            cauldron = ICauldron(0x23cc87FBEBDD67ccE167Fa9Ec6Ad3b7fE3892E30);
            ladle = ILadle(0x16E25cf364CeCC305590128335B8f327975d0560);
        }

        strategy = Strategy(vm.envAddress("STRATEGY"));
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

contract ZeroStateTest is ZeroState {
    function testHarnessIsInvested() public {
        assertTrue(strategy.state() == Strategy.State.INVESTED);
    } 
}

abstract contract InvestedState is ZeroState {

    function setUp() public virtual override {
        super.setUp();

        fyToken = strategy.fyToken();
        pool = strategy.pool();
        sharesToken = pool.sharesToken();

        vm.label(address(pool), "pool");
        vm.label(address(sharesToken), "sharesToken");
        vm.label(address(baseToken), "baseToken");
        vm.label(address(fyToken), "fyToken");
    } 
}


contract InvestedStateTest is InvestedState {

    function testHarnessMintInvested() public {
        console2.log("strategy.mint()");

        uint256 poolIn = pool.totalSupply() / 1000;
        assertGt(poolIn, 0);

        track("bobStrategyTokens", strategy.balanceOf(bob));
        track("cached", strategy.cached());
        track("strategyPoolBalance", pool.balanceOf(address(strategy)));
        uint256 expected = (poolIn * strategy.totalSupply()) / strategy.cached();

        cash(pool, address(strategy), poolIn);
        uint256 minted = strategy.mint(bob);

        assertEq(minted, expected);
        assertTrackPlusEq("bobStrategyTokens", minted, strategy.balanceOf(bob));
        assertTrackPlusEq("cached", poolIn, strategy.cached());
        assertTrackPlusEq("strategyPoolBalance", poolIn, pool.balanceOf(address(strategy)));
    }

    function testHarnessBurnInvested() public {
        console2.log("strategy.burn()");

        uint256 poolIn = pool.totalSupply() / 1000;
        cash(pool, address(strategy), poolIn);
        uint256 minted = strategy.mint(bob);
        uint256 burnAmount = minted / 2;
        vm.prank(bob);
        strategy.transfer(address(strategy), burnAmount);

        track("cached", strategy.cached());
        track("bobPoolTokens", pool.balanceOf(bob));
        track("strategySupply", strategy.totalSupply());
        uint256 poolExpected = (burnAmount * strategy.cached()) / strategy.totalSupply();

        uint256 poolObtained = strategy.burn(bob);

        assertEq(poolObtained, poolExpected);
        assertTrackPlusEq("bobPoolTokens", poolObtained, pool.balanceOf(bob));
        assertTrackMinusEq("cached", poolObtained, strategy.cached());
    }

    function testHarnessEjectAuthInvested() public {
        console2.log("strategy.eject()");

        vm.expectRevert(bytes("Access denied"));
        vm.prank(bob);
        strategy.eject();
    }

    function testHarnessEjectInvested() public {
        console2.log("strategy.eject()");

        uint256 expectedBase = pool.balanceOf(address(strategy)) * pool.getBaseBalance() / pool.totalSupply();

        vm.prank(alice);
        strategy.eject();

        assertTrue(strategy.state() == Strategy.State.DIVESTED ||strategy.state() == Strategy.State.EJECTED || strategy.state() == Strategy.State.DRAINED);
    } // --> Divested, Ejected or Drained

    function testHarnessNoDivestBeforeMaturityInvested() public {
        console2.log("strategy.divest()");

        vm.expectRevert(bytes("Only after maturity"));
        strategy.divest();
    }
}

abstract contract EjectedOrDrainedState is InvestedState {
    
    function setUp() public virtual override {
        super.setUp();

        vm.prank(alice);
        strategy.eject();
    }
}

contract TestEjectedOrDrained is EjectedOrDrainedState {
    function testHarnessBuyFYTokenEjected() public onlyEjected {
        console2.log("strategy.buyFYToken()");

        uint256 fyTokenAvailable = fyToken.balanceOf(address(strategy));
        track("aliceFYTokens", fyToken.balanceOf(alice));
        track("strategyFYToken", fyTokenAvailable);
        assertEq(baseToken.balanceOf(address(strategy)), strategy.cached());
        track("strategyBaseTokens", baseToken.balanceOf(address(strategy)));
        track("cached", strategy.cached());

        // initial buy - half of ejected fyToken balance
        uint initialBuy = fyTokenAvailable / 2;
        cash(baseToken, address(strategy), initialBuy);
        (uint256 bought,) = strategy.buyFYToken(alice, bob);

        assertEq(bought, initialBuy);
        assertTrackPlusEq("aliceFYTokens", initialBuy, fyToken.balanceOf(alice));
        assertTrackMinusEq("strategyFYToken", initialBuy, fyToken.balanceOf(address(strategy)));
        assertTrackPlusEq("strategyBaseTokens", initialBuy, baseToken.balanceOf(address(strategy)));
        assertTrackPlusEq("cached", initialBuy, strategy.cached());

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
        assertTrackPlusEq("cached", fyTokenAvailable, strategy.cached());

        // State variables are reset
        assertEq(address(strategy.fyToken()), address(0));
        assertEq(uint256(strategy.maturity()), 0);
        assertEq(address(strategy.pool()), address(0));
        assertEq(uint256(strategy.state()), 1);
    } // --> Divested

    function testHarnessRestartDrained() public onlyDrained {
        console2.log("strategy.restart()");
        uint256 restartAmount = 10 ** baseToken.decimals();

        cash(baseToken, address(strategy), restartAmount);

        vm.prank(alice);
        strategy.restart();

        // Test we are now divested
        assertEq(strategy.cached(), restartAmount);
        assertEq(uint256(strategy.state()), 1);
    } // --> Divested
}

abstract contract InvestedAfterMaturity is InvestedState {

    function setUp() public virtual override {
        super.setUp();

        vm.warp(pool.maturity());
    }
}

contract InvestedAfterMaturityTest is InvestedAfterMaturity {
    function testHarnessDivestAfterMaturity() public {
        console2.log("strategy.divest()");

        uint256 expectedBase = pool.balanceOf(address(strategy)) * pool.getBaseBalance() / pool.totalSupply();
        uint256 expectedFYToken =
            pool.balanceOf(address(strategy)) * (pool.getFYTokenBalance() - pool.totalSupply()) / pool.totalSupply();

        strategy.divest();

        assertEq(pool.balanceOf(address(strategy)), 0);
        assertApproxEqAbs(baseToken.balanceOf(address(strategy)), expectedBase + expectedFYToken, 100);
        assertEq(strategy.cached(), baseToken.balanceOf(address(strategy)));
    } // --> Divested
}

abstract contract DivestedState is InvestedAfterMaturity {

    function setUp() public virtual override {
        super.setUp();

        strategy.divest();
    }
}
contract DivestedStateTest is DivestedState {
    function testHarnessNoRepeatedInit() public {
        console2.log("strategy.init()");
        uint256 initAmount = 1e18;

        vm.expectRevert(bytes("Not allowed in this state"));
        vm.prank(alice);
        strategy.init(hole);
    }

    function testHarnessMintDivested() public {
        console2.log("strategy.mint()");
        uint256 baseIn = strategy.cached() / 1000;
        uint256 expectedMinted = (baseIn * strategy.totalSupply()) / strategy.cached();

        track("bobStrategyTokens", strategy.balanceOf(bob));
        track("cached", strategy.cached());

        cash(baseToken, address(strategy), baseIn);
        uint256 minted = strategy.mintDivested(bob);

        assertEq(minted, expectedMinted);
        assertTrackPlusEq("bobStrategyTokens", minted, strategy.balanceOf(bob));
        assertTrackPlusEq("cached", baseIn, strategy.cached());
    }

    function testHarnessBurnDivested() public {
        console2.log("strategy.burn()");
        // Let's get some tokens
        uint256 baseIn = strategy.cached() / 1000;
        cash(baseToken, address(strategy), baseIn);
        uint256 minted = strategy.mintDivested(bob);

        uint256 burnAmount = minted / 2;
        vm.prank(bob);
        strategy.transfer(address(strategy), burnAmount);
        uint256 expectedBaseObtained = burnAmount * strategy.cached() / strategy.totalSupply();
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


