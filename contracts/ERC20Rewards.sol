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

/// @dev A token inheriting from ERC20Rewards will reward token holders with a rewards token.
/// The rewarded amount will be a fixed wei per second, distributed proportionally to token holders
/// by the size of their holdings.
contract ERC20Rewards is AccessControl, ERC20Permit {
    using CastU256U32 for uint256;

    event RewardsSet(IERC20 rewardsToken, uint32 start, uint32 end, uint256 rate);
    event RewardsPerToken(uint256 rewardsPerToken);
    event UserRewards(address user, uint256 userRewards, uint256 rewardsPerTokenStored);
    event Claimed(address receiver, uint256 claimed);

    struct RewardsPeriod {
        uint32 start;                                   // Start time for the current rewardsToken schedule
        uint32 end;                                     // End time for the current rewardsToken schedule
    }

    IERC20 public rewardsToken;                         // Token used as rewards
    RewardsPeriod public rewardsPeriod;                  // Period in which rewards are accumulated by users
    uint256 public rewardsRate;                         // Wei rewarded per second among all token holders

    uint256 public rewardsPerTokenStored;               // Accumulated rewards per token (1e18) for the period
    uint32 public lastUpdated;                          // Last time the rewards per token accumulator was updated

    mapping (address => uint256) public rewards;        // Rewards accumulated by users
    mapping (address => uint256) public paidRewardPerToken;    // Last rewards per token level accumulated by each user
    
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
    function setRewards(IERC20 rewardsToken_, uint32 start, uint32 end, uint256 rate)
        public
        auth
    {
        if (rewardsToken_ != IERC20(address(0))) rewardsToken = rewardsToken_; // TODO: Allow to change only after a safety period after end, to avoid affecting current claimable

        RewardsPeriod memory rewardsPeriod_ = rewardsPeriod;
        rewardsPeriod_.start = start;
        rewardsPeriod_.end = end;
        rewardsPeriod = rewardsPeriod_;

        rewardsRate = rate;

        lastUpdated = start; // 
        emit RewardsSet(rewardsToken, start, end, rate);
    }

    /// @dev Update the rewards per token accumulator.
    /// @notice Needs to be called on each liquidity event
    function _updateRewardsPerToken() internal returns (uint256 rewardsPerToken) {
        if (_totalSupply == 0 || block.timestamp.u32() < rewardsPeriod.start) return 0;
        if (lastUpdated >= rewardsPeriod.end) return rewardsPerTokenStored;

        uint32 end = earliest(block.timestamp.u32(), rewardsPeriod.end);
        uint256 timeSinceLastUpdated = end - lastUpdated; // Cast out to avoid overflows later on

        rewardsPerToken = rewardsPerTokenStored + 1e18 * timeSinceLastUpdated * rewardsRate / _totalSupply; // The rewards per token are scaled up for precision
        rewardsPerTokenStored = rewardsPerToken;
        lastUpdated = end;
        emit RewardsPerToken(rewardsPerToken);
    }

    /// @dev Accumulate rewards for an user.
    /// @notice Needs to be called on each liquidity event, or when user balances change.
    function _updateUserRewards(address user) internal returns (uint256 userRewards) {
        uint256 rewardsPerTokenStored_ = rewardsPerTokenStored;
        
        userRewards = rewards[user] + _balanceOf[user] * (rewardsPerTokenStored_ - paidRewardPerToken[user]) / 1e18; // We must scale down the rewards by the precision factor

        rewards[user] = userRewards;
        paidRewardPerToken[user] = rewardsPerTokenStored_;
        emit UserRewards(user, userRewards, rewardsPerTokenStored_);
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
