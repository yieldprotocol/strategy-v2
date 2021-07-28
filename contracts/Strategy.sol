// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;

import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/TransferHelper.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/yieldspace-interfaces/IPool.sol";
import "@yield-protocol/vault-interfaces/DataTypes.sol";
import "./ERC20Rewards.sol";

interface ILadle {
    function joins(bytes6) external view returns (address);
    function cauldron() external view returns (ICauldron);
    function build(bytes6 seriesId, bytes6 ilkId, uint8 salt) external returns (bytes12 vaultId, DataTypes.Vault memory vault);
    function tweak(bytes12 vaultId, bytes6 seriesId, bytes6 ilkId) external returns (DataTypes.Vault memory vault);
    function destroy(bytes12 vaultId) external;
    function pour(bytes12 vaultId, address to, int128 ink, int128 art) external;
}

interface ICauldron {
    function assets(bytes6) external view returns (address);
    function series(bytes6) external view returns (DataTypes.Series memory);
    function balances(bytes12) external view returns (DataTypes.Balances memory);
}

/* library CastU256U128 {
    /// @dev Safely cast an uint256 to an uint128
    function u128(uint256 x) internal pure returns (uint128 y) {
        require (x <= type(uint128).max, "Cast overflow");
        y = uint128(x);
    }
} */

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
    event PoolSwapped(address pool);
    event Invest(uint256 minted);
    event Divest(uint256 burnt);

    struct Limits {                              // Buffer limits, in 1e18 units
        uint80 low;                              // If the buffer would drop below this level, it fills to mid 
        uint80 mid;                              // Target buffer level
        uint80 high;                             // If the buffer would drop below this level, it drains to mid
    }

    IERC20 public immutable base;                // Base token for this strategy
    bytes6 public baseId;                        // Identifier for the base token in Yieldv2
    address public baseJoin;                     // Yield v2 Join to deposit token when borrowing
    ILadle public ladle;                         // Gateway to the Yield v2 Collateralized Debt Engine
    ICauldron public cauldron;                   // Accounts in the Yield v2 Collateralized Debt Engine
    bytes12 public vaultId;                      // Vault used to borrow fyToken

    Limits public limits;                        // Limits for unallocated funds
    uint256 public buffer;                       // Unallocated base token in this strategy

    IPool public pool;                           // Current pool that this strategy invests in
    IFYToken public fyToken;                     // Current fyToken for this strategy
    IPool[] public pools;                        // Pools that this strategy invests in, past, present and future
    bytes6[] public seriesIds;                   // SeriesId for each pool in the pools array
    uint256 public poolCounter;                  // Index of the current pool in the pools array

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
    }

    modifier beforeMaturity() {
        require (
            fyToken.maturity() < uint32(block.timestamp),
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

    /// @dev Set a queue of pools to invest in, sequentially
    /// @notice Until the last pool reaches maturity, this can't be changed
    function setPools(IPool[] memory pools_, bytes6[] memory seriesIds_) 
        public
        afterMaturity
        auth
    {
        require (pools.length == 0 || poolCounter == pools.length - 1, "Pools queued");
        for (uint256 p = 0; p < pools_.length; p++) {
            DataTypes.Series memory series = cauldron.series(seriesIds_[p]);
            require(
                series.fyToken == pools_[p].fyToken(),
                "Mismatched seriesId"
            );
        }
        pools = pools_;
        seriesIds = seriesIds_;
        poolCounter = type(uint256).max;
    }

    /// @dev Initialize this contract, minting a number of strategy tokens equal to the base balance of the strategy
    /// @notice The funds for initialization must have been sent previously, using a batchable router.
    function init(address to)
        public
        auth
    {
        require (_totalSupply == 0, "Already initialized");
        _mint(to, base.balanceOf(address(this)));
    }

    /// @dev Swap funds to the next pool
    /// @notice If there is no next pool, all funds are divested, and investing disabled
    function swap()
        public
        afterMaturity
    {
        // Divest from the current pool
        if (poolCounter == type(uint256).max) { // First pool in the set
            poolCounter = 0;
        } else {
            // Divest fully, all debt in the vault should be repaid and collateral withdrawn into the buffer
            // With a bit of extra code, the collateral could be left in the vault
            _divestAndRepay(pool.balanceOf(address(this)), 0, 0);

            // Redeem any fyToken surplus
            uint256 toRedeem = fyToken.balanceOf(address(this));
            fyToken.transfer(address(fyToken), toRedeem);
            fyToken.redeem(address(this), toRedeem);
            poolCounter++;
        }

        // Swap to the next pool
        if (poolCounter < pools.length) {   // We swap pool and vault, borrow and invest
            pool = pools[poolCounter];
            fyToken = pool.fyToken();
            bytes6 seriesId = seriesIds[poolCounter];

            if (vaultId == bytes12(0)) (vaultId, ) = ladle.build(seriesId, baseId, 0);
            else ladle.tweak(vaultId, seriesId, baseId); // This will revert if the vault still has debt

            _borrowAndInvest(buffer - limits.mid, 0);
        } else { // There is no next pool, we leave the funds in the buffer and disable investing
            pool = IPool(address(0));
            fyToken = IFYToken(address(0));
            vaultId = bytes12(0);

            ladle.destroy(vaultId);

            limits = Limits({
                low: 0,
                mid: 0,
                high: type(uint80).max
            });
        }
        buffer = base.balanceOf(address(this));
        emit PoolSwapped(address(pool));
    }

    /// @dev Value of the strategy in base token terms
    function strategyValue()
        external view
        returns (uint256 value)
    {
        value = _strategyValue();
    }

    /// @dev Value of the strategy in base token terms
    function _strategyValue()
        internal view
        returns (uint256 value)
    {
        //  - Can we use 1 fyToken = 1 base for this purpose? It overvalues the value of the strategy.
        //  - If so lpTokens/lpSupply * (lpReserves + lpFYReserves) + unallocated = value_in_token(strategy)
        if (pool == IPool(address(0))) value =
            (base.balanceOf(address(pool)) + fyToken.balanceOf(address(pool))
             * pool.balanceOf(address(this))) / pool.totalSupply()
             + buffer
             + fyToken.balanceOf(address(this));
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
        uint256 deposit = base.balanceOf(address(this)) - buffer;
        minted = _totalSupply - deposit / _strategyValue();
        
        // Invest if the deposit would lead to `buffer` over `limits.high`
        if (buffer + deposit > limits.high) _drainBuffer(deposit, 0); // TODO: Set slippage as a twap

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
        if (withdrawal > buffer || buffer - withdrawal < limits.low) _fillBuffer(withdrawal, 0, 0); // TODO: Set slippage as a twap

        _burn(address(this), toBurn);
        base.transfer(to, withdrawal);
    }

    /// @dev Drain the available funds buffer, after an hypothetical deposit
    function _drainBuffer(uint256 deposit, uint256 min)
        internal
        returns (uint256 tokenInvested)
    {
        require(
            buffer + deposit > limits.high,
            "Buffer not high enough"
        );

        // Find out how much of the buffer we need to invest so that buffer + deposit = buffer.mid
        uint256 toInvest = deposit + buffer - limits.mid;
        // Borrow and invest
        tokenInvested = _borrowAndInvest(toInvest, min);

        buffer = base.balanceOf(address(this));
    }

    /// @dev Fill the available funds buffer to the mid point, after an hypothetical withdrawal
    function _fillBuffer(uint256 withdrawal, uint256 minTokenReceived, uint256 minFYTokenReceived)
        internal
        returns (uint256 tokenDivested, uint256 fyTokenDivested)
    {
        require(
            buffer - withdrawal < limits.low,
            "Buffer not low enough"
        );

        // Find out how many lp tokens we need to burn so that buffer - withdrawal = buffer.mid
        uint256 toObtain = limits.mid + withdrawal - buffer;
        // Find value of lp tokens in base terms, scaled up for precision
        uint256 lpValueUp = (1e18 * (base.balanceOf(address(pool)) + fyToken.balanceOf(address(pool)))) / pool.totalSupply();
        uint256 toDivest = (1e18 * toObtain) / lpValueUp;   // It doesn't matter if the amount to divest is off by some wei
        // Divest and repay
        (tokenDivested, fyTokenDivested) = _divestAndRepay(toDivest, minTokenReceived, minFYTokenReceived);

        buffer = base.balanceOf(address(this));
    }

    /// @dev Invest available funds from the strategy into YieldSpace LP - Borrow and mint
    function _borrowAndInvest(uint256 tokenInvested, uint256 min)
        internal
        returns (uint256 minted)
    {
        // Find pool proportion p = fyTokenReserves/tokenReserves
        // Deposit (investment * p) base to borrow (investment * p) fyToken
        //   (investment * p) fyToken + (investment * (1 - p)) base = investment
        //   (investment * p) / ((investment * p) + (investment * (1 - p))) = p
        //   (investment * (1 - p)) / ((investment * p) + (investment * (1 - p))) = 1 - p
        // The minimum invested amount will be buffer.high - buffer.mid
        uint256 tokenToPool = tokenInvested * base.balanceOf(address(pool)) / fyToken.balanceOf(address(pool));  // Rounds down
        uint256 fyTokenToPool = tokenInvested - tokenToPool;        // fyTokenToPool is rounded up

        base.transfer(baseJoin, fyTokenToPool);
        int128 fyTokenToPool_ = fyTokenToPool.u128().i128();
        ladle.pour(vaultId, address(pool), fyTokenToPool_, fyTokenToPool_);

        // Mint LP tokens with (investment * p) fyToken and (investment * (1 - p)) base
        base.transfer(address(pool), tokenToPool);
        (,, minted) = pool.mint(address(this), true, min);          // Calculate from unaccounted base amount in pool, which was rounded down. Surplus is in base token, which was rounded up

        emit Invest(minted);
    }

    /// @dev Divest from YieldSpace LP into available funds for the strategy - Burn and repay
    function _divestAndRepay(uint256 lpBurnt, uint256 minTokenReceived, uint256 minFYTokenReceived)
        internal
        returns (uint256 tokenDivested, uint256 fyTokenDivested)
    {
        // Burn lpTokens
        pool.transfer(address(pool), lpBurnt);
        (, tokenDivested, fyTokenDivested) = pool.burn(address(this), minTokenReceived, minFYTokenReceived);
        
        // Repay with fyToken as much as possible
        uint256 debt = cauldron.balances(vaultId).art;
        uint256 toRepay = (debt >= fyTokenDivested) ? fyTokenDivested : debt;
        toRepay += fyToken.balanceOf(address(this));    // If there is a surplus from a previous divestment event, use it.
        
        fyToken.transfer(address(fyToken), toRepay);
        int128 toRepay_ = toRepay.u128().i128();
        ladle.pour(vaultId, address(this), toRepay_, toRepay_);

        // Any surplus fyToken remains in the contract, locked until there is debt and a divestment event.

        emit Divest(lpBurnt);
    }
}
