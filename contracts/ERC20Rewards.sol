// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;

import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/ERC20Permit.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/utils-v2/contracts/utils/RevertMsgExtractor.sol";


library CastU256U32 {
    /// @dev Safely cast an uint256 to an uint32
    function u32(uint256 x) internal pure returns (uint32 y) {
        require (x <= type(uint32).max, "Cast overflow");
        y = uint32(x);
    }
}

library CastU256U128 {
    /// @dev Safely cast an uint256 to an uint128
    function u128(uint256 x) internal pure returns (uint128 y) {
        require (x <= type(uint128).max, "Cast overflow");
        y = uint128(x);
    }
}

/// @dev A token inheriting from ERC20Rewards will reward token holders with a rewards token.
/// The rewarded amount will be a fixed wei per second, distributed proportionally to token holders
/// by the size of their holdings.
contract ERC20Rewards is AccessControl, ERC20Permit {
    using CastU256U32 for uint256;
    using CastU256U128 for uint256;

    event RewardsSet(IERC20 rewardsToken, uint32 start, uint32 end, uint256 rate);
    event RewardsPerTokenUpdated(uint256 accumulated);
    event UserRewardsUpdated(address user, uint256 userRewards, uint256 paidRewardPerToken);
    event Claimed(address receiver, uint256 claimed);

    struct RewardsPeriod {
        uint32 start;                                   // Start time for the current rewardsToken schedule
        uint32 end;                                     // End time for the current rewardsToken schedule
    }

    struct RewardsPerToken {
        uint128 accumulated;                            // Accumulated rewards per token for the period, scaled up by 1e18
        uint32 lastUpdated;                             // Last time the rewards per token accumulator was updated
        uint96 rate;                                    // Wei rewarded per second among all token holders
    }

    IERC20 public rewardsToken;                         // Token used as rewards
    RewardsPeriod public rewardsPeriod;                 // Period in which rewards are accumulated by users

    RewardsPerToken public rewardsPerToken;             // Accumulator to track rewards per token               

    mapping (address => uint128) public rewards;        // Rewards accumulated by users
    mapping (address => uint128) public paidRewardPerToken;    // Last rewards per token level accumulated by each user
    
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

    /// @dev Return the earliest of two timestamps
    function earliest(uint32 x, uint32 y) internal pure returns (uint32 z) {
        z = (x < y) ? x : y;
    }

    /// @dev Return the latest of two timestamps
    function latest(uint32 x, uint32 y) internal pure returns (uint32 z) {
        z = (x > y) ? x : y;
    }

    /// @dev Set a rewards schedule
    /// TODO: Allow sequential schedules, each with their own supply accumulator and rewards accumulator. Only once active schdule at a time.
    function setRewards(IERC20 rewardsToken_, uint32 start, uint32 end, uint96 rate)
        public
        auth
    {
        if (rewardsToken_ != IERC20(address(0))) rewardsToken = rewardsToken_; // TODO: Allow to change only after a safety period after end, to avoid affecting current claimable

        rewardsPeriod = RewardsPeriod({
            start: start,
            end: end
        });

        rewardsPerToken = RewardsPerToken({
            accumulated: 0,
            lastUpdated: start,
            rate: rate
        });

        emit RewardsSet(rewardsToken, start, end, rate);
    }

    /// @dev Update the rewards per token accumulator.
    /// @notice Needs to be called on each liquidity event
    function _updateRewardsPerToken() internal returns (uint128) {
        RewardsPerToken memory rewardsPerToken_ = rewardsPerToken;
        RewardsPeriod memory rewardsPeriod_ = rewardsPeriod;

        // We skip the calculations if we can
        if (_totalSupply == 0 || block.timestamp.u32() < rewardsPeriod_.start) return 0;
        if (rewardsPerToken_.lastUpdated >= rewardsPeriod_.end) return rewardsPerToken_.accumulated;

        // Find out the unaccounted period
        uint32 end = earliest(block.timestamp.u32(), rewardsPeriod_.end);
        uint256 timeSinceLastUpdated = end - rewardsPerToken_.lastUpdated; // Cast to uint256 to avoid overflows later on

        // Calculate and update the new value of the accumulator. timeSinceLastUpdated casts it into uint256, which is desired.
        rewardsPerToken_.accumulated = (rewardsPerToken_.accumulated + 1e18 * timeSinceLastUpdated * rewardsPerToken_.rate / _totalSupply).u128(); // The rewards per token are scaled up for precision
        rewardsPerToken_.lastUpdated = end;
        rewardsPerToken = rewardsPerToken_;
        
        emit RewardsPerTokenUpdated(rewardsPerToken_.accumulated);

        return rewardsPerToken_.accumulated;
    }

    /// @dev Accumulate rewards for an user.
    /// @notice Needs to be called on each liquidity event, or when user balances change.
    function _updateUserRewards(address user) internal returns (uint128 userRewards) {
        RewardsPerToken memory rewardsPerToken_ = rewardsPerToken;
        
        // Calculate and update the new value user reserves. _balanceOf[user] casts it into uint256, which is desired.
        userRewards = (rewards[user] + _balanceOf[user] * (rewardsPerToken_.accumulated - paidRewardPerToken[user]) / 1e18).u128(); // We must scale down the rewards by the precision factor
        rewards[user] = userRewards;
        paidRewardPerToken[user] = rewardsPerToken_.accumulated;
        emit UserRewardsUpdated(user, userRewards, rewardsPerToken_.accumulated);
    }

    /// @dev Mint tokens, after accumulating rewards for an user and update the rewards per token accumulator.
    function _mint(address dst, uint256 wad)
        internal virtual override
        returns (bool)
    {
        _updateRewardsPerToken();
        _updateUserRewards(dst);
        return super._mint(dst, wad);
    }

    /// @dev Burn tokens, after accumulating rewards for an user and update the rewards per token accumulator.
    function _burn(address src, uint256 wad)
        internal virtual override
        returns (bool)
    {
        _updateRewardsPerToken();
        _updateUserRewards(src);
        return super._burn(src, wad);
    }

    /// @dev Transfer tokens, after updating rewards for source and destination.
    function _transfer(address src, address dst, uint wad) internal virtual override returns (bool) {
        _updateUserRewards(src);
        _updateUserRewards(dst);
        return super._transfer(src, dst, wad);
    }

    /// @dev Claim all rewards from caller into a given address
    function claim(address to)
        external
        returns (uint256 claiming)
    {
        claiming = _updateUserRewards(msg.sender);
        rewardsToken.transfer(to, claiming);
        delete rewards[msg.sender]; // A Claimed event implies the rewards were set to zero
        emit Claimed(to, claiming);
    }
}
