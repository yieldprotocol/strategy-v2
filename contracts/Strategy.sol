// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;

import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/ERC20Permit.sol";
import "@yield-protocol/utils-v2/contracts/token/TransferHelper.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/yieldspace-interfaces/IPool.sol";
import "@yield-protocol/vault-interfaces/DataTypes.sol";


interface ILadle {
    function joins(bytes6) external view returns (address);
    function cauldron() external view returns (ICauldron);
    function build(bytes6 seriesId, bytes6 ilkId, uint8 salt) external returns (bytes12 vaultId, DataTypes.Vault memory vault);
    function destroy(bytes12 vaultId) external;
    function pour(bytes12 vaultId, address to, int128 ink, int128 art) external;
}

interface ICauldron {
    function assets(bytes6) external view returns (address);
    function series(bytes6) external view returns (DataTypes.Series memory);
}

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

library CastU128I128 {
    /// @dev Safely cast an uint128 to an int128
    function i128(uint128 x) internal pure returns (int128 y) {
        require (x <= uint128(type(int128).max), "Cast overflow");
        y = int128(x);
    }
}

/// @dev The Pool contract exchanges base for fyToken at a price defined by a specific formula.
contract Strategy is AccessControl, ERC20Permit {
    using CastU256U128 for uint256;
    using CastU256U32 for uint256;
    using CastU128I128 for uint128;

    event LadleSet(ILadle ladle);
    event TokenJoinReset(address join);
    event TokenIdSet(bytes6 id);
    event LimitsSet(uint128 low, uint128 high);
    event RewardsSet(IERC20 reward, uint192 rate, uint32 start, uint32 end);
    event PoolSwapped(address pool, bytes6 seriesId);
    event Claimable(address user, uint256 claimable);
    event Claimed(address user, uint256 claimed);

    struct Limits {
        uint128 low;
        uint128 high;
    }

    struct Schedule {
        uint192 rate;                            // Reward schedule rate
        uint32 start;                            // Start time for the current reward schedule
        uint32 end;                              // End time for the current reward schedule
    }

    IERC20 public immutable base;                // Base token for this strategy
    bytes6 public baseId;                        // Identifier for the base token in Yieldv2
    address public baseJoin;                     // Yield v2 Join to deposit token when borrowing
    ILadle public ladle;                         // Gateway to the Yield v2 Collateralized Debt Engine
    Limits public limits;                        // Limits for unallocated funds
    IPool public pool;                           // Pool that this strategy invests in
    IFYToken public fyToken;                     // Current fyToken for this strategy
    uint256 public buffer;                       // Unallocated base token in this strategy
    bytes12 public vaultId;                      // Vault used to borrow fyToken

    IMintableERC20 public reward;                // Token used for additional rewards
    Schedule public schedule;                    // Reward schedule
    mapping (address => uint32) public claimed;  // Last time at which each user claimed rewards

    constructor(ILadle ladle_, IERC20 base_, bytes6 baseId_)
        ERC20Permit(
            "Yield LP Strategy",
            "fyLPSTRAT",
            18
        )
    { 
        require(
            ladle_.cauldron().assets(baseId_) == address(base_),
            "Mismatched baseId"
        );
        base = base_;
        baseId = baseId_;
        baseJoin = ladle_.joins(baseId_);

        ladle = ladle_;

        limits = Limits({
            low: 0,
            high: type(uint128).max
        });
    }

    /// @dev Set a new Ladle
    /// @notice Use with extreme caution, only for Ladle replacements
    function setLadle(ILadle ladle_)
        public
        auth
    {
        ladle = ladle_;
        emit LadleSet(ladle_);
    }

    /// @dev Set a new base token id
    /// @notice Use with extreme caution, only for token reconfigurations in Cauldron
    function setTokenId(bytes6 baseId_)
        public
        auth
    {
        require(
            ladle.cauldron().assets(baseId_) == address(base),
            "Mismatched baseId"
        );
        baseId = baseId_;
        emit TokenIdSet(baseId_);
    }

    /// @dev Reset the base token join
    /// @notice Use with extreme caution, only for Join replacements
    function resetTokenJoin()
        public
        auth
    {
        baseJoin = ladle.joins(baseId);
        emit TokenJoinReset(baseJoin);
    }

    /// @dev Set the buffer limits
    function setLimits(uint128 low_, uint128 high_)
        public
        auth
    {
        require (
            low_ <= high_,
            "Limits limits error"
        );

        limits = Limits({
            low: low_,
            high: high_
        });
        emit LimitsSet(low_, high_);
    }

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

    /// @dev Swap funds to a new pool (auth)
    /// @notice First the strategy must be fully divested from the old pool.
    /// @notice First the strategy must repaid all debts from the old series.
    function swap(IPool pool_, bytes6 seriesId_)
        public
        auth
    {
        ICauldron cauldron = ladle.cauldron();
        DataTypes.Series memory series = cauldron.series(seriesId_);
        require(
            series.fyToken == pool_.fyToken(),
            "Mismatched seriesId"
        );

        if (vaultId != bytes12(0)) ladle.destroy(vaultId); // This will revert unless the vault has been emptied
        
        // Build a new vault
        (vaultId, ) = ladle.build(seriesId_, baseId, 0);
        pool = pool_;
        fyToken = pool_.fyToken();
        emit PoolSwapped(address(pool_), seriesId_);
    }

    /// @dev Value of the strategy in base token terms
    function strategyValue()
        external view
        returns (uint256 strategy)
    {
        strategy = _strategyValue();
    }

    /// @dev Value of the strategy in base token terms
    function _strategyValue()
        internal view
        returns (uint256 strategy)
    {
        //  - Can we use 1 fyToken = 1 base for this purpose? It overvalues the value of the strategy.
        //  - If so lpTokens/lpSupply * (lpReserves + lpFYReserves) + unallocated = value_in_token(strategy)
        strategy = (base.balanceOf(address(pool)) + fyToken.balanceOf(address(pool)) * 
            pool.balanceOf(address(this))) / pool.totalSupply() + buffer;
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
    function mint(address to)
        public
        returns (uint256 minted)
    {
        // Find value of strategy
        // Find value of deposit. Straightforward if done in base
        // minted = supply * deposit/strategy
        uint256 deposited = base.balanceOf(address(this)) - buffer;
        minted = _totalSupply - deposited / _strategyValue();
        buffer += deposited;

        _adjustClaimable(to, minted);
        _mint(to, minted);
    }

    /// @dev We adjust the claimable rewards of the receiver in a transfer
    /// @notice The claimable rewards of the transferred strategy tokens are lost. Batch with `claim`.
    function _transfer(address src, address dst, uint wad) internal virtual override returns (bool) {
        _adjustClaimable(dst, wad);
        return super._transfer(src, dst, wad);
    }

    /// @dev Burn strategy tokens to withdraw funds. Replenish the available funds limits if below levels
    /// @notice The claimable rewards of the transferred strategy tokens are lost. Batch with `claim`.
    function burn(address to)
        public
        returns (uint256 withdrawal)
    {
        // Find value of strategy
        // Find value of burnt tokens. Straightforward if withdrawal done in base
        // strategy * burnt/supply = withdrawal
        uint256 toBurn = _balanceOf[address(this)];
        withdrawal = _strategyValue() * toBurn / _totalSupply;

        // Divest if the withdrawal would lead to `buffer` below `limits.low`
        if (withdrawal > buffer || buffer - withdrawal < limits.low) {
            _fillBuffer(withdrawal, 0, 0/* minTokenReceived, minFYTokenReceived*/); // TODO: Set slippage via governance, and calculate limits on the fly
        }
        buffer -= withdrawal;
        _burn(address(this), toBurn);
        base.transfer(to, withdrawal);
    }

    /// @dev Fill the available funds limits to the high limits limit
    function fillBuffer(uint256 minTokenReceived, uint256 minFYTokenReceived)
        public
        auth
        returns (uint256 tokenDivested, uint256 fyTokenDivested)
    {
        (tokenDivested, fyTokenDivested) = _fillBuffer(0, minTokenReceived, minFYTokenReceived);
    }

    /// @dev Fill the available funds limits, after an hypothetical withdrawal
    function _fillBuffer(uint256 withdrawal, uint256 minTokenReceived, uint256 minFYTokenReceived)
        internal
        returns (uint256 tokenDivested, uint256 fyTokenDivested)
    {
        require(
            buffer - withdrawal < limits.high,
            "Limits is full"
        );

        // Find out how many lp tokens we need to burn so that buffer - withdrawal = bufferHigh
        uint256 toObtain = limits.high + withdrawal - buffer;
        // Find value of lp tokens in base terms, scaled up for precision
        uint256 lpValueUp = (1e18 * (base.balanceOf(address(pool)) + fyToken.balanceOf(address(pool)))) / pool.totalSupply();
        uint256 toDivest = (1e18 * toObtain) / lpValueUp;
        // Divest and repay
        (tokenDivested, fyTokenDivested) = divestAndRepay(toDivest, minTokenReceived, minFYTokenReceived);
    }

    /// @dev Invest available funds from the strategy into YieldSpace LP (auth) - Borrow and mint
    function borrowAndInvest(uint256 tokenInvested, uint256 min)
        public
        auth
        returns (uint256 minted)
    {
        buffer -= tokenInvested;

        // Find pool proportion p = fyTokenReserves/tokenReserves
        uint256 proportion = 1e18 * fyToken.balanceOf(address(pool)) / base.balanceOf(address(pool));
        // Deposit (investment * p) base to borrow (investment * p) fyToken
        //   (investment * p) fyToken + (investment * (1 - p)) base = investment
        //   (investment * p) / ((investment * p) + (investment * (1 - p))) = p
        //   (investment * (1 - p)) / ((investment * p) + (investment * (1 - p))) = 1 - p
        uint256 fyTokenToPool = tokenInvested * proportion / 1e18;
        uint256 tokenToPool = tokenInvested - fyTokenToPool;

        base.transfer(baseJoin, fyTokenToPool);
        int128 fyTokenToPool_ = fyTokenToPool.u128().i128();
        ladle.pour(vaultId, address(pool), fyTokenToPool_, fyTokenToPool_);

        // Mint LP tokens with (investment * p) fyToken and (investment * (1 - p)) base
        base.transfer(address(pool), tokenToPool);
        (,, minted) = pool.mint(address(this), true, min);
    }

    /// @dev Invest available funds from the strategy into YieldSpace LP (auth) - Buy and mint
    /// @notice Decide off-chain how much fyToken to buy
    function buyAndInvest(uint256 tokenInvested, uint256 fyTokenToBuy, uint256 minTokensMinted)
        public
        auth
        returns (uint256 minted)
    {
        buffer -= tokenInvested;
        base.transfer(address(pool), tokenInvested);
        (,, minted) = pool.mintWithBase(address(this), fyTokenToBuy, minTokensMinted);
    }

    /// @dev Divest from YieldSpace LP into available funds for the strategy (auth) - Burn and repay
    function divestAndRepay(uint256 lpBurnt, uint256 minTokenReceived, uint256 minFYTokenReceived)
        public
        auth
        returns (uint256 tokenDivested, uint256 fyTokenDivested)
    {
        // Burn lpTokens
        pool.transfer(address(pool), lpBurnt);
        (, tokenDivested, fyTokenDivested) = pool.burn(address(this), minTokenReceived, minFYTokenReceived);
        // Repay with fyToken. Reverts if there isn't enough debt
        fyToken.transfer(address(fyToken), fyTokenDivested);
        int128 fyTokenDivested_ = fyTokenDivested.u128().i128();
        ladle.pour(vaultId, address(this), fyTokenDivested_, fyTokenDivested_);
        buffer += tokenDivested;  
    }

    /// @dev Divest from YieldSpace LP into available funds for the strategy (auth) - Burn and sell
    function divestAndSell(uint256 lpBurnt, uint256 minTokenReceived)
        public
        auth
        returns (uint256 tokenDivested)
    {
        // Burn lpTokens, selling all obtained fyToken
        pool.transfer(address(pool), lpBurnt);
        (, tokenDivested) = pool.burnForBase(address(this), minTokenReceived);
        buffer += tokenDivested;
    }

    /// @dev Divest from YieldSpace LP into available funds for the strategy (auth) - Burn and redeem
    function divestAndRedeem(uint256 lpBurnt, uint256 minTokenReceived, uint256 minFYTokenReceived)
        public
        auth
        returns (uint256 tokenDivested)
    {
        // Burn lpTokens
        pool.transfer(address(pool), lpBurnt);
        uint256 fyTokenDivested;
        (, tokenDivested, fyTokenDivested) = pool.burn(address(this), minTokenReceived, minFYTokenReceived);
        // Redeem all obtained fyToken
        fyToken.transfer(address(fyToken), fyTokenDivested);
        tokenDivested += fyToken.redeem(address(this), fyTokenDivested);
        buffer += tokenDivested;
    }
}
