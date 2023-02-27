// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import { IERC20 } from "@yield-protocol/utils-v2/src/token/IERC20.sol";
import { ERC20Mock } from "@yield-protocol/vault-v2/src/mocks/ERC20Mock.sol";
import { IStrategy } from "../../src/interfaces/IStrategy.sol";
import { TestExtensions } from "./../utils/TestExtensions.sol";
import { TestConstants } from "./../utils/TestConstants.sol";


using stdStorage for StdStorage;

abstract contract Deployed is Test, TestExtensions, TestConstants {
    event RewardsTokenSet(IERC20 token);
    event RewardsSet(uint32 start, uint32 end, uint256 rate);
    event RewardsPerTokenUpdated(uint256 accumulated);
    event UserRewardsUpdated(address user, uint256 userRewards, uint256 paidRewardPerToken);
    event Claimed(address user, address receiver, uint256 claimed);

    bool ci;

    IStrategy public strategy;
    uint256 public strategyUnit;
    IERC20 public rewards;
    uint256 public rewardsUnit;
    uint256 totalRewards; // = 10 * WAD;
    uint256 length; // = 1000000;


    address user;
    address other;
    address timelock;
    address me;

    uint256 userProportion;
    uint256 userMintTime;
    uint256 otherProportion;
    uint256 otherMintTime;

    function setUp() public virtual {
        if (!(ci = vm.envOr(CI, true))) {
            string memory rpc = vm.envOr(RPC, HARNESS);
            vm.createSelectFork(rpc);

            string memory network = vm.envOr(NETWORK, MAINNET);
            timelock = addresses[network][TIMELOCK];

            strategy = IStrategy(vm.envAddress(STRATEGY));
            strategyUnit = uint128(10 ** ERC20Mock(address(strategy)).decimals());

            rewards = IERC20(address(new ERC20Mock("Rewards Token", "REW")));
            rewardsUnit = 10 ** ERC20Mock(address(rewards)).decimals();

            //... Users ...
            user = address(1);
            other = address(2);
            me = 0xb4c79daB8f259C7Aee6E5b2Aa729821864227e84;

            vm.label(user, "user");
            vm.label(other, "other");
            vm.label(timelock, "timelock");
            vm.label(me, "me");
            vm.label(address(strategy), "strategy");
            vm.label(address(rewards), "rewards");

            // Mint some rewards
            cash(IERC20(address(strategy.pool())), address(strategy), 100 * strategyUnit);
            strategy.mint(user);

            cash(IERC20(address(strategy.pool())), address(strategy), 100 * strategyUnit);
            strategy.mint(other);

            // Record data for claim tests
            userProportion = strategy.balanceOf(user) * 1e18 / strategy.totalSupply();
            userMintTime = block.timestamp;
            otherProportion = strategy.balanceOf(other) * 1e18 / strategy.totalSupply();
            otherMintTime = block.timestamp;
        }
    }

    modifier skipRewardsTokenSet() {
        if(address(strategy.rewardsToken()) != address(0)) {
            console2.log("Rewards token set, skipping test");
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

    modifier skipRewardsPeriodSet() {
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        if(start != 0 && end != 0) {
            console2.log("Rewards period set, skipping test");
        }
        _;
    }

    modifier skipRewardsPeriodStarted() {
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        if(start != 0 && end != 0 && block.timestamp >= start) {
            console2.log("Rewards period started, skipping test");
        }
        _;
    }


    modifier skipRewardsPeriodEnded() {
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        if(start != 0 && end != 0 && block.timestamp >= end) {
            console2.log("Rewards period ended, skipping test");
        }
        _;
    }
}

contract DeployedTest is Deployed {

    function testSetRewardsToken(IERC20 token) public skipOnCI skipRewardsTokenSet {
        vm.expectEmit(true, false, false, false);
        emit RewardsTokenSet(token);

        vm.prank(timelock);
        strategy.setRewardsToken(token);

        assertEq(address(strategy.rewardsToken()), address(token));
    }
}

abstract contract WithRewardsToken is Deployed {
    function setUp() public override virtual {
        super.setUp();

        if (!ci) {
            if(address(strategy.rewardsToken()) == address(0)) {
                console2.log("Setting Rewards Token");
                vm.prank(timelock);
                strategy.setRewardsToken(rewards);
            }
        }
    }
}


contract WithRewardsTokenTest is WithRewardsToken {

    function testDontResetRewardsToken(address token) public skipOnCI {
        vm.expectRevert(bytes("Rewards token already set"));

        vm.prank(timelock);
        strategy.setRewardsToken(IERC20(token));
    }

    function testStartBeforeEnd(uint32 start, uint32 end) public skipOnCI skipRewardsPeriodSet {
        end = uint32(bound(end, block.timestamp, type(uint32).max));
        end = uint32(bound(end, block.timestamp, type(uint32).max - 1));
        start = uint32(bound(start, end + 1, type(uint32).max));
        vm.expectRevert(bytes("Incorrect input"));
        vm.prank(timelock);
        strategy.setRewards(start, end, 1);
    }

    function testSetRewards(uint32 start, uint32 end, uint96 rate) public skipOnCI skipRewardsPeriodSet {
        end = uint32(bound(end, block.timestamp + 1, type(uint32).max));
        start = uint32(bound(start, block.timestamp, end - 1));

        vm.expectEmit(true, false, false, false);
        emit RewardsSet(start, end, rate);

        vm.prank(timelock);
        strategy.setRewards(start, end, rate);

        (uint32 start_, uint32 end_) = strategy.rewardsPeriod();
        (,, uint96 rate_) = strategy.rewardsPerToken();

        assertEq(start_, start);
        assertEq(end_, end);
        assertEq(rate_, rate);
    }
}

abstract contract WithProgram is WithRewardsToken {
    function setUp() public override virtual {
        super.setUp();

        if (!ci) {
            (uint256 start, uint256 end) = strategy.rewardsPeriod();
            // If there isn't a rewards period set, or the rewards period has ended, set a new one
            if(start == 0 && end == 0 || block.timestamp > end) {
                console2.log("Setting Rewards Period");
                length = 1000000;
                totalRewards = 10 * rewardsUnit;
                start = block.timestamp + 1000000;
                end = start + length;
                uint256 rate = totalRewards / length;

                vm.prank(timelock);
                strategy.setRewards(uint32(start), uint32(end), uint96(rate));

                cash(rewards, address(strategy), totalRewards); // Rewards to be distributed
            } else {
                length = end - start;
                (,, uint96 rate) = strategy.rewardsPerToken();
                totalRewards = length * rate;
            }
        }
    }
}

contract WithProgramTest is WithProgram {

    function testProgramChange(uint32 start, uint32 end, uint96 rate) public skipOnCI skipRewardsPeriodStarted {
        end = uint32(bound(end, block.timestamp + 1, type(uint32).max));
        start = uint32(bound(start, block.timestamp, end - 1));

        vm.expectEmit(true, false, false, false);
        emit RewardsSet(start, end, rate);

        vm.prank(timelock);
        strategy.setRewards(start, end, rate);
    }

    function testDoesntUpdateRewardsPerToken() public skipOnCI skipRewardsPeriodStarted {
        cash(IERC20(address(strategy.pool())), address(strategy), strategyUnit);
        strategy.mint(user);
        (uint128 accumulated,,) = strategy.rewardsPerToken();
        assertEq(accumulated, 0);
    }

    function testDoesntUpdateUserRewards() public skipOnCI skipRewardsPeriodStarted {
        cash(IERC20(address(strategy.pool())), address(strategy), strategyUnit);
        strategy.mint(user);
        (uint128 accumulated,) = strategy.rewards(user);
        assertEq(accumulated, 0);
    }
}

abstract contract DuringProgram is WithProgram {
    function setUp() public skipOnCI override virtual {
        super.setUp();

        if (!ci) {
            // If period not started yet, warp to start
            (uint256 start,) = strategy.rewardsPeriod();
            if(block.timestamp < start) {
                console2.log("Warping to start of rewards period");
                vm.warp(start);
            }
        }
    }
}

contract DuringProgramTest is DuringProgram {

    function dontChangeProgram(uint32 start, uint32 end, uint96 rate) public skipOnCI {
        end = uint32(bound(end, block.timestamp + 1, type(uint32).max));
        start = uint32(bound(start, block.timestamp, end - 1));

        vm.expectRevert(bytes("Ongoing program"));
        vm.prank(timelock);
        strategy.setRewards(start, end, rate);
    }

    // Warp somewhere in rewards period, mint, and check that rewardsPerToken is updated
    function testUpdatesRewardsPerTokenOnMint(uint32 elapsed) public skipOnCI {
        uint256 totalSupply = strategy.totalSupply();
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        elapsed = uint32(bound(elapsed, 0, end - start));
        vm.warp(start + elapsed);
        cash(IERC20(address(strategy.pool())), address(strategy), strategyUnit);
        strategy.mint(user);

        (uint128 accumulated, uint32 lastUpdated, uint96 rate) = strategy.rewardsPerToken();
        assertEq(lastUpdated, block.timestamp);
        assertEq(accumulated, uint256(rate) * elapsed * 1e18 / totalSupply); // accumulated is stored scaled up by 1e18
    }

    // Warp somewhere in rewards period, burn, and check that rewardsPerToken is updated
    function testUpdatesRewardsPerTokenOnBurn(uint32 elapsed) public skipOnCI {
        uint256 totalSupply = strategy.totalSupply();
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        elapsed = uint32(bound(elapsed, 0, end - start));
        vm.warp(start + elapsed);
        vm.startPrank(user);
        strategy.transfer(address(strategy), strategy.balanceOf(user));
        strategy.burn(user);
        vm.stopPrank();

        (uint128 accumulated, uint32 lastUpdated, uint96 rate) = strategy.rewardsPerToken();
        assertEq(lastUpdated, block.timestamp);
        assertEq(accumulated, uint256(rate) * elapsed * 1e18 / totalSupply); // accumulated is stored scaled up by 1e18
    }

    // Warp somewhere in rewards period, transfer, and check that rewardsPerToken is updated
    function testUpdatesRewardsPerTokenOnTransfer(uint32 elapsed) public skipOnCI {
        uint256 totalSupply = strategy.totalSupply();
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        elapsed = uint32(bound(elapsed, 0, end - start));
        vm.warp(start + elapsed);
        vm.prank(user);
        strategy.transfer(other, 1);

        (uint128 accumulated, uint32 lastUpdated, uint96 rate) = strategy.rewardsPerToken();
        assertEq(lastUpdated, block.timestamp);
        assertEq(accumulated, uint256(rate) * elapsed * 1e18 / totalSupply); // accumulated is stored scaled up by 1e18
    }

    function testUpdatesUserRewardsOnMint(uint32 elapsed, uint32 elapseAgain, uint128 mintAmount) public skipOnCI {
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        elapsed = uint32(bound(elapsed, 0, end - start));

        // deposit = mintAmount + pool.balanceOf(address(strategy)) - strategy.cached
        // deposit <= type(uint256).max / strategy.totalSupply() 
        // mintAmount + pool.balanceOf(address(strategy)) - strategy.cached <= type(uint256).max / strategy.totalSupply()
        // mintAmount <= type(uint256).max / strategy.totalSupply() - pool.balanceOf(address(strategy)) + strategy.cached
        // mintAmount = uint128(bound(mintAmount, 0, type(uint256).max / strategy.totalSupply() - strategy.pool().balanceOf(address(strategy)) + strategy.cached()));
        mintAmount = uint128(bound(mintAmount, 0, strategyUnit * 1e18)); // TODO: 1e18 full tokens is a ridiculously high amount, but it would be better to replace it by the actual limit.

        // First, check that rewardsPerToken is updated
        vm.warp(start + elapsed);
        cash(IERC20(address(strategy.pool())), address(strategy), mintAmount);
        strategy.mint(user);
        (uint128 accumulatedUserStart, uint128 accumulatedCheckpoint) = strategy.rewards(user);
        (uint128 accumulatedPerToken,,) = strategy.rewardsPerToken();
        assertEq(accumulatedCheckpoint, accumulatedPerToken);

        // Then, check that user rewards are updated
        elapseAgain = uint32(bound(elapseAgain, 0, end - (start + elapsed)));
        vm.warp(start + elapsed + elapseAgain);
        uint256 userBalance = strategy.balanceOf(user);
        cash(IERC20(address(strategy.pool())), address(strategy), mintAmount);
        strategy.mint(user);
        (uint128 accumulatedPerTokenNow,,) = strategy.rewardsPerToken();
        (uint128 accumulatedUser,) = strategy.rewards(user);
        assertEq(accumulatedUser, accumulatedUserStart + userBalance * (accumulatedPerTokenNow - accumulatedPerToken) / 1e18);
    }

    function testUpdatesUserRewardsOnBurn(uint32 elapsed, uint32 elapseAgain, uint128 burnAmount) public skipOnCI {
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        elapsed = uint32(bound(elapsed, 0, end - start));
        uint256 userBalance = strategy.balanceOf(user);
        assertGt(userBalance, 0);
        burnAmount = uint128(bound(burnAmount, 0, userBalance)) / 2;

        // First, check that rewardsPerToken is updated
        vm.warp(start + elapsed);
        vm.startPrank(user);
        strategy.transfer(address(strategy), burnAmount);
        strategy.burn(user);

        (uint128 accumulatedUserStart, uint128 accumulatedCheckpoint) = strategy.rewards(user);
        (uint128 accumulatedPerToken,,) = strategy.rewardsPerToken();
        assertEq(accumulatedCheckpoint, accumulatedPerToken);

        // Then, check that user rewards are updated
        elapseAgain = uint32(bound(elapseAgain, 0, end - (start + elapsed)));
        vm.warp(start + elapsed + elapseAgain);
        userBalance = strategy.balanceOf(user);
        
        strategy.transfer(address(strategy), burnAmount);
        strategy.burn(user);
        vm.stopPrank();
        (uint128 accumulatedPerTokenNow,,) = strategy.rewardsPerToken();
        (uint128 accumulatedUser,) = strategy.rewards(user);
        assertEq(accumulatedUser, accumulatedUserStart + userBalance * (accumulatedPerTokenNow - accumulatedPerToken) / 1e18);
    }

    function testUpdatesUserRewardsOnTransfer(uint32 elapsed, uint32 elapseAgain, uint128 transferAmount) public skipOnCI {
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        elapsed = uint32(bound(elapsed, 0, end - start));
        uint256 userBalance = strategy.balanceOf(user);
        assertGt(userBalance, 0);
        transferAmount = uint128(bound(transferAmount, 0, userBalance));

        // First, check that rewardsPerToken is updated
        vm.warp(start + elapsed);
        vm.prank(user);
        strategy.transfer(other, transferAmount);
        (uint128 accumulatedUserStart, uint128 accumulatedCheckpointUser) = strategy.rewards(user);
        (uint128 accumulatedOtherStart, uint128 accumulatedCheckpointOther) = strategy.rewards(other);
        (uint128 accumulatedPerToken,,) = strategy.rewardsPerToken();
        assertEq(accumulatedCheckpointUser, accumulatedPerToken);
        assertEq(accumulatedCheckpointOther, accumulatedPerToken);

        // Then, check that user rewards are updated
        elapseAgain = uint32(bound(elapseAgain, 0, end - (start + elapsed)));
        vm.warp(start + elapsed + elapseAgain);
        userBalance = strategy.balanceOf(user);
        uint256 otherBalance = strategy.balanceOf(other);
        vm.prank(other);
        strategy.transfer(user, transferAmount);
        (uint128 accumulatedPerTokenNow,,) = strategy.rewardsPerToken();
        (uint128 accumulatedUser,) = strategy.rewards(user);
        (uint128 accumulatedOther,) = strategy.rewards(other);
        assertEq(accumulatedUser, accumulatedUserStart + userBalance * (accumulatedPerTokenNow - accumulatedPerToken) / 1e18);
        assertEq(accumulatedOther, accumulatedOtherStart + otherBalance * (accumulatedPerTokenNow - accumulatedPerToken) / 1e18);
    }

    function testClaim() public skipOnCI {
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        uint256 elapsed = end - (userMintTime >= start ? userMintTime : start);
        vm.warp(end);

        (uint128 accumulatedUser,) = strategy.rewards(user);
        assertEq(accumulatedUser, 0);

        track("otherRewardsBalance", rewards.balanceOf(other));

        (,, uint96 rate) = strategy.rewardsPerToken();
        uint256 expectedRewards = rate * elapsed * userProportion / 1e18; // This works because we know no one else has minted after the user

        vm.prank(user);
        strategy.claim(other);

        assertApproxEqRel(expectedRewards, rewards.balanceOf(other) - tracked["otherRewardsBalance"], 1e14);
    }


    function testRemit() public skipOnCI {
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        uint256 elapsed = end - (userMintTime >= start ? userMintTime : start);
        vm.warp(end);

        (uint128 accumulatedUser,) = strategy.rewards(user);
        assertEq(accumulatedUser, 0);

        track("userRewardsBalance", rewards.balanceOf(user));

        (,, uint96 rate) = strategy.rewardsPerToken();
        uint256 expectedRewards = rate * elapsed * userProportion / 1e18; // This works because we know no one else has minted after the user

        vm.prank(other);
        strategy.claim(user);

        assertApproxEqRel(expectedRewards, rewards.balanceOf(user) - tracked["userRewardsBalance"], 1e14);
    }
}

abstract contract AfterProgramEnd is WithProgram {
    function setUp() public override virtual {
        super.setUp();

        if (!ci) {
            // If rewards period active, warp to end
            (, uint32 end) = strategy.rewardsPeriod();
            if (end < block.timestamp) {
                vm.warp(end + 1);
            }
        }
    }
}

contract AfterProgramEndTest is AfterProgramEnd {

    function testSetNewRewards(uint32 start, uint32 end, uint96 rate) public skipOnCI {
        end = uint32(bound(end, block.timestamp + 1, type(uint32).max));
        start = uint32(bound(start, block.timestamp, end - 1));

        vm.expectEmit(true, false, false, false);
        emit RewardsSet(start, end, rate);

        vm.prank(timelock);
        strategy.setRewards(start, end, rate);

        (uint32 start_, uint32 end_) = strategy.rewardsPeriod();
        (,, uint96 rate_) = strategy.rewardsPerToken();

        assertEq(start_, start);
        assertEq(end_, end);
        assertEq(rate_, rate);
    }

    function testAccumulateNoMore() public skipOnCI {
        // Warp to end and mint to update accumulators
        (, uint32 end) = strategy.rewardsPeriod();
        vm.warp(end);
        cash(IERC20(address(strategy.pool())), address(strategy), strategyUnit);
        strategy.mint(user);
        (uint128 globalAccumulated,,) = strategy.rewardsPerToken();
        (, uint128 userAccumulated) = strategy.rewards(user);

        // Warp again, and check accumulators haven't changed
        vm.warp(end + 10);

        cash(IERC20(address(strategy.pool())), address(strategy), strategyUnit);
        strategy.mint(user);

        (uint128 globalAccumulatedAfter,,) = strategy.rewardsPerToken();
        (, uint128 userAccumulatedAfter) = strategy.rewards(user);

        assertEq(globalAccumulated, globalAccumulatedAfter);
        assertEq(userAccumulated, userAccumulatedAfter);
    }
}