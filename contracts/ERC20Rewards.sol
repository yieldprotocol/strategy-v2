// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;

import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/ERC20Permit.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";


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

    event RewardsSet(IERC20 rewardToken, uint32 start, uint32 end, uint256 rate);
    event Claimable(address user, uint256 claimable);
    event Claimed(address user, uint256 claimed);

    struct RewardPeriod {
        uint32 start;                               // Start time for the current rewardToken schedule
        uint32 end;                                 // End time for the current rewardToken schedule
    }

    IERC20 public rewardToken;                      // Token used as rewards
    RewardPeriod public rewardPeriod;               // Reward period
    uint256 public rewardRate;                      // Wei rewarded per second
    uint256 public averageSupply;                   // Average supply from the start of the period until the last update
    uint32 public lastUpdated;                      // Timestamp for the last liquidity event
    mapping (address => uint256) public claimed;    // Amount claimed by each user so far

    constructor(string memory name, string memory symbol, uint8 decimals)
        ERC20Permit(name, symbol, decimals)
    { }

    /// @dev Set a rewards schedule
    function setRewards(IERC20 rewardToken_, uint32 start, uint32 end, uint256 rate)
        public
        auth
    {
        if (rewardToken_ != IERC20(address(0))) rewardToken = rewardToken_; // TODO: Allow to change only after a safety period after end, to avoid affecting current claimable

        RewardPeriod memory rewardPeriod_ = rewardPeriod;
        rewardPeriod_.start = start;                // TODO: Don't allow to set later than end
        rewardPeriod_.end = end;                    // TODO: Don't allow to set to a point in the past, to avoid removing claimable amounts
        rewardPeriod = rewardPeriod_;

        rewardRate = rate;                         // TODO: Allow to decrease only after a safety period after end, to avoid affecting current claimable
        emit RewardsSet(rewardToken, start, end, rate);
    }

    /// @dev Claim all rewards from caller into a given address
    function claim(address to)
        public
        returns (uint256 claiming)
    {
        claimed[msg.sender] += claiming = _claimableAmount(msg.sender);
        rewardToken.transfer(to, claiming);
        emit Claimed(to, claiming);
    }

    /// @dev Length of time into the rewards schedule.
    function claimablePeriod()
        external view
        returns (uint32 period)
    {
        return _claimablePeriod();
    }

    /// @dev Claimable rewards for a given user.
    function claimableAmount(address user)
        external view
        returns (uint256 amount)
    {
        return _claimableAmount(user);
    }

    /// @dev Length of time into the rewards schedule.
    function _claimablePeriod()
        internal view
        returns (uint32 userPeriod)
    {
        RewardPeriod memory rewardPeriod_ = rewardPeriod;
        uint32 start = block.timestamp.u32() > rewardPeriod_.start ? block.timestamp.u32() : rewardPeriod_.start; // max
        uint32 end = block.timestamp.u32() < rewardPeriod_.end ? block.timestamp.u32() : rewardPeriod_.end; // min
        userPeriod = (end > start) ? end - start : 0;
    }

    /// @dev Claimable rewards for a given user.
    /// Elapsed rewards period * User holdings * Rewards per second per token - Already claimed rewards
    function _claimableAmount(address user)
        internal view
        returns (uint256 amount)
    {
        uint256 rewardsPerTokenPerSecond = rewardRate / averageSupply;
        amount = _claimablePeriod() * _balanceOf[user] * rewardsPerTokenPerSecond - claimed[user];
    }

    /// @dev Update the average supply as the time-weighted average between the previous average until the previous update,
    /// and the current supply level from the previous update until now.
    function _update()
        internal
        returns (uint256 _averageSupply)
    {
        uint32 storedEnd = (lastUpdated > rewardPeriod.start) ? lastUpdated : rewardPeriod.start;
        uint32 storedPeriod = storedEnd - rewardPeriod.start;
        uint32 currentEnd = (block.timestamp.u32() > rewardPeriod.end) ? rewardPeriod.end : block.timestamp.u32();
        uint32 currentPeriod = currentEnd - block.timestamp.u32();

        averageSupply = _averageSupply =  (averageSupply * storedPeriod + _totalSupply * currentPeriod) / (storedPeriod + currentPeriod);
        lastUpdated = block.timestamp.u32();
    }

    /// @dev Mint tokens, updating the supply average before.
    function _mint(address dst, uint256 wad)
        internal virtual override
        returns (bool)
    {
        _update();
        return super._mint(dst, wad);
    }

    /// @dev Burn tokens, updating the supply average before.
    function _burn(address src, uint256 wad)
        internal virtual override
        returns (bool)
    {
        _update();
        return super._burn(src, wad);
    }

    /// @dev Transfer tokens, adjusting upwards the claimed rewards of the receiver to avoid double-counting.
    /// @notice The sender should batch the transfer with a `claim` before, to avoid losing rewards.
    function _transfer(address src, address dst, uint wad) internal virtual override returns (bool) {
        uint256 rewardsPerTokenPerSecond = rewardRate / averageSupply;
        claimed[dst] += _claimablePeriod() * wad * rewardsPerTokenPerSecond; // Renounce to any claims from the received tokens
        return super._transfer(src, dst, wad);
    }
}
