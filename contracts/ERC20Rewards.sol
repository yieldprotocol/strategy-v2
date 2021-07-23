// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;

import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/ERC20Permit.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";

interface IMintableERC20 is IERC20 {
    function mint(address, uint256) external;
}

library CastU256U32 {
    /// @dev Safely cast an uint256 to an uint32
    function u32(uint256 x) internal pure returns (uint32 y) {
        require (x <= type(uint32).max, "Cast overflow");
        y = uint32(x);
    }
}

/// @dev The Pool contract exchanges base for fyToken at a price defined by a specific formula.
contract ERC20Rewards is AccessControl, ERC20Permit {
    using CastU256U32 for uint256;

    event RewardsSet(IMintableERC20 reward, uint192 rate, uint32 start, uint32 end);
    event Claimable(address user, uint256 claimable);
    event Claimed(address user, uint256 claimed);

    struct Schedule {
        uint192 rate;                            // Reward schedule rate
        uint32 start;                            // Start time for the current reward schedule
        uint32 end;                              // End time for the current reward schedule
    }

    IMintableERC20 public reward;                // Token used for additional rewards
    Schedule public schedule;                    // Reward schedule
    mapping (address => uint32) public claimed;  // Last time at which each user claimed rewards

    constructor(string memory name, string memory symbol, uint8 decimals)
        ERC20Permit(name, symbol, decimals)
    { }

    /// @dev Set a rewards schedule
    /// @notice The rewards token can be changed, but that won't affect past claims, use with care.
    /// @notice There is only one schedule with one rate, so a change to the schedule will affect all unclaimed rewards, use with care.
    function setRewards(IMintableERC20 reward_, uint192 rate, uint32 start, uint32 end)
        public
        auth
    {
        if (reward_ != IMintableERC20(address(0))) reward = reward_;

        Schedule memory schedule_ = schedule;
        schedule_.rate = rate;
        schedule_.start = start;
        schedule_.end = end;
        schedule = schedule_;
        emit RewardsSet(reward, schedule_.rate, schedule_.start, schedule_.end);
    }

    /// @dev Length of time that the user can claim rewards for.
    function _claimablePeriod(address user)
        internal view
        returns (uint32 period)
    {
        Schedule memory schedule_ = schedule;
        uint32 lastClaimed = claimed[user];
        uint32 start = lastClaimed > schedule_.start ? lastClaimed : schedule_.start; // max
        uint32 end = uint32(block.timestamp) < schedule_.end ? uint32(block.timestamp) : schedule_.end; // min
        period = (end > start) ? end - start : 0;
    }

    /// @dev The claimable reward tokens are the total rewards since the last claim for the user multiplied by the proportion
    /// of strategy tokens the user holds with regards to the total strategy token supply.
    /// To allow the schedule rate to change the current schedule level is `recorded + rate * (now - start)`
    /// Since users can claim at any time, their claimable are (current level - last claimed level) * (user balance / total supply)
    function _claimable(address user)
        internal view
        returns (uint256 claimable)
    {
        uint256 totalRewards = uint256(schedule.rate) * _claimablePeriod(user); // TODO: schedule.rate could be returned from _claimablePeriod, or schedule be given to _claimablePeriod
        claimable = totalRewards * _balanceOf[user] / _totalSupply;        
    }

    /// @dev Adjust the claimable tokens by increasing the claimed timestamp proportionally upwards with the tokens received.
    /// In other words, any received tokens don't benefit from the accumulated claimable level.
    function _adjustClaimable(address user, uint256 added)
        internal
        returns (uint32 adjustment)
    {
        uint256 oldBalance = _balanceOf[user];
        uint256 newBalance = oldBalance + added;

        adjustment = ((_claimablePeriod(user) * (newBalance - oldBalance)) / newBalance).u32();
        claimed[user] += adjustment;
        emit Claimable(user, adjustment);       
    }

    /// @dev Claim all rewards tokens available to the owner
    function claim(address to)
        public
        returns (uint256 claiming)
    {
        claiming = _claimable(msg.sender);
        claimed[msg.sender] = uint32(block.timestamp);
        reward.mint(to, claiming);
        emit Claimed(to, claiming);
    }

    /// @dev Mint strategy tokens. The underlying tokens that the user contributes need to have been transferred previously.
    /// @notice The claimable rewards of the transferred strategy tokens are lost if burning. Batch `burn` with `claim`.
    function _mint(address dst, uint256 wad)
        internal virtual override
        returns (bool)
    {
        _adjustClaimable(dst, wad);
        return super._mint(dst, wad);
    }

    /// @dev We adjust the claimable rewards of the receiver in a transfer
    /// @notice The claimable rewards of the transferred strategy tokens are lost. Batch with `claim`.
    function _transfer(address src, address dst, uint wad) internal virtual override returns (bool) {
        _adjustClaimable(dst, wad);
        return super._transfer(src, dst, wad);
    }
}
