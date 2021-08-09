// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;

import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/TransferHelper.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/utils-v2/contracts/token/ERC20Rewards.sol";
import "@yield-protocol/vault-interfaces/DataTypes.sol";
// import "@yield-protocol/yieldspace-interfaces/IPool.sol";

interface ILadle {
    function joins(bytes6) external view returns (address);
    function cauldron() external view returns (ICauldron);
    function build(bytes6 seriesId, bytes6 ilkId, uint8 salt) external returns (bytes12 vaultId, DataTypes.Vault memory vault);
    function tweak(bytes12 vaultId, bytes6 seriesId, bytes6 ilkId) external returns (DataTypes.Vault memory vault);
    function destroy(bytes12 vaultId) external;
    function pour(bytes12 vaultId, address to, int128 ink, int128 art) external;
    function close(bytes12 vaultId, address to, int128 ink, int128 art) external;
}

interface ICauldron {
    function assets(bytes6) external view returns (address);
    function series(bytes6) external view returns (DataTypes.Series memory);
    function balances(bytes12) external view returns (DataTypes.Balances memory);
    function debtToBase(bytes6 seriesId, uint128 art) external view returns (uint128);
}

interface IPool is IERC20, IERC2612 {
    function base() external view returns(IERC20);
    function fyToken() external view returns(IFYToken);
    function maturity() external view returns(uint32);
    function getBaseBalance() external view returns(uint112);
    function getFYTokenBalance() external view returns(uint112);
    function retrieveBase(address to) external returns(uint128 retrieved);
    function retrieveFYToken(address to) external returns(uint128 retrieved);
    function sellBase(address to, uint128 min) external returns(uint128);
    function buyBase(address to, uint128 baseOut, uint128 max) external returns(uint128);
    function sellFYToken(address to, uint128 min) external returns(uint128);
    function buyFYToken(address to, uint128 fyTokenOut, uint128 max) external returns(uint128);
    function sellBasePreview(uint128 baseIn) external view returns(uint128);
    function buyBasePreview(uint128 baseOut) external view returns(uint128);
    function sellFYTokenPreview(uint128 fyTokenIn) external view returns(uint128);
    function buyFYTokenPreview(uint128 fyTokenOut) external view returns(uint128);
    function mint(address to, bool calculateFromBase, uint256 minTokensMinted) external returns (uint256, uint256, uint256);
    function mintWithBase(address to, uint256 fyTokenToBuy, uint256 minTokensMinted) external returns (uint256, uint256, uint256);
    function burn(address to, uint256 minBaseOut, uint256 minFYTokenOut) external returns (uint256, uint256, uint256);
    function burnForBase(address to, uint256 minBaseOut) external returns (uint256, uint256);
    function getCache() external view returns (uint112, uint112, uint32);
}

library CastU128I128 {
    /// @dev Safely cast an uint128 to an int128
    function i128(uint128 x) internal pure returns (int128 y) {
        require (x <= uint128(type(int128).max), "Cast overflow");
        y = int128(x);
    }
}

