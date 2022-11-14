// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;
import "forge-std/Test.sol";
import "../contracts/Strategy.sol";

interface DonorStrategy {
        function seriesId() external view returns(bytes6);
        function pool() external view returns(IPool);
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

    address deployer = address(0);
    address alice = address(1);
    address bob = address(2);

    ILadle ladle = ILadle(0x6cB18fF2A33e981D1e38A663Ca056c0a5265066A);
    DonorStrategy donorStrategy = DonorStrategy(0x7ACFe277dEd15CabA6a8Da2972b1eb93fe1e2cCD); // We use this strategy as the source for the pool and fyToken addresses.
    
    bytes6 seriesId;
    IPool pool;
    IFYToken fyToken;
    IERC20Metadata baseToken;
    IERC20Metadata sharesToken;
    Strategy strategy;

    mapping (string => uint256) tracked;

    function cash(IERC20 token, address user, uint256 amount) public {
        stdstore
            .target(address(token))
            .sig(token.balanceOf.selector)
            .with_key(user)
            .checked_write(amount);
    }

    function track(string memory id, uint256 amount) public {
        tracked[id] = amount;
    }

    function assertTrackPlusEq(string memory id, uint256 plus, uint256 amount) public {
        assertEq(tracked[id] + plus, amount);
    }

    function setUp() public virtual {
        vm.createSelectFork('mainnet', 15741300);
        
        seriesId = donorStrategy.seriesId();
        pool = donorStrategy.pool();
        fyToken = IFYToken(address(pool.fyToken()));
        baseToken = pool.baseToken();
        sharesToken = pool.sharesToken();

        strategy = new Strategy("", "", baseToken.decimals(), ladle, fyToken);

        strategy.grantRole(Strategy.init.selector, alice);

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
    function testInit() public {
        console2.log("strategy.init()");
        uint256 initAmount = 1e18;
        cash(baseToken, address(strategy), initAmount);
        track("bobStrategyTokens", strategy.balanceOf(bob));

        vm.prank(alice);
        strategy.init(bob);

        // Test the strategy can add the dstStrategy as the next pool
        assertEq(strategy.totalSupply(), strategy.balanceOf(bob));
        assertTrackPlusEq("bobStrategyTokens", initAmount, strategy.balanceOf(bob));
    }
}

// Deployed
//   mint(4) -> init -> Divested ✓
//   init -> Divested
// Divested
//   mintDivested
//   burnDivested
//   invest -> Invested
// Invested
//   mint(3)
//   burn
//   eject -> DivestedAndEjected
//   time passes -> InvestedAfterMaturity
// InvestedAfterMaturity
//   divest -> Divested

// DivestedAndEjected
//   same as Divested
//   time passes -> DivestedAndEjectedAfterMaturityOfEjected
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