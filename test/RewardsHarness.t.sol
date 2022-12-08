// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import { IERC20 } from "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import { ERC20Mock } from "lib/yield-utils-v2/contracts/mocks/ERC20Mock.sol";
// import { Strategy } from "../contracts/Strategy.sol";
import { IStrategy } from "../contracts/interfaces/IStrategy.sol";
import { TestExtensions } from "./utils/TestExtensions.sol";
import { TestConstants } from "./utils/TestConstants.sol";


using stdStorage for StdStorage;

abstract contract Deployed is Test, TestExtensions, TestConstants {

    event RewardsTokenSet(IERC20 token);
    event RewardsSet(uint32 start, uint32 end, uint256 rate);
    event RewardsPerTokenUpdated(uint256 accumulated);
    event UserRewardsUpdated(address user, uint256 userRewards, uint256 paidRewardPerToken);
    event Claimed(address user, address receiver, uint256 claimed);

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

    function setUpMock() public {
        setUpHarness(LOCALHOST); // TODO: Merge with the unit tests
    }

    function setUpHarness(string memory network) public {
        timelock = addresses[network][TIMELOCK];

        strategy = IStrategy(vm.envAddress("STRATEGY"));
        strategyUnit = uint128(10 ** ERC20Mock(address(strategy)).decimals());

        rewards = IERC20(address(new ERC20Mock("Rewards Token", "REW")));
        rewardsUnit = 10 ** ERC20Mock(address(rewards)).decimals();
    }

    function setUp() public virtual {
        string memory network = vm.envOr(NETWORK, LOCALHOST);
        if (!equal(network, LOCALHOST)) vm.createSelectFork(vm.envOr("RPC", LOCALHOST)); // TODO: Why doesn't it pick RPC from TestConstants?

        if (vm.envOr(MOCK, true)) setUpMock();
        else setUpHarness(network);

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

        cash(IERC20(address(strategy.pool())), address(strategy), 100 * strategyUnit);
        strategy.mint(user);

        cash(IERC20(address(strategy.pool())), address(strategy), 100 * strategyUnit);
        strategy.mint(other);

        userProportion = strategy.balanceOf(user) * 1e18 / strategy.totalSupply();
        userMintTime = block.timestamp;
        otherProportion = strategy.balanceOf(other) * 1e18 / strategy.totalSupply();
        otherMintTime = block.timestamp;
    }

    modifier skipRewardsTokenSet() {
        if(address(strategy.rewardsToken()) != address(0)) {
            console2.log("Rewards token set, skipping test");
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

    function testSetRewardsToken(IERC20 token) public skipRewardsTokenSet {
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

        if(address(strategy.rewardsToken()) == address(0)) {
            console2.log("Setting Rewards Token");
            vm.prank(timelock);
            strategy.setRewardsToken(rewards);
        }
    }
}


contract WithRewardsTokenTest is WithRewardsToken {

    function testDontResetRewardsToken(address token) public {
        vm.expectRevert(bytes("Rewards token already set"));

        vm.prank(timelock);
        strategy.setRewardsToken(IERC20(token));
    }

    function testStartBeforeEnd(uint32 start, uint32 end) public skipRewardsPeriodSet {
        end = uint32(bound(end, block.timestamp, type(uint32).max));
        end = uint32(bound(end, block.timestamp, type(uint32).max - 1));
        start = uint32(bound(start, end + 1, type(uint32).max));
        vm.expectRevert(bytes("Incorrect input"));
        vm.prank(timelock);
        strategy.setRewards(start, end, 1);
    }

    function testSetRewards(uint32 start, uint32 end, uint96 rate) public skipRewardsPeriodSet {
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

        (uint256 start, uint256 end) = strategy.rewardsPeriod();
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

contract WithProgramTest is WithProgram {

    function testProgramChange(uint32 start, uint32 end, uint96 rate) public skipRewardsPeriodStarted {
        end = uint32(bound(end, block.timestamp + 1, type(uint32).max));
        start = uint32(bound(start, block.timestamp, end - 1));

        vm.expectEmit(true, false, false, false);
        emit RewardsSet(start, end, rate);

        vm.prank(timelock);
        strategy.setRewards(start, end, rate);
    }

    function testDoesntUpdateRewardsPerToken() public skipRewardsPeriodStarted {
        cash(IERC20(address(strategy.pool())), address(strategy), strategyUnit);
        strategy.mint(user);
        (uint128 accumulated,,) = strategy.rewardsPerToken();
        assertEq(accumulated, 0);
    }

    function testDoesntUpdateUserRewards() public skipRewardsPeriodStarted {
        cash(IERC20(address(strategy.pool())), address(strategy), strategyUnit);
        strategy.mint(user);
        (uint128 accumulated,) = strategy.rewards(user);
        assertEq(accumulated, 0);
    }
}

abstract contract DuringProgram is WithProgram {
    function setUp() public override virtual {
        super.setUp();

        // If period not started yet, warp to start
        (uint256 start,) = strategy.rewardsPeriod();
        if(block.timestamp < start) {
            console2.log("Warping to start of rewards period");
            vm.warp(start);
        }
    }
}

contract DuringProgramTest is DuringProgram {

    function dontChangeProgram(uint32 start, uint32 end, uint96 rate) public {
        end = uint32(bound(end, block.timestamp + 1, type(uint32).max));
        start = uint32(bound(start, block.timestamp, end - 1));

        vm.expectRevert(bytes("Ongoing program"));
        vm.prank(timelock);
        strategy.setRewards(start, end, rate);
    }

    function testUpdatesRewardsPerTokenOnMint(uint32 elapsed) public {
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

    function testUpdatesRewardsPerTokenOnBurn(uint32 elapsed) public {
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

    function testUpdatesRewardsPerTokenOnTransfer(uint32 elapsed) public {
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

    function testUpdatesUserRewardsOnMint(uint32 elapsed, uint32 elapseAgain, uint128 mintAmount) public {
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        elapsed = uint32(bound(elapsed, 0, end - start));

        // deposit = mintAmount + pool.balanceOf(address(strategy)) - strategy.cached
        // deposit <= type(uint256).max / strategy.totalSupply() 
        // mintAmount + pool.balanceOf(address(strategy)) - strategy.cached <= type(uint256).max / strategy.totalSupply()
        // mintAmount <= type(uint256).max / strategy.totalSupply() - pool.balanceOf(address(strategy)) + strategy.cached
        // mintAmount = uint128(bound(mintAmount, 0, type(uint256).max / strategy.totalSupply() - strategy.pool().balanceOf(address(strategy)) + strategy.cached()));
        mintAmount = uint128(bound(mintAmount, 0, strategyUnit * 1e18)); // TODO: 1e18 full tokens is a ridiculously high amount, but it would be better to replace it by the actual limit.

        vm.warp(start + elapsed);
        cash(IERC20(address(strategy.pool())), address(strategy), mintAmount);
        strategy.mint(user);
        (uint128 accumulatedUserStart, uint128 accumulatedCheckpoint) = strategy.rewards(user);
        (uint128 accumulatedPerToken,,) = strategy.rewardsPerToken();
        assertEq(accumulatedCheckpoint, accumulatedPerToken);

        elapseAgain = uint32(bound(elapseAgain, 0, end - (start + elapsed)));
        vm.warp(start + elapsed + elapseAgain);
        uint256 userBalance = strategy.balanceOf(user);
        cash(IERC20(address(strategy.pool())), address(strategy), mintAmount);
        strategy.mint(user);
        (uint128 accumulatedPerTokenNow,,) = strategy.rewardsPerToken();
        (uint128 accumulatedUser,) = strategy.rewards(user);
        assertEq(accumulatedUser, accumulatedUserStart + userBalance * (accumulatedPerTokenNow - accumulatedPerToken) / 1e18);
    }

    function testUpdatesUserRewardsOnBurn(uint32 elapsed, uint32 elapseAgain, uint128 burnAmount) public {
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        elapsed = uint32(bound(elapsed, 0, end - start));
        uint256 userBalance = strategy.balanceOf(user);
        assertGt(userBalance, 0);
        burnAmount = uint128(bound(burnAmount, 0, userBalance)) / 2;

        vm.warp(start + elapsed);
        vm.startPrank(user);
        strategy.transfer(address(strategy), burnAmount);
        strategy.burn(user);

        (uint128 accumulatedUserStart, uint128 accumulatedCheckpoint) = strategy.rewards(user);
        (uint128 accumulatedPerToken,,) = strategy.rewardsPerToken();
        assertEq(accumulatedCheckpoint, accumulatedPerToken);

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

    function testUpdatesUserRewardsOnTransfer(uint32 elapsed, uint32 elapseAgain, uint128 transferAmount) public {
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        elapsed = uint32(bound(elapsed, 0, end - start));
        uint256 userBalance = strategy.balanceOf(user);
        assertGt(userBalance, 0);
        transferAmount = uint128(bound(transferAmount, 0, userBalance));

        vm.warp(start + elapsed);
        vm.prank(user);
        strategy.transfer(other, transferAmount);
        (uint128 accumulatedUserStart, uint128 accumulatedCheckpointUser) = strategy.rewards(user);
        (uint128 accumulatedOtherStart, uint128 accumulatedCheckpointOther) = strategy.rewards(other);
        (uint128 accumulatedPerToken,,) = strategy.rewardsPerToken();
        assertEq(accumulatedCheckpointUser, accumulatedPerToken);
        assertEq(accumulatedCheckpointOther, accumulatedPerToken);

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

    function testClaim() public {
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        uint256 elapsed = end - (userMintTime >= start ? userMintTime : start);
        vm.warp(end);

        (uint128 accumulatedUser,) = strategy.rewards(user);
        assertEq(accumulatedUser, 0);

        track("otherRewardsBalance", rewards.balanceOf(other));

        (,, uint96 rate) = strategy.rewardsPerToken();
        uint256 expectedRewards = rate * elapsed * userProportion / 1e18;

        vm.prank(user);
        strategy.claim(other);
        (uint128 accumulatedPerTokenNow,,) = strategy.rewardsPerToken();

        uint256 calculatedRewards = uint256(accumulatedPerTokenNow) * strategy.balanceOf(user) / 1e18;

        assertTrackPlusEq("otherRewardsBalance", calculatedRewards, rewards.balanceOf(other));
        assertApproxEqRel(expectedRewards, calculatedRewards, 1e14);
    }


    function testRemit() public {
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        uint256 elapsed = end - (userMintTime >= start ? userMintTime : start);
        vm.warp(end);

        (uint128 accumulatedUser,) = strategy.rewards(user);
        assertEq(accumulatedUser, 0);

        track("userRewardsBalance", rewards.balanceOf(user));

        (,, uint96 rate) = strategy.rewardsPerToken();
        uint256 expectedRewards = rate * elapsed * userProportion / 1e18;

        vm.prank(other);
        strategy.claim(user);
        (uint128 accumulatedPerTokenNow,,) = strategy.rewardsPerToken();

        uint256 calculatedRewards = uint256(accumulatedPerTokenNow) * strategy.balanceOf(user) / 1e18;

        assertTrackPlusEq("userRewardsBalance", calculatedRewards, rewards.balanceOf(user));
        assertApproxEqRel(expectedRewards, calculatedRewards, 1e14);
    }
}

abstract contract AfterProgramEnd is WithProgram {
    function setUp() public override virtual {
        super.setUp();

        // If rewards period active, warp to end
        (, uint32 end) = strategy.rewardsPeriod();
        if (end < block.timestamp) {
            vm.warp(end + 1);
        }
    }
}

contract AfterProgramEndTest is AfterProgramEnd {

    function testSetNewRewards(uint32 start, uint32 end, uint96 rate) public {
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

    function testAccumulateNoMore() public {
        (uint32 start, uint32 end) = strategy.rewardsPeriod();
        vm.warp(end);
        cash(IERC20(address(strategy.pool())), address(strategy), strategyUnit);
        strategy.mint(user);
        (uint128 globalAccumulated,,) = strategy.rewardsPerToken();
        (, uint128 userAccumulated) = strategy.rewards(user);

        vm.warp(end + 10);

        cash(IERC20(address(strategy.pool())), address(strategy), strategyUnit);
        strategy.mint(user);

        (uint128 globalAccumulatedAfter,,) = strategy.rewardsPerToken();
        (, uint128 userAccumulatedAfter) = strategy.rewards(user);

        assertEq(globalAccumulated, globalAccumulatedAfter);
        assertEq(userAccumulated, userAccumulatedAfter);
    }
}