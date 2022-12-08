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
import { TestConstants } from "./utils/TestConstants.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/DataTypes.sol";

interface DonorStrategy {
    function seriesId() external view returns (bytes6);
    function pool() external view returns (IPool);
}

abstract contract DeployedState is Test, TestConstants {
    using stdStorage for StdStorage;

    // YSDAI6MMS: 0x7ACFe277dEd15CabA6a8Da2972b1eb93fe1e2cCD
    // YSDAI6MJD: 0x1144e14E9B0AA9e181342c7e6E0a9BaDB4ceD295
    // YSUSDC6MMS: 0xFBc322415CBC532b54749E31979a803009516b5D
    // YSUSDC6MJD: 0x8e8D6aB093905C400D583EfD37fbeEB1ee1c0c39
    // YSETH6MMS: 0xcf30A5A994f9aCe5832e30C138C9697cda5E1247
    // YSETH6MJD: 0x831dF23f7278575BA0b136296a285600cD75d076
    // YSFRAX6MMS: 0x1565F539E96c4d440c38979dbc86Fd711C995DD6
    // YSFRAX6MJD: 0x47cC34188A2869dAA1cE821C8758AA8442715831

    // Pin to block 15741300 on 2022 September to March roll, so that the March pool exists and is initialized, but has no fyToken
    // Roll tx: https://etherscan.io/tx/0x26eb4d44a310d953db5bcf2fdd47350fadac8be60d0f7c00313a0f83c4ff8d6b
    // Pool: 0xbdc7bdae87dfe602e91fdd019c4c0334c38f6a46

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
        vm.createSelectFork(MAINNET, 15741300);

        seriesId = donorStrategy.seriesId();
        pool = donorStrategy.pool();
        fyToken = IFYToken(address(pool.fyToken()));
        baseToken = pool.baseToken();
        sharesToken = pool.sharesToken();

        // Strategy V2
        strategy = new Strategy("StrategyTest.t.sol", "test", fyToken);

        // The strategy needs to be given permission to initalize the pool
        // vm.prank(timelock);
        // AccessControl(address(pool)).grantRole(IPool.init.selector, address(strategy));

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

abstract contract DivestedState is DeployedState {
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

        vm.expectRevert(bytes("Not allowed in this state"));
        vm.prank(alice);
        strategy.init(hole);
    }

    function testMintDivested() public {
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

    function testBurnDivested() public {
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

    function testNoAuthInvest() public {
        console2.log("strategy.invest()");

        vm.expectRevert(bytes("Access denied"));
        vm.prank(bob);
        strategy.invest(pool);
    }

    function testNoMismatchedBaseInvest() public {
        console2.log("strategy.invest()");

        address DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        if (address(baseToken) == DAI) pool = IPool(0x1D2eB98042006B1bAFd10f33743CcbB573429daa); // FRAX
        else pool = IPool(0xBdc7Bdae87dfE602E91FDD019c4C0334C38f6A46); // DAI

        vm.expectRevert(bytes("Mismatched base"));
        vm.prank(alice);
        strategy.invest(pool);
    }
    
    function testNoFYTokenInvest() public {
        console2.log("strategy.invest()");

        pool = IPool(0x52956Fb3DC3361fd24713981917f2B6ef493DCcC); // DAI only

        vm.expectRevert(bytes("Only with no fyToken in the pool"));
        vm.prank(alice);
        strategy.invest(pool);
    }

    function testInvest() public {
        console2.log("strategy.invest()");

        uint256 strategyBaseFunds = baseToken.balanceOf(address(strategy));
        track("poolBaseBalance", pool.getBaseBalance());
        track("strategyPoolBalance", pool.balanceOf(address(strategy)));
        uint256 poolTotalSupplyBefore = pool.totalSupply();
        assertGt(strategyBaseFunds, 0);

        vm.prank(alice);
        strategy.invest(pool);

        // Base makes it to the pool
        assertTrackPlusApproxEqAbs("poolBaseBalance", strategyBaseFunds, pool.getBaseBalance(), 100); // We allow some room because Euler conversions might not be perfect

        // Strategy gets the pool increase in total supply
        assertTrackPlusEq(
            "strategyPoolBalance", pool.totalSupply() - poolTotalSupplyBefore, pool.balanceOf(address(strategy))
        );

        // State variables are set
        assertEq(address(strategy.fyToken()), address(fyToken));
        assertEq(uint256(strategy.maturity()), uint256(pool.maturity()));
        assertEq(address(strategy.pool()), address(pool));
        assertEq(uint256(strategy.state()), 2);
    } // --> Invested
}

abstract contract InvestedState is DivestedState {
    function setUp() public virtual override {
        super.setUp();
        vm.prank(alice);
        strategy.invest(pool);
    }
}

contract InvestedStateTest is InvestedState {
    function testmint() public {
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

    function testburn() public {
        console2.log("strategy.burn()");
        uint256 burnAmount = strategy.balanceOf(hole) / 2;
        assertGt(burnAmount, 0);

        // Let's dig some tokens out of the hole
        vm.prank(hole);
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

    function testEjectAuth() public {
        console2.log("strategy.eject()");

        vm.expectRevert(bytes("Access denied"));
        vm.prank(bob);
        strategy.eject();
    }

    function testEjectToDivested() public {
        console2.log("strategy.eject()");

        uint256 expectedBase = pool.balanceOf(address(strategy)) * pool.getBaseBalance() / pool.totalSupply();

        vm.prank(alice);
        strategy.eject();

        assertEq(pool.balanceOf(address(strategy)), 0);
        assertApproxEqAbs(baseToken.balanceOf(address(strategy)), expectedBase, 100);
        assertEq(strategy.cached(), baseToken.balanceOf(address(strategy)));
        assertEq(fyToken.balanceOf(address(strategy)), 0);
        assertEq(strategy.fyTokenCached(), 0);

        // State variables are reset
        assertEq(address(strategy.pool()), address(0));
        assertEq(uint256(strategy.state()), 1);
    } // --> Divested

    function testNoDivestBeforeMaturity() public {
        console2.log("strategy.divest()");

        vm.expectRevert(bytes("Only after maturity"));
        strategy.divest();
    }
}

abstract contract InvestedTiltedState is DivestedState {
    function setUp() public virtual override {
        super.setUp();
        vm.prank(alice);
        strategy.invest(pool);

        // Tilt the pool
        cash(IERC20(address(fyToken)), address(pool), pool.getBaseBalance() / 10);
        pool.sellFYToken(hole, 0);
    }
}

contract InvestedTiltedStateTest is InvestedTiltedState {

    function testEjectTiltedToDrained() public {
        console2.log("strategy.eject()");

        track("cached", strategy.cached());
        track("bobBaseTokens", baseToken.balanceOf(bob));
        track("strategySupply", strategy.totalSupply());

        uint256 poolExpected = pool.balanceOf(address(strategy));

        // Hacker!
        uint256 poolFYTokenBalance = fyToken.balanceOf(address(pool));
        vm.prank(address(pool));
        fyToken.transfer(hole, poolFYTokenBalance);

        vm.prank(alice);
        (uint256 baseObtained, uint256 fyTokenObtained) = strategy.eject();

        assertEq(pool.balanceOf(alice), poolExpected);
        assertEq(strategy.cached(), 0);
        assertEq(strategy.fyTokenCached(), 0);
        assertEq(uint256(strategy.state()), 4);
    }

    function testEjectTiltedToEjected() public {
        console2.log("strategy.eject()");

        uint256 expectedBase = pool.balanceOf(address(strategy)) * pool.getBaseBalance() / pool.totalSupply();
        uint256 expectedFYToken = pool.balanceOf(address(strategy)) * (pool.getFYTokenBalance() - pool.totalSupply()) / pool.totalSupply();

        vm.prank(alice);
        strategy.eject();

        assertEq(pool.balanceOf(address(strategy)), 0);
        assertApproxEqAbs(baseToken.balanceOf(address(strategy)), expectedBase, 100);
        assertEq(strategy.cached(), baseToken.balanceOf(address(strategy)));
        assertEq(fyToken.balanceOf(address(strategy)), expectedFYToken);
        assertEq(strategy.fyTokenCached(), fyToken.balanceOf(address(strategy)));

        // State variables are reset
        assertEq(address(strategy.pool()), address(0));
        assertEq(uint256(strategy.state()), 3);
    } // --> EjectedState
}

abstract contract EjectedState is InvestedState {
    function setUp() public virtual override {
        super.setUp();

        // Tilt the pool
        cash(IERC20(address(fyToken)), address(pool), pool.getBaseBalance() / 10);
        pool.sellFYToken(hole, 0);

        vm.prank(alice);
        strategy.eject();
    }
}

contract TestEjected is EjectedState {
    function testBuyFYToken() public {
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

abstract contract DrainedState is InvestedTiltedState {
    function setUp() public virtual override {
        super.setUp();

        // Hacker!
        uint256 poolFYTokenBalance = fyToken.balanceOf(address(pool));
        vm.prank(address(pool));
        fyToken.transfer(hole, poolFYTokenBalance);

        vm.prank(alice);
        (uint256 baseObtained, uint256 fyTokenObtained) = strategy.eject();
    }
}

contract TestDrained is DrainedState {

    function testNoRestartWithoutBase() public {
        console2.log("strategy.restart()");

        vm.expectRevert("No base to restart");
        vm.prank(alice);
        strategy.restart();

    }
    
    function testRestart() public {
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

contract TestInvestedAfterMaturity is InvestedAfterMaturity {
    function testDivest() public {
        console2.log("strategy.divest()");

        uint256 expectedBase = pool.balanceOf(address(strategy)) * pool.getBaseBalance() / pool.totalSupply();

        strategy.divest();

        assertEq(pool.balanceOf(address(strategy)), 0);
        assertApproxEqAbs(baseToken.balanceOf(address(strategy)), expectedBase, 100);
        assertEq(strategy.cached(), baseToken.balanceOf(address(strategy)));

        // State variables are reset
        assertEq(address(strategy.fyToken()), address(0));
        assertEq(uint256(strategy.maturity()), 0);
        assertEq(address(strategy.pool()), address(0));
    } // --> Divested
}

abstract contract InvestedTiltedAfterMaturity is InvestedTiltedState {
    function setUp() public virtual override {
        super.setUp();
        vm.warp(pool.maturity());
    }
}

contract InvestedTiltedAfterMaturityTest is InvestedTiltedAfterMaturity {
    function testDivestOnTiltedPoolAfterMaturity() public {
        console2.log("strategy.divest()");

        vm.warp(pool.maturity());

        uint256 expectedBase = pool.balanceOf(address(strategy)) * pool.getBaseBalance() / pool.totalSupply();
        uint256 expectedFYToken =
            pool.balanceOf(address(strategy)) * (pool.getFYTokenBalance() - pool.totalSupply()) / pool.totalSupply();
        assertGt(expectedFYToken, 0);

        strategy.divest();

        assertEq(pool.balanceOf(address(strategy)), 0);
        assertApproxEqAbs(baseToken.balanceOf(address(strategy)), expectedBase + expectedFYToken, 100);
        assertEq(strategy.cached(), baseToken.balanceOf(address(strategy)));
    } // --> Ejected
}

// }
// Deployed
//   mint(4) -> init -> Divested ✓ (Tested on StrategyMigrator.t.sol)
//   init -> Divested ✓
// Divested
//   mintDivested ✓
//   burnDivested ✓
//   invest -> Invested ✓
// Invested
//   mint ✓
//   burn ✓
//   eject -> Divested ✓
//   time passes -> InvestedAfterMaturity ✓
//   sell fyToken into pool -> InvestedTilted ✓
// InvestedTilted
//   eject -> Ejected ✓
//   eject -> Drained TODO
//   time passes -> InvestedTiltedAfterMaturity  ✓
// Ejected
//   buyFYToken -> Divested ✓
// Blocked
//   restart -> Divested TODO
// InvestedAfterMaturity
//   divest -> Divested ✓
//   eject -> Divested ✓
// InvestedTiltedAfterMaturity
//   divest -> Divested ✓