/// @dev The Pool contract exchanges base for fyToken at a price defined by a specific formula.
contract Strategy is AccessControl, ERC20Rewards {
    using CastU256U128 for uint256; // Inherited from ERC20Rewards
    using CastU128I128 for uint128;

    event YieldSet(ILadle ladle, ICauldron cauldron);
    event TokenJoinReset(address join);
    event TokenIdSet(bytes6 id);
    event LimitsSet(uint80 low, uint80 mid, uint80 high);
    event PoolDeviationRateSet(uint256 poolDeviationRate);
    event NextPoolSet(IPool indexed pool, bytes6 indexed seriesId);
    event PoolEnded(address pool);
    event PoolStarted(address pool);
    event PoolWarmed(address pool, uint112 cachedBaseReserves, uint112 cachedFYTokenReserves);
    event Invest(uint256 minted);
    event Divest(uint256 burnt);

    struct Limits {                              // Buffer limits, in 1e18 units
        uint80 low;                              // If the buffer would drop below this level, it fills to mid 
        uint80 mid;                              // Target buffer level
        uint80 high;                             // If the buffer would drop below this level, it drains to mid
    }

    struct PoolCache {                           // Pool reserves and timestamp
        uint112 base;                            // Cached base reserves
        uint112 fyToken;                         // Cached fyToken reserves
        uint32 timestamp;                        // Last time pool reserves cached locally
    }

    uint32 constant public TWAR_INTERVAL = 3600; // Seconds to use on the stat pool TWAP
    uint32 constant public START_DELAY = 3600;   // Seconds between the first cache reading for a next pool and it starting

    IERC20 public immutable base;                // Base token for this strategy
    bytes6 public baseId;                        // Identifier for the base token in Yieldv2
    address public baseJoin;                     // Yield v2 Join to deposit token when borrowing
    ILadle public ladle;                         // Gateway to the Yield v2 Collateralized Debt Engine
    ICauldron public cauldron;                   // Accounts in the Yield v2 Collateralized Debt Engine
    bytes12 public vaultId;                      // Vault used to borrow fyToken

    Limits public limits;                        // Limits for unallocated funds
    uint256 public buffer;                       // Unallocated base token in this strategy

    IPool public pool;                           // Current pool that this strategy invests in
    PoolCache public poolCache;                  // Local cache of pool reserves
    bytes6 public seriesId;                      // SeriesId for the current pool in Yield v2
    IFYToken public fyToken;                     // Current fyToken for this strategy

    IPool public nextPool;                       // Next pool that this strategy will invest in
    PoolCache public nextPoolCache;              // Local cache of pool reserves for the next pool
    bytes6 public nextSeriesId;                  // SeriesId for the next pool in Yield v2
    uint32 public nextPoolStart;                 // Time at which the next pool can be started

    uint256 public poolDeviationRate;            // Accepted deviation of the pool reserves, per second since last investment event

    constructor(string memory name, string memory symbol, uint8 decimals, ILadle ladle_, IERC20 base_, bytes6 baseId_)
        ERC20Rewards(name, symbol, decimals)
    { 
        require(
            ladle_.cauldron().assets(baseId_) == address(base_),
            "Mismatched baseId"
        );
        base = base_;
        baseId = baseId_;
        baseJoin = ladle_.joins(baseId_);

        ladle = ladle_;
        cauldron = ladle_.cauldron();

        // This set of limits disables investing
        limits = Limits({
            low: 0,
            mid: 0,
            high: type(uint80).max
        });

        // This deviation rate allows a 1% deviation per second
        poolDeviationRate = 1e16;
    }

    modifier beforeMaturity() {
        require (
            fyToken.maturity() >= uint32(block.timestamp),
            "Only before maturity"
        );
        _;
    }

    modifier afterMaturity() {
        require (
            fyToken == IFYToken(address(0)) || fyToken.maturity() < uint32(block.timestamp),
            "Only after maturity"
        );
        _;
    }

    /// @dev Set a new Ladle and Cauldron
    /// @notice Use with extreme caution, only for Ladle replacements
    function setYield(ILadle ladle_, ICauldron cauldron_)
        public
        afterMaturity
        auth
    {
        ladle = ladle_;
        cauldron = ladle_.cauldron();
        emit YieldSet(ladle_, cauldron_);
    }

    /// @dev Set a new base token id
    /// @notice Use with extreme caution, only for token reconfigurations in Cauldron
    function setTokenId(bytes6 baseId_)
        public
        afterMaturity
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
        afterMaturity
        auth
    {
        baseJoin = ladle.joins(baseId);
        emit TokenJoinReset(baseJoin);
    }

    /// @dev Set the buffer limits
    function setLimits(uint80 low_, uint80 mid_, uint80 high_)
        public
        auth
    {
        require (
            low_ <= mid_ && mid_ <= high_,
            "Inconsistent buffer limits"
        );

        limits = Limits({
            low: low_,
            mid: mid_,
            high: high_
        });
        emit LimitsSet(low_, mid_, high_);
    }

    /// @dev Set the buffer limits
    function setPoolDeviationRate(uint256 poolDeviationRate_)
        public
        auth
    {
        poolDeviationRate = poolDeviationRate_;
        emit PoolDeviationRateSet(poolDeviationRate_);
    }

    /// @dev Set the next pool to invest in
    function setNextPool(IPool pool_, bytes6 seriesId_) 
        public
        auth
    {
        DataTypes.Series memory series = cauldron.series(seriesId_);
        require(
            series.fyToken == pool_.fyToken(),
            "Mismatched seriesId"
        );

        nextPool = pool_;
        nextSeriesId = seriesId_;
        
        // Reset the pool start TWAP
        delete nextPoolCache;
        delete nextPoolStart;

        emit NextPoolSet(pool_, seriesId_);
    }

    /// @dev Initialize this contract, minting a number of strategy tokens equal to the base balance of the strategy
    /// @notice The funds for initialization must have been sent previously, using a batchable router.
    function init(address to)
        public
        auth
    {
        require (_totalSupply == 0, "Already initialized");
        buffer = base.balanceOf(address(this));
        _mint(to, buffer);
    }

    /// @dev Divest out of a pool once it has matured
    function endPool()
        public
        afterMaturity
    {
        // Divest fully, all debt in the vault should be repaid and collateral withdrawn into the buffer
        // With a bit of extra code, the collateral could be left in the vault
        uint256 toDivest = pool.balanceOf(address(this));
        if (toDivest > 0)
            _divestAndRepay(toDivest);

        // Redeem any fyToken surplus
        uint256 toRedeem = fyToken.balanceOf(address(this));
        if (toRedeem > 0) {
            fyToken.transfer(address(fyToken), toRedeem);
            fyToken.redeem(address(this), toRedeem);
        } else {    // There must still be debt, repay with underlying
            uint128 debt = cauldron.balances(vaultId).art;
            base.transfer(address(baseJoin), cauldron.debtToBase(seriesId, debt));
            int128 debt_ = debt.i128();
            ladle.close(vaultId, address(this), -debt_, -debt_);   // Negative ink = withdraw, negative art = repay. Takes a fyToken amount as art parameter
        }

        // Make sure the buffer is up to date
        buffer = base.balanceOf(address(this));

        emit PoolEnded(address(pool));

        // Clear up
        delete pool;
        delete fyToken;
        delete poolCache;
        
        ladle.destroy(vaultId);
        delete vaultId;
    }

    /// @dev Update the next pool TWAP, to avoid getting sandwiched on start pool
    function warmPool()
        public
    {
        require(nextPool != IPool(address(0)), "Next pool not set");

        PoolCache memory nextPoolCache_ = nextPoolCache;
        if (nextPoolCache_.timestamp == 0) nextPoolStart = uint32(block.timestamp) + START_DELAY;

        nextPoolCache = _twarUpdatedCache(nextPoolCache_, _getCache(nextPool));
        emit PoolWarmed(address(nextPool), nextPoolCache_.base, nextPoolCache_.fyToken);
    }

    /// @dev Start the strategy investments in the next pool
    function startPool()
        public
    {
        require(pool == IPool(address(0)), "Current pool exists");
        require(nextPool != IPool(address(0)), "Next pool not set");

        pool = nextPool;
        fyToken = pool.fyToken();
        seriesId = nextSeriesId;
        poolCache = nextPoolCache;      // Swap to the TWAP-updated cache

        require(poolCache.timestamp + START_DELAY <= uint32(block.timestamp), "Warm up process ongoing");
        require(_poolDeviated(poolCache, _getCache(pool)) == false, "Pool reserves changed too fast");

        delete nextPool;
        delete nextSeriesId;
        delete nextPoolCache;

        (vaultId, ) = ladle.build(seriesId, baseId, 0);

        // Make sure the buffer is up to date
        buffer = base.balanceOf(address(this));

        // Invest if there is enough in the buffer
        if (buffer > limits.high) _borrowAndInvest(buffer - limits.mid);

        emit PoolStarted(address(pool));
    }

    /// @dev Value of the strategy in base token terms
    function strategyValue()
        external view
        returns (uint256 value)
    {
        value = _strategyValue();
    }

    /// @dev Value of the strategy in base token terms
    /// @notice LP tokens and fyToken are only counted towards the strategy value for the current pool
    function _strategyValue()
        internal view
        returns (uint256 value)
    {
        //  - Can we use 1 fyToken = 1 base for this purpose? It overvalues the value of the strategy.
        //  - If so lpTokens/lpSupply * (lpReserves + lpFYReserves) + unallocated = value_in_token(strategy)
        if (pool != IPool(address(0))) value =
            ((base.balanceOf(address(pool)) + fyToken.balanceOf(address(pool)))
             * pool.balanceOf(address(this))) / pool.totalSupply()
             + fyToken.balanceOf(address(this))
             + buffer;
        else value = buffer;
    }

    /// @dev Mint strategy tokens. Invests if the available funds end above levels.
    /// @notice The underlying tokens that the user contributes need to have been transferred previously, using a batchable router.
    function mint(address to)
        public
        beforeMaturity
        returns (uint256 minted)
    {
        // Find value of strategy
        // Find value of deposit. Straightforward if done in base
        // minted = supply * deposit/strategy
        uint256 buffer_ = base.balanceOf(address(this));
        uint256 deposit = buffer_ - buffer;
        minted = _totalSupply - deposit / _strategyValue();
        
        // Invest if the buffer has gone over `limits.high`
        if (buffer_ > limits.high) {
            // Find out how much of the buffer we need to invest so that buffer + deposit = buffer.mid
            // Borrow and invest, so that the buffer remains at limits.mid
            _borrowAndInvest(buffer_ - limits.mid);
            buffer = limits.mid;
        } else {
            buffer = buffer_;
        }

        _mint(to, minted);
    }

    /// @dev Burn strategy tokens to withdraw funds. Divests if the available funds would end below levels
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
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
            // Find out how many lp tokens we need to burn so that buffer - withdrawal = buffer.mid
            uint256 toObtain = limits.mid + withdrawal - buffer;
            // Find value of lp tokens in base terms, scaled up for precision
            uint256 lpValueUp = (1e18 * (base.balanceOf(address(pool)) + fyToken.balanceOf(address(pool)))) / pool.totalSupply();
            uint256 toDivest = (1e18 * toObtain) / lpValueUp;   // It doesn't matter if the amount to divest is off by some wei
            // Divest and repay
            _divestAndRepay(toDivest);

            buffer = base.balanceOf(address(this)) - withdrawal; // The amount of base obtained can be affected by rounding, better to sync thna to use limits.mid
        }
        else {
            buffer -= withdrawal;
        }

        _burn(address(this), toBurn);
        base.transfer(to, withdrawal);
    }

    /// @dev Invest available funds from the strategy into YieldSpace LP - Borrow and mint
    function _borrowAndInvest(uint256 tokenInvested)
        internal
        returns (uint256 minted)
    {
        PoolCache memory remotePoolCache = _getCache(pool);
        PoolCache memory localPoolCache = poolCache; 
        require(_poolDeviated(localPoolCache, remotePoolCache) == false, "Pool reserves changed too fast");
        poolCache = _twarUpdatedCache(localPoolCache, remotePoolCache);

        // Find pool proportion p = tokenReserves/(tokenReserves + fyTokenReserves)
        // Deposit (investment * p) base to borrow (investment * p) fyToken
        //   (investment * p) fyToken + (investment * (1 - p)) base = investment
        //   (investment * p) / ((investment * p) + (investment * (1 - p))) = p
        //   (investment * (1 - p)) / ((investment * p) + (investment * (1 - p))) = 1 - p

        uint256 baseInPool = base.balanceOf(address(pool));
        uint256 fyTokenInPool = fyToken.balanceOf(address(pool));
        
        uint256 tokenToPool = (tokenInvested * baseInPool) / (baseInPool + fyTokenInPool);  // Rounds down
        uint256 fyTokenToPool = tokenInvested - tokenToPool;        // fyTokenToPool is rounded up

        base.transfer(baseJoin, fyTokenToPool);
        int128 fyTokenToPool_ = fyTokenToPool.u128().i128();
        ladle.pour(vaultId, address(pool), fyTokenToPool_, fyTokenToPool_);

        // Mint LP tokens with (investment * p) fyToken and (investment * (1 - p)) base
        base.transfer(address(pool), tokenToPool);
        (,, minted) = pool.mint(address(this), true, 0); // We already checked for slippage

        emit Invest(minted);
    }

    /// @dev Divest from YieldSpace LP into available funds for the strategy - Burn and repay
    function _divestAndRepay(uint256 lpBurnt)
        internal
        returns (uint256 tokenDivested, uint256 fyTokenDivested)
    {
        PoolCache memory remotePoolCache = _getCache(pool);
        PoolCache memory localPoolCache = poolCache; 
        require(_poolDeviated(localPoolCache, remotePoolCache) == false, "Pool reserves changed too fast");
        poolCache = _twarUpdatedCache(localPoolCache, remotePoolCache);

        // Burn lpTokens
        pool.transfer(address(pool), lpBurnt);
        (, tokenDivested, fyTokenDivested) = pool.burn(address(this), 0, 0); // We already checked for slippage
        
        // Repay with fyToken as much as possible
        uint256 debt = cauldron.balances(vaultId).art;
        uint256 fyTokenAvailable = fyToken.balanceOf(address(this));    // If there is a surplus from a previous divestment event, use it.
        if (debt > 0 && fyTokenAvailable > 0) {
            uint256 toRepay = (debt >= fyTokenAvailable) ? fyTokenAvailable : debt;
            
            fyToken.transfer(address(fyToken), toRepay);
            int128 toRepay_ = toRepay.u128().i128();
            ladle.pour(vaultId, address(this), -toRepay_, -toRepay_);   // Negative ink = withdraw, negative art = repay
        }

        // Any surplus fyToken remains in the contract, locked until there is debt and a divestment event.

        emit Divest(lpBurnt);
    }

    /// @dev Get a cached pool reserves in the PoolCache format
    function _getCache(IPool pool_) internal view returns (PoolCache memory poolCache_) {
        (uint112 poolBase, uint112 poolFYToken, uint32 lastUpdated) = pool_.getCache();
        return PoolCache(poolBase, poolFYToken, lastUpdated);
    }

    /// @dev Return a TWAR-updated pool cache
    function _twarUpdatedCache(PoolCache memory remotePoolCache, PoolCache memory localPoolCache)
        internal view
        returns (PoolCache memory updatedPoolCache)
    {

        if (localPoolCache.timestamp == uint32(block.timestamp)) return localPoolCache; // Update only once per block

        uint32 elapsed = uint32(block.timestamp) - localPoolCache.timestamp;
        if (elapsed > TWAR_INTERVAL) elapsed = TWAR_INTERVAL;
        updatedPoolCache = PoolCache({
            base: (remotePoolCache.base * elapsed + localPoolCache.base * (TWAR_INTERVAL - elapsed)) / TWAR_INTERVAL,
            fyToken: (remotePoolCache.fyToken * elapsed + localPoolCache.fyToken * (TWAR_INTERVAL - elapsed)) / TWAR_INTERVAL,
            timestamp: uint32(block.timestamp)
        });
    }

    /// @dev Check if the pool reserves have deviated more than the acceptable amount between two pool caches.
    function _poolDeviated(PoolCache memory localPoolCache, PoolCache memory remotePoolCache)
        internal view
        returns (bool deviated)
    {
        // Floor the elapsed time at 1 to make the math work if there is a second event in the same block
        uint256 elapsed = block.timestamp != localPoolCache.timestamp ? block.timestamp - localPoolCache.timestamp : 1;

        // Calculate deviation as a linear function
        deviated = 
            elapsed * 1e18 * remotePoolCache.base / remotePoolCache.fyToken >
            elapsed * (1e18 + poolDeviationRate) * localPoolCache.base / localPoolCache.fyToken ||
            elapsed * 1e18 * remotePoolCache.fyToken / remotePoolCache.base >
            elapsed * (1e18 + poolDeviationRate) * localPoolCache.fyToken / localPoolCache.base;
    }
}
