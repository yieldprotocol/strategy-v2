// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;

import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/MinimalTransferHelper.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/utils-v2/contracts/token/ERC20Rewards.sol";
import "@yield-protocol/utils-v2/contracts/cast/CastU256I128.sol";
import "@yield-protocol/utils-v2/contracts/cast/CastU128I128.sol";
import "@yield-protocol/vault-interfaces/DataTypes.sol";
import "@yield-protocol/vault-interfaces/ICauldron.sol";
import "@yield-protocol/vault-interfaces/ILadle.sol";
import "@yield-protocol/yieldspace-interfaces/IPool.sol";


/// @dev The Pool contract exchanges base for fyToken at a price defined by a specific formula.
contract Strategy is AccessControl, ERC20Rewards {
    using MinimalTransferHelper for IERC20;
    using CastU256U128 for uint256; // Inherited from ERC20Rewards
    using CastU256I128 for uint256;
    using CastU128I128 for uint128;

    event YieldSet(ILadle ladle, ICauldron cauldron);
    event TokenJoinReset(address join);
    event TokenIdSet(bytes6 id);
    event NextPoolSet(IPool indexed pool, bytes6 indexed seriesId);
    event PoolEnded(address pool);
    event PoolStarted(address pool);
    event Invest(uint256 minted);
    event Divest(uint256 burnt);

    IERC20 public immutable base;                // Base token for this strategy
    bytes6 public baseId;                        // Identifier for the base token in Yieldv2
    address public baseJoin;                     // Yield v2 Join to deposit token when borrowing
    ILadle public ladle;                         // Gateway to the Yield v2 Collateralized Debt Engine
    ICauldron public cauldron;                   // Accounts in the Yield v2 Collateralized Debt Engine
    bytes12 public vaultId;                      // Vault used to borrow fyToken

    IPool public pool;                           // Current pool that this strategy invests in
    bytes6 public seriesId;                      // SeriesId for the current pool in Yield v2
    IFYToken public fyToken;                     // Current fyToken for this strategy

    IPool public nextPool;                       // Next pool that this strategy will invest in
    bytes6 public nextSeriesId;                  // SeriesId for the next pool in Yield v2

    uint256 public cached;                       // LP tokens owned by the strategy after the last operation

    constructor(string memory name, string memory symbol, uint8 decimals, ILadle ladle_, IERC20 base_, bytes6 baseId_)
        ERC20Rewards(name, symbol, decimals)
    { 
        require(
            ladle_.cauldron().assets(baseId_) == address(base_),
            "Mismatched baseId"
        );
        base = base_;
        baseId = baseId_;
        baseJoin = address(ladle_.joins(baseId_));

        ladle = ladle_;
        cauldron = ladle_.cauldron();
    }

    modifier poolSelected() {
        require (
            pool != IPool(address(0)),
            "Pool not selected"
        );
        _;
    }

    modifier poolNotSelected() {
        require (
            pool == IPool(address(0)),
            "Pool selected"
        );
        _;
    }

    modifier afterMaturity() {
        require (
            uint32(block.timestamp) > fyToken.maturity(),
            "Only after maturity"
        );
        _;
    }

    /// @dev Set a new Ladle and Cauldron
    /// @notice Use with extreme caution, only for Ladle replacements
    function setYield(ILadle ladle_)
        external
        poolNotSelected
        auth
    {
        ladle = ladle_;
        ICauldron cauldron_ = ladle_.cauldron();
        cauldron = cauldron_;
        emit YieldSet(ladle_, cauldron_);
    }

    /// @dev Set a new base token id
    /// @notice Use with extreme caution, only for token reconfigurations in Cauldron
    function setTokenId(bytes6 baseId_)
        external
        poolNotSelected
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
        external
        poolNotSelected
        auth
    {
        baseJoin = address(ladle.joins(baseId));
        emit TokenJoinReset(baseJoin);
    }

    /// @dev Set the next pool to invest in
    function setNextPool(IPool pool_, bytes6 seriesId_) 
        external
        auth
    {
        require(
            base == pool_.base(),
            "Mismatched base"
        );
        DataTypes.Series memory series = cauldron.series(seriesId_);
        require(
            series.fyToken == pool_.fyToken(),
            "Mismatched seriesId"
        );

        nextPool = pool_;
        nextSeriesId = seriesId_;

        emit NextPoolSet(pool_, seriesId_);
    }

    /// @dev Start the strategy investments in the next pool
    /// @notice When calling this function for the first pool, some underlying needs to be transferred to the strategy first, using a batchable router.
    function startPool()
        external
        poolNotSelected
    {
        require(nextPool != IPool(address(0)), "Next pool not set");

        pool = nextPool;
        fyToken = pool.fyToken();
        seriesId = nextSeriesId;

        delete nextPool;
        delete nextSeriesId;

        (vaultId, ) = ladle.build(seriesId, baseId, 0);

        // Find pool proportion p = tokenReserves/(tokenReserves + fyTokenReserves)
        // Deposit (investment * p) base to borrow (investment * p) fyToken
        //   (investment * p) fyToken + (investment * (1 - p)) base = investment
        //   (investment * p) / ((investment * p) + (investment * (1 - p))) = p
        //   (investment * (1 - p)) / ((investment * p) + (investment * (1 - p))) = 1 - p

        uint256 baseBalance = base.balanceOf(address(this));
        require(baseBalance > 0, "No funds to start with");

        uint256 baseInPool = base.balanceOf(address(pool));
        uint256 fyTokenInPool = fyToken.balanceOf(address(pool));
        
        uint256 baseToPool = (baseBalance * baseInPool) / (baseInPool + fyTokenInPool);  // Rounds down
        uint256 fyTokenToPool = baseBalance - baseToPool;        // fyTokenToPool is rounded up

        // Borrow fyToken with base as collateral
        base.safeTransfer(baseJoin, fyTokenToPool);
        int128 fyTokenToPool_ = fyTokenToPool.i128();
        ladle.pour(vaultId, address(pool), fyTokenToPool_, fyTokenToPool_);

        // Mint LP tokens with (investment * p) fyToken and (investment * (1 - p)) base
        base.safeTransfer(address(pool), baseToPool);
        (,, cached) = pool.mint(address(this), true, 0); // We don't care about slippage

        if (_totalSupply == 0) _mint(msg.sender, cached); // Initialize the strategy if needed

        emit PoolStarted(address(pool));
    }

    /// @dev Divest out of a pool once it has matured
    function endPool()
        external
        afterMaturity
    {
        uint256 toDivest = pool.balanceOf(address(this));
        
        // Burn lpTokens
        IERC20(address(pool)).safeTransfer(address(pool), toDivest);
        (,, uint256 fyTokenDivested) = pool.burn(address(this), 0, 0); // We don't care about slippage
        
        // Repay with fyToken as much as possible
        DataTypes.Balances memory balances_ = cauldron.balances(vaultId);
        uint256 debt = balances_.art;
        uint256 toRepay = (debt >= fyTokenDivested) ? fyTokenDivested : debt;
        if (toRepay > 0) {
            IERC20(address(fyToken)).safeTransfer(address(fyToken), toRepay);
            int128 toRepay_ = toRepay.i128();
            ladle.pour(vaultId, address(this), 0, -toRepay_);
            debt -= toRepay;
        }

        // Redeem any fyToken surplus
        uint256 toRedeem = fyTokenDivested - toRepay;
        if (toRedeem > 0) {
            IERC20(address(fyToken)).safeTransfer(address(fyToken), toRedeem);
            fyToken.redeem(address(this), toRedeem);
        }

        // Repay with underlying if there is still any debt
        if (debt > 0) {
            base.safeTransfer(baseJoin, cauldron.debtToBase(seriesId, debt.u128())); // The strategy can't lose money due to the pool invariant, there will always be enough if we get here.
            int128 debt_ = debt.i128();
            ladle.close(vaultId, address(this), 0, -debt_);   // Takes a fyToken amount as art parameter
        }

        // Withdraw all collateral
        ladle.pour(vaultId, address(this), -(balances_.ink.i128()), 0);

        emit PoolEnded(address(pool));

        // Clear up
        delete pool;
        delete fyToken;
        delete seriesId;
        delete cached;
        
        ladle.destroy(vaultId);
        delete vaultId;
    }

    /// @dev Mint strategy tokens.
    /// @notice The lp tokens that the user contributes need to have been transferred previously, using a batchable router.
    function mint(address to)
        external
        poolSelected
        returns (uint256 minted)
    {
        // minted = supply * value(deposit) / value(strategy)
        uint256 deposit = pool.balanceOf(address(this)) - cached;
        minted = _totalSupply * deposit / cached;
        cached += deposit;

        _mint(to, minted);
    }

    /// @dev Burn strategy tokens to withdraw lp tokens. The lp tokens obtained won't be of the same pool that the investor deposited,
    /// if the strategy has swapped to another pool.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function burn(address to)
        external
        poolSelected
        returns (uint256 withdrawal)
    {
        // strategy * burnt/supply = withdrawal
        uint256 burnt = _balanceOf[address(this)];
        withdrawal = cached * burnt / _totalSupply;
        cached -= withdrawal;

        _burn(address(this), burnt);
        IERC20(address(pool)).safeTransfer(to, withdrawal);
    }

    /// @dev Burn strategy tokens to withdraw base tokens. It can be called only when a pool is not selected.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function burnForBase(address to)
        external
        poolNotSelected
        returns (uint256 withdrawal)
    {
        // strategy * burnt/supply = withdrawal
        uint256 burnt = _balanceOf[address(this)];
        withdrawal = base.balanceOf(address(this)) * burnt / _totalSupply;

        _burn(address(this), burnt);
        base.safeTransfer(to, withdrawal);
    }
}
