// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;

import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/ERC20Permit.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/utils-v2/contracts/utils/RevertMsgExtractor.sol";


library CastU256U224 {
    /// @dev Safely cast an uint256 to an uint224
    function u224(uint256 x) internal pure returns (uint224 y) {
        require (x <= type(uint32).max, "Cast overflow");
        y = uint224(x);
    }
}

library CastU256U32 {
    /// @dev Safely cast an uint256 to an uint32
    function u32(uint256 x) internal pure returns (uint32 y) {
        require (x <= type(uint32).max, "Cast overflow");
        y = uint32(x);
    }
}

/// @dev A token inheriting from ERC20Rewards will reward token holders with a rewards token.
/// The rewarded amount will be a fixed wei per second, distributed proportionally to token holders
/// by the size of their holdings.
contract ERC20Rewards is AccessControl, ERC20Permit {
    using CastU256U32 for uint256;
    using CastU256U224 for uint256;

    event RewardsSet(IERC20 rewardToken, uint32 start, uint32 end, uint256 rate);
    event Claimable(address user, uint256 claimable);
    event Claimed(address user, uint256 claimed);

    struct RewardPeriod {
        uint32 start;                                   // Start time for the current rewardToken schedule
        uint32 end;                                     // End time for the current rewardToken schedule
    }

    struct SupplyTracker {
        uint32 lastUpdated;                             // Last time the total supply average was computed
        uint224 average;                                // Average total supply
    }

    struct UserRewards {
        uint32 lastUpdated;                             // Last time the user rewards were updated
        uint224 accumulated;                            // Rewards accumulated before the last update
    }

    IERC20 public rewardToken;                          // Token used as rewards
    RewardPeriod public rewardPeriod;                   // Period in which rewards are accumulated by users
    SupplyTracker public supplyTracker;                 // Total supply average
    uint256 public rewardRate;                          // Wei rewarded per second

    mapping (address => UserRewards) public rewards;    // Rewards accumulated by users
    
    constructor(string memory name, string memory symbol, uint8 decimals)
        ERC20Permit(name, symbol, decimals)
    { }

    /// @dev Submit a series of calls for execution
    /// @notice Allows batched call to self (this contract).
    /// @param calls An array of inputs for each call.
    function batch(bytes[] calldata calls) external payable returns(bytes[] memory results) {
        results = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(calls[i]);
            if (!success) revert(RevertMsgExtractor.getRevertMsg(result));
            results[i] = result;
        }
    }

    /// @dev Set a rewards schedule
    /// TODO: Allow sequential schedules, each with their own supply accumulator and rewards accumulator. Only once active schdule at a time.
    function setRewards(IERC20 rewardToken_, uint32 start, uint32 end, uint256 rate)
        public
        auth
    {
        if (rewardToken_ != IERC20(address(0))) rewardToken = rewardToken_; // TODO: Allow to change only after a safety period after end, to avoid affecting current claimable

        RewardPeriod memory rewardPeriod_ = rewardPeriod;
        rewardPeriod_.start = start;
        rewardPeriod_.end = end;
        rewardPeriod = rewardPeriod_;

        rewardRate = rate;
        emit RewardsSet(rewardToken, start, end, rate);
    }

    /// @dev Claim all rewards from caller into a given address
    function claim(address to)
        public
        returns (uint256 claiming)
    {
        UserRewards memory userRewards_ = rewards[msg.sender];
        RewardPeriod memory rewardPeriod_ = rewardPeriod;
        
        // Calculate the period for which rewards haven't been recorded into the accumulator
        uint32 start = (userRewards_.lastUpdated > rewardPeriod_.start) ? userRewards_.lastUpdated : rewardPeriod_.start;
        uint32 end = (block.timestamp.u32() > rewardPeriod_.end) ? rewardPeriod_.end : block.timestamp.u32();
        uint32 unaccountedPeriod = (end > start) ? end - start : 0;

        // Calculate the claimable amount
        uint256 rewardsPerTokenPerSecond = rewardRate / supplyTracker.average;
        claiming = unaccountedPeriod * _balanceOf[msg.sender] * rewardsPerTokenPerSecond + userRewards_.accumulated;

        // Reset the user rewards records
        userRewards_.accumulated = 0;
        userRewards_.lastUpdated = block.timestamp.u32();
        rewards[msg.sender] = userRewards_;

        // Transfer out the rewards
        rewardToken.transfer(to, claiming);
        emit Claimed(to, claiming);
    }

    /// @dev Update the average supply as the time-weighted average between the previous average until the previous update,
    /// and the current supply level from the previous update until now.
    function _updateAverageSupply()
        internal
        returns (uint224 _averageSupply)
    {
        SupplyTracker memory supplyTracker_ = supplyTracker;
        uint32 storedEnd = (supplyTracker_.lastUpdated > rewardPeriod.start) ? supplyTracker_.lastUpdated : rewardPeriod.start;
        uint32 storedPeriod = storedEnd - rewardPeriod.start;
        uint32 currentEnd = (block.timestamp.u32() > rewardPeriod.end) ? rewardPeriod.end : block.timestamp.u32();
        uint32 currentPeriod = currentEnd - block.timestamp.u32();

        if (currentPeriod == 0) return 0; // Save gas

        supplyTracker_.average = _averageSupply = ((supplyTracker_.average * storedPeriod + _totalSupply * currentPeriod) / (storedPeriod + currentPeriod)).u224();
        supplyTracker_.lastUpdated = block.timestamp.u32();
        supplyTracker = supplyTracker_;
        // emit
    }

    function _updateUserRewards(address user)
        internal
        returns (uint224 _rewards)
    {
        UserRewards memory userRewards_ = rewards[user];
        uint32 start = (userRewards_.lastUpdated > rewardPeriod.start) ? userRewards_.lastUpdated : rewardPeriod.start;
        uint32 end = (block.timestamp.u32() > rewardPeriod.end) ? rewardPeriod.end : block.timestamp.u32();
        uint32 unaccountedPeriod = (end > start) ? end - start : 0;

        if (unaccountedPeriod == 0) return 0; // Save gas

        uint256 rewardsPerTokenPerSecond = rewardRate / supplyTracker.average;
        userRewards_.accumulated = _rewards = (unaccountedPeriod * _balanceOf[user] * rewardsPerTokenPerSecond + userRewards_.accumulated).u224();
        userRewards_.lastUpdated = block.timestamp.u32();
        rewards[user] = userRewards_;
        // emit
    }

    /// @dev Mint tokens, updating the supply average before.
    function _mint(address dst, uint256 wad)
        internal virtual override
        returns (bool)
    {
        _updateUserRewards(msg.sender);
        _updateAverageSupply();
        return super._mint(dst, wad);
    }

    /// @dev Burn tokens, updating the supply average before.
    function _burn(address src, uint256 wad)
        internal virtual override
        returns (bool)
    {
        _updateUserRewards(msg.sender);
        _updateAverageSupply();
        return super._burn(src, wad);
    }

    /// @dev Transfer tokens, updating the accumulated rewards of the receiver to avoid double-counting.
    /// @notice The sender should batch the transfer with a `claim` before, to avoid losing rewards.
    function _transfer(address src, address dst, uint wad) internal virtual override returns (bool) {
        _updateUserRewards(dst);
        return super._transfer(src, dst, wad);
    }
}
