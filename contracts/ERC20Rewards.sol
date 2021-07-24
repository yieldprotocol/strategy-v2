// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;

import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/ERC20Permit.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";


interface IMintableERC20 is IERC20 {
    function mint(address, uint256) external;
}

library CastU256U128 {
    /// @dev Safely cast an uint256 to an uint128
    function u128(uint256 x) internal pure returns (uint128 y) {
        require (x <= type(uint128).max, "Cast overflow");
        y = uint128(x);
    }
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
    using CastU256U128 for uint256;

    event RewardsSet(IMintableERC20 rewardToken, uint32 start, uint32 end, uint128 rate, uint128 available);
    event Claimable(address user, uint256 claimable);
    event Claimed(address user, uint256 claimed);

    struct RewardPeriod {
        uint32 start;                               // Start time for the current rewardToken schedule
        uint32 end;                                 // End time for the current rewardToken schedule
    }

    struct RewardEmissions {
        uint128 rate;                               // Reward schedule rate. Wei rewarded per second per 1e18 wei held
        uint128 available;                          // Wei that will be rewarded
    }

    IMintableERC20 public rewardToken;              // Token used for additional rewards
    RewardPeriod public rewardPeriod;               // Reward period
    RewardEmissions public rewardEmissions;         // How much will be rewarded
    mapping (address => uint32) public lastClaimed; // Last time at which each user claimed rewards

    constructor(string memory name, string memory symbol, uint8 decimals)
        ERC20Permit(name, symbol, decimals)
    { }

    /// @dev Set a rewards schedule
    /// @notice The rewards token can be changed, but that won't affect past claims, use with care.
    /// @notice There is only one schedule with one rate, so a change to the schedule will affect all unclaimed rewards, use with care.
    function setRewards(IMintableERC20 rewardToken_, uint32 start, uint32 end, uint128 rate, uint128 available)
        public
        auth
    {
        if (rewardToken_ != IMintableERC20(address(0))) rewardToken = rewardToken_; // TODO: Allow to change only after a safety period after end, to avoid affecting current claimable

        RewardPeriod memory rewardPeriod_ = rewardPeriod;
        rewardPeriod_.start = start;                // TODO: Don't allow to set later than end
        rewardPeriod_.end = end;                    // TODO: Don't allow to set to a point in the past, to avoid removing claimable amounts
        rewardPeriod = rewardPeriod_;

        RewardEmissions memory rewardEmissions_ = rewardEmissions;
        rewardEmissions_.rate = rate;               // TODO: Allow to decrease only after a safety period after end, to avoid affecting current claimable
        rewardEmissions_.available = available;     // TODO: Allow to decrease only after a safety period after end, to avoid affecting current claimable
        rewardEmissions = rewardEmissions_;
        emit RewardsSet(rewardToken, start, end, rate, available);
    }

    /// @dev Claim all rewards tokens available to the owner
    function claim(address to)
        public
        returns (uint256 claiming)
    {
        claiming = _claimableAmount(msg.sender);
        lastClaimed[msg.sender] = uint32(block.timestamp);
        rewardEmissions.available -= claiming.u128();
        rewardToken.mint(to, claiming);
        emit Claimed(to, claiming);
    }

    /// @dev Length of time that the user can claim rewards for.
    function claimablePeriod(address user)
        external view
        returns (uint32 period)
    {
        return _claimablePeriod(user);
    }

    /// @dev The claimable rewardToken tokens are user balance multiplied by the emissions rate, counting from the time they last claimed.
    function claimableAmount(address user)
        external view
        returns (uint256 amount)
    {
        return _claimableAmount(user);
    }

    /// @dev Length of time that the user can claim rewards for.
    function _claimablePeriod(address user)
        internal view
        returns (uint32 userPeriod)
    {
        RewardPeriod memory rewardPeriod_ = rewardPeriod;
        uint32 lastClaimed_ = lastClaimed[user];
        uint32 start = lastClaimed_ > rewardPeriod_.start ? lastClaimed_ : rewardPeriod_.start; // max
        uint32 end = uint32(block.timestamp) < rewardPeriod_.end ? uint32(block.timestamp) : rewardPeriod_.end; // min
        userPeriod = (end > start) ? end - start : 0;
    }

    /// @dev The claimable rewardToken tokens are user balance multiplied by the emissions rate, counting from the time they last claimed.
    function _claimableAmount(address user)
        internal view
        returns (uint256 amount)
    {
        RewardEmissions memory emissions = rewardEmissions;
        amount = _balanceOf[user] * _claimablePeriod(user) * emissions.rate / 1e18;
        amount = (amount < emissions.available) ? amount : emissions.available;
    }

    /// @dev Adjust the claimable tokens by increasing the claimed timestamp proportionally upwards with the tokens received.
    /// In other words, any received tokens don't benefit from the accumulated claimable level.
    function _adjustClaimable(address user, uint256 added)
        internal
        returns (uint32 adjustment)
    {
        if (lastClaimed[user] == 0) {
            lastClaimed[user] = block.timestamp.u32();
        } else {
            uint256 oldBalance = _balanceOf[user];
            uint256 newBalance = oldBalance + added;

            adjustment = ((_claimablePeriod(user) * (newBalance - oldBalance)) / newBalance).u32();
            lastClaimed[user] += adjustment;
            emit Claimable(user, adjustment);
        }
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
