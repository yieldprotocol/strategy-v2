// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../contracts/Strategy.sol";

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

    address timelock = 0x3b870db67a45611CF4723d44487EAF398fAc51E3;
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
        vm.label(address(strategy), "strategy");
        vm.label(address(pool), "pool");
        vm.label(address(sharesToken), "sharesToken");
        vm.label(address(baseToken), "baseToken");
        vm.label(address(fyToken), "fyToken");
    }
}

contract ZeroStateTest is ZeroState {
    function testInitStrat() public {
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
        strategy.init(bob);
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
        uint256 initAmount = 1_000_000 * 10 ** baseToken.decimals();
        cash(baseToken, address(strategy), initAmount);

        vm.prank(alice);
        strategy.init(bob);
    }
}

contract DivestedStateTest is DivestedState {
    function testNoRepeatedInit() public {
        console2.log("strategy.init()");
        uint256 initAmount = 1e18;

        vm.expectRevert(bytes("Already initialized"));
        vm.prank(alice);
        strategy.init(bob);
    }

    function testMintDivested() public {
        console2.log("strategy.mint()");
        uint256 mintAmount = 1000 * 10 ** baseToken.decimals();

        track("bobStrategyTokens", strategy.balanceOf(bob));
        cash(baseToken, address(strategy), mintAmount);
        vm.prank(alice);
        strategy.mint(bob, 0, type(uint256).max);

        assertTrackPlusEq("bobStrategyTokens", mintAmount, strategy.balanceOf(bob));
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

        vm.prank(alice);
        strategy.invest(seriesId, 0, type(uint256).max);

        //TODO: check state changes
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
        uint256 mintAmount = 1000 * 10 ** baseToken.decimals();

        track("bobStrategyTokens", strategy.balanceOf(bob));
        cash(baseToken, address(strategy), mintAmount);
        vm.prank(alice);
        // TODO: This fails because at this point the cached balance is higher than the actual balance
        strategy.mint(bob, 0, type(uint256).max);

        assertTrackPlusEq("bobStrategyTokens", mintAmount, strategy.balanceOf(bob));
        console.log(
            "+ + file: StrategyTest.t.sol + line 198 + testMintInvested + strategy.balanceOf(bob)",
            strategy.balanceOf(bob)
        );
    }

    function testBurnInvested() public {
        console2.log("strategy.burn()");
        uint256 burnAmount = strategy.balanceOf(bob) / 2;
        assertGt(burnAmount, 0);

        track("bobStrategyTokens", strategy.balanceOf(bob));
        track("aliceBaseTokens", baseToken.balanceOf(alice));

        console.log(strategy.balanceOf(bob));

        vm.prank(bob);
        strategy.transfer(address(strategy), burnAmount);
        strategy.burn(alice, alice, 0);

        assertTrackMinusEq("bobStrategyTokens", burnAmount, strategy.balanceOf(bob));
        assertTrackPlusEq("aliceBaseTokens", 500050153532937642368309, baseToken.balanceOf(alice));
    }

    function testEjectInvested() public {
        console2.log("strategy.eject()");
        uint256 ejectAmount = strategy.balanceOf(bob) / 2;
        assertGt(ejectAmount, 0);

        assertGt(pool.balanceOf(address(strategy)), 0);

        vm.prank(alice);
        strategy.eject(0, type(uint256).max);

        assertEq(pool.balanceOf(address(strategy)), 0);

        //TODO: check other state changes
    }
}

abstract contract DivestedAndEjectedState is InvestedState {
    // not sure if this is correct, the state chart says:
    // Invested
    //   eject -> DivestedAndEjected

    function setUp() public virtual override {
        super.setUp();
        vm.prank(alice);
        strategy.eject(0, type(uint256).max);
    }
}

contract TestDivestedAndEjected is DivestedAndEjectedState {
    function testMintDivestedAndEjected() public {
        console2.log("strategy.mint()");
        uint256 mintAmount = 1000 * 10 ** baseToken.decimals();

        track("bobStrategyTokens", strategy.balanceOf(bob));
        cash(baseToken, address(strategy), mintAmount);
        vm.prank(alice);

        // TODO: This fails because at this point the cached balance is higher than the actual balance
        strategy.mint(bob, 0, type(uint256).max);

        assertTrackPlusEq("bobStrategyTokens", mintAmount, strategy.balanceOf(bob));
    }

    function testBurnDivestedAndEjected() public {
        // TODO: Failing
        console2.log("strategy.burn()");
        uint256 burnAmount = strategy.balanceOf(bob) / 2;
        assertGt(burnAmount, 0);

        vm.prank(bob);
        strategy.transfer(address(strategy), burnAmount);
        strategy.burn(alice, alice, 0);

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
    function testDivestInvestedAfterMaturity() public {
        console2.log("strategy.divest()");
        vm.prank(bob);
        strategy.divest();
        //TODO: Checkl state changes
    }
}


// }
// Deployed
//   mint(4) -> init -> Divested ✓
//   init -> Divested ???
// Divested
//   mintDivested ✓
//   burnDivested ✓
//   invest -> Invested ✓  TODO: Check state changes
// Invested
//   mint(3) - TODO: failing
//   burn ✓
//   eject -> DivestedAndEjected ✓  TODO: Is it correct that this represents the state of DivestedAndEjected? - The contract will be divested and will have ejected fyToken -> DivestedAndEjected
//   time passes -> InvestedAfterMaturity  TODO: Is there something to test here? - Just a state transition, no test
// DivestedAndEjected
//   mintDivested  - TODO: failing
//   burnDivested  - TODO: failing
//   invest -> Invested  - TODO: failing
//   time passes -> DivestedAndEjectedAfterMaturityOfEjected TODO: Is there something to test here? - Just a state transition, no test
// InvestedAfterMaturity
//   divest -> Divested ✓ TODO: Check state changes

// InvestedAndEjected
//   same as Invested
//   time passes -> InvestedAfterMaturityAndEjected
//   time passes -> InvestedAndAfterMaturityOfEjected
//   time passes -> InvestedAfterMaturityAndAfterMaturityOfEjected
// InvestedAfterMaturityAndEjected
//   divest -> DivestedAndEjected
//   time passes -> InvestedAfterMaturityAndAfterMaturityOfEjected

// DivestedAndEjectedAfterMaturityOfEjected
//   same as DivestedAndEjected
//   redeemEjected -> Divested
// InvestedAfterMaturityAndEjected
//   same as InvestedAfterMaturity
// InvestedAndAfterMaturityOfEjected
//   same as Invested
//   redeemEjected -> Invested
// InvestedAfterMaturityAndAfterMaturityOfEjected
//   same as InvestedAfterMaturity
//   redeemEjected -> InvestedAfterMaturity
