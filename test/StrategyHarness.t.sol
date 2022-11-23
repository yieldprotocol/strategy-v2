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

abstract contract DeployedState is Test {
    using stdStorage for StdStorage;

    // YSDAI6MMS: 0x7ACFe277dEd15CabA6a8Da2972b1eb93fe1e2cCD
    // YSDAI6MJD: 0x1144e14E9B0AA9e181342c7e6E0a9BaDB4ceD295
    // YSUSDC6MMS: 0xFBc322415CBC532b54749E31979a803009516b5D
    // YSUSDC6MJD: 0x8e8D6aB093905C400D583EfD37fbeEB1ee1c0c39
    // YSETH6MMS: 0xcf30A5A994f9aCe5832e30C138C9697cda5E1247
    // YSETH6MJD: 0x831dF23f7278575BA0b136296a285600cD75d076
    // YSFRAX6MMS: 0x1565F539E96c4d440c38979dbc86Fd711C995DD6
    // YSFRAX6MJD: 0x47cC34188A2869dAA1cE821C8758AA8442715831

    address deployer = address(bytes20(keccak256("deployer")));
    address alice = address(bytes20(keccak256("alice")));
    address bob = address(bytes20(keccak256("bob")));
    address hole = address(bytes20(keccak256("hole")));

    address timelock = 0x3b870db67a45611CF4723d44487EAF398fAc51E3;
    ICauldron cauldron = ICauldron(0xc88191F8cb8e6D4a668B047c1C8503432c3Ca867);
    ILadle ladle = ILadle(0x6cB18fF2A33e981D1e38A663Ca056c0a5265066A);
    Strategy strategy = Strategy(0x7ACFe277dEd15CabA6a8Da2972b1eb93fe1e2cCD);

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

    function setUp() public virtual {
        vm.createSelectFork("mainnet");

        seriesId = strategy.seriesId();
        pool = strategy.pool();
        fyToken = strategy.fyToken();
        baseToken = pool.baseToken();
        sharesToken = pool.sharesToken();

        // Alice has privileged roles
        strategy.grantRole(Strategy.init.selector, alice);
        strategy.grantRole(Strategy.invest.selector, alice);
        strategy.grantRole(Strategy.eject.selector, alice);
        strategy.grantRole(Strategy.restart.selector, alice);

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

contract DeployedStateTest is DeployedState {
    function testInit() public {
        console2.log("strategy.init()");
        uint256 initAmount = 10 ** baseToken.decimals();

        cash(baseToken, address(strategy), initAmount);
        track("bobStrategyTokens", strategy.balanceOf(bob));

        vm.prank(alice);
        strategy.init(bob);

        // Test the strategy can add the dstStrategy as the next pool
        assertEq(strategy.cached(), initAmount);
        assertEq(strategy.totalSupply(), strategy.balanceOf(bob));
        assertTrackPlusEq("bobStrategyTokens", initAmount, strategy.balanceOf(bob));
        assertEq(uint256(strategy.state()), 1);
    } // --> Divested

    function testNoEmptyInit() public {
        console2.log("strategy.init()");

        vm.expectRevert(bytes("Not enough base in"));
        vm.prank(alice);
        strategy.init(hole);
    }

    function testNoEmptyInvest() public {
        console2.log("strategy.invest()");

        vm.expectRevert(bytes("Not allowed in this state"));
        vm.prank(alice);
        strategy.invest(pool);
    }

    function testBurnPoolTokensNotForYou() public {
        console2.log("strategy._burnPoolTokens()");

        vm.expectRevert(bytes("Unauthorized"));
        strategy._burnPoolTokens(pool, 0);
    }
}

/// @dev Invested is the most common state
abstract contract InvestedState {
    modifier onlyInvested() {
        if (strategy.state() != 2) {
            console2.log("Strategy not invested, skipping...");
            return;
        }
        _;
    }

    function setUp() public virtual override { }
}

contract InvestedStateTest is InvestedState {

    function testmint() public onlyInvested {
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

    function testburn() public onlyInvested {
        console2.log("strategy.burn()");

        uint256 poolIn = pool.totalSupply() / 1000;
        cash(pool, address(strategy), poolIn);
        uint256 minted = strategy.mint(bob);

        track("cached", strategy.cached());
        track("bobPoolTokens", pool.balanceOf(bob));
        track("strategySupply", strategy.totalSupply());
        uint256 poolExpected = (burnAmount * strategy.cached()) / strategy.totalSupply();

        uint256 poolObtained = strategy.burn(bob);

        assertEq(poolObtained, poolExpected);
        assertTrackPlusEq("bobPoolTokens", poolObtained, pool.balanceOf(bob));
        assertTrackMinusEq("cached", poolObtained, strategy.cached());
    }

    function testEjectAuth() public onlyInvested {
        console2.log("strategy.eject()");

        vm.expectRevert(bytes("Access denied"));
        vm.prank(bob);
        strategy.eject();
    }

    function testEject() public onlyInvested {
        console2.log("strategy.eject()");

        uint256 expectedBase = pool.balanceOf(address(strategy)) * pool.getBaseBalance() / pool.totalSupply();

        vm.prank(alice);
        strategy.eject();

        assertTrue(strategy.state() == 1 ||strategy.state() == 3 || strategy.state() == 4);
    } // --> Divested, Ejected or Drained

    function testNoDivestBeforeMaturity() public onlyInvested {
        console2.log("strategy.divest()");

        vm.expectRevert(bytes("Only after maturity"));
        strategy.divest();
    }
}

abstract contract EjectedState is InvestedState {
    modifier onlyEjected() {
        if (strategy.state() != 3) {
            console2.log("Strategy not ejected, skipping...");
            return;
        }
        _;
    }
    
    function setUp() public virtual override {
        super.setUp();

        vm.prank(alice);
        strategy.eject();
    }
}

contract TestEjected is EjectedState {
    function testBuyFYToken() public onlyEjected {
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
}

abstract contract DrainedState is EjectedState {
    modifier onlyDrained() {
        if (strategy.state() != 4) {
            console2.log("Strategy not drained, skipping...");
            return;
        }
        _;
    }

    function setUp() public virtual override {
        super.setUp();
    }
}

contract TestDrained is DrainedState {
    function testRestart() public onlyDrained {
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
    modifier onlyInvestedAfterMaturity() {
        if (strategy.state() != 2 && block.timestamp >= pool.maturity()) {
            console2.log("Strategy not invested after maturity, skipping...");
            return;
        }
        _;
    }

    function setUp() public virtual override {
        super.setUp();
        vm.warp(pool.maturity());
    }
}

contract InvestedAfterMaturityTest is InvestedAfterMaturity {
    function testDivestOnTiltedPoolAfterMaturity() public onlyInvestedAfterMaturity {
        console2.log("strategy.divest()");

        uint256 expectedBase = pool.balanceOf(address(strategy)) * pool.getBaseBalance() / pool.totalSupply();
        uint256 expectedFYToken =
            pool.balanceOf(address(strategy)) * (pool.getFYTokenBalance() - pool.totalSupply()) / pool.totalSupply();
        assertGt(expectedFYToken, 0);

        strategy.divest();

        assertEq(pool.balanceOf(address(strategy)), 0);
        assertApproxEqAbs(baseToken.balanceOf(address(strategy)), expectedBase + expectedFYToken, 100);
        assertEq(strategy.cached(), baseToken.balanceOf(address(strategy)));
    } // --> Divested
}

abstract contract DivestedState is InvestedAfterMaturity {
    modifier onlyDivested() {
        if (strategy.state() != 1) {
            console2.log("Strategy not divested, skipping...");
            return;
        }
        _;
    }

    function setUp() public virtual override {
        super.setUp();
        strategy.divest();
    }
}
contract DivestedStateTest is DivestedState {
    function testNoRepeatedInit() public onlyDivested {
        console2.log("strategy.init()");
        uint256 initAmount = 1e18;

        vm.expectRevert(bytes("Not allowed in this state"));
        vm.prank(alice);
        strategy.init(hole);
    }

    function testMintDivested() public onlyDivested {
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

    function testBurnDivested() public onlyDivested {
        console2.log("strategy.burn()");
        uint256 burnAmount = strategy.balanceOf(hole) / 2;
        assertGt(burnAmount, 0);

        // Let's dig some tokens out of the hole
        vm.prank(hole);
        strategy.transfer(address(strategy), burnAmount);
        assertGt(burnAmount, 0);

        track("aliceBaseTokens", baseToken.balanceOf(alice));
        uint256 baseObtained = strategy.burnDivested(alice);

        assertEq(baseObtained, burnAmount);
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


