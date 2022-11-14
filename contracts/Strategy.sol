// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import "./interfaces/IStrategy.sol";
import "./StrategyMigrator.sol";
import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/SafeERC20Namer.sol";
import "@yield-protocol/utils-v2/contracts/token/MinimalTransferHelper.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/utils-v2/contracts/token/ERC20Rewards.sol";
import "@yield-protocol/utils-v2/contracts/cast/CastU256I128.sol";
import "@yield-protocol/utils-v2/contracts/cast/CastU128I128.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/ICauldron.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/ILadle.sol";
import "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";

// TODO: Can we make this a fancy free function?
library DivUp {
    /// @dev Divide a between b, rounding up
    function divUp(uint256 a, uint256 b) internal pure returns(uint256 c) {
        // % 0 panics even inside the unchecked, and so prevents / 0 afterwards
        // https://docs.soliditylang.org/en/v0.8.9/types.html 
        unchecked { a % b == 0 ? c = a / b : c = a / b + 1; } 
    }
}

/// @dev The Strategy contract allows liquidity providers to provide liquidity in underlying
/// and receive strategy tokens that represent a stake in a YieldSpace pool contract.
/// Upon maturity, the strategy can `divest` from the mature pool, becoming a proportional
/// ownership underlying vault. When not invested, the strategy can `invest` into a Pool using
/// all its underlying.
/// The strategy can also `eject` from a Pool before maturity, immediately converting its assets
/// to underlying as much as possible. If any fyToken can't be exchanged for underlying, the
/// strategy will hold them until maturity when `redeemEjected` can be used.
contract Strategy is AccessControl, ERC20Rewards, StrategyMigrator { // TODO: I'd like to import IStrategy
    using DivUp for uint256;
    using MinimalTransferHelper for IERC20;
    using CastU256U128 for uint256; // Inherited from ERC20Rewards
    using CastU256I128 for uint256;
    using CastU128I128 for uint128;

    struct EjectedSeries {
        bytes6 seriesId;
        uint128 cached;
    }

    event YieldSet(ILadle ladle, ICauldron cauldron);
    event TokenJoinReset(address join);
    event TokenIdSet(bytes6 id);

    event Invested(address indexed pool, uint256 baseInvested, uint256 lpTokensObtained);
    event Divested(address indexed pool, uint256 lpTokenDivested, uint256 baseObtained);
    event Ejected(address indexed pool, uint256 lpTokenDivested, uint256 baseObtained, uint256 fyTokenObtained);
    event Redeemed(bytes6 indexed seriesId, uint256 redeemedFYToken, uint256 receivedBase);

    // TODO: Global variables can be packed

    ILadle public ladle;                         // Gateway to the Yield v2 Collateralized Debt Engine
    ICauldron public cauldron;                   // Accounts in the Yield v2 Collateralized Debt Engine
    bytes6 public baseId;                        // Identifier for the base token in Yieldv2
    // IERC20 public immutable base;             // Base token for this strategy (inherited from StrategyMigrator)
    address public baseJoin;                     // Yield v2 Join to deposit token when borrowing

    bytes12 public vaultId;                      // VaultId for the Strategy debt
    bytes6 public seriesId;                      // Identifier for the current seriesId
    // IFYToken public override fyToken;         // Current fyToken for this strategy (inherited from StrategyMigrator)
    IPool public pool;                           // Current pool that this strategy invests in
    uint256 public cachedBase;                   // Base tokens owned by the strategy after the last operation

    EjectedSeries public ejected;                // In emergencies, the strategy can keep fyToken of one series

    constructor(string memory name, string memory symbol, uint8 decimals, ILadle ladle_, IFYToken fyToken_)
        ERC20Rewards(name, symbol, decimals)
        StrategyMigrator(
            IERC20(fyToken_.underlying()),
            fyToken_)
    {
        ladle = ladle_;
        cauldron = ladle_.cauldron();

        // Deploy with a seriesId_ matching the migrating strategy if using the migration feature
        // Deploy with any series matching the desired base in any other case
        fyToken = fyToken_;

        base = IERC20(fyToken_.underlying());
        baseId = fyToken_.underlyingId();
        baseJoin = address(ladle_.joins(baseId));

        _grantRole(Strategy.init.selector, address(this)); // Enable the `mint` -> `init` hook.
    }

    modifier invested() {
        require (
            maturity != 0,
            "Not invested"
        );
        _;
    }

    modifier divested() {
        require (
            maturity == 0,
            "Not divested"
        );
        _;
    }

    /// @dev Set a new Ladle and Cauldron
    /// @notice Use with extreme caution, only for Ladle replacements
    function setYield(ILadle ladle_)
        external
        divested
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
        divested
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
        divested
        auth
    {
        baseJoin = address(ladle.joins(baseId));
        emit TokenJoinReset(baseJoin);
    }

    // ----------------------- STATE CHANGES --------------------------- //

    /// @dev Mock pool mint hooked up to initialize the strategy and return strategy tokens.
    function mint(address, address, uint256, uint256)
        external
        override
        auth
        returns (uint256 baseIn, uint256 fyTokenIn, uint256 minted)
    {
        baseIn = minted = this.init(msg.sender);
        fyTokenIn = 0;
    }

    /// @dev Mint the first strategy tokens, without investing
    function init(address to)
        external
        auth
        returns (uint256 minted)
    {
        // Delete seriesId and fyToken, disabling any further migrations
        delete seriesId;
        delete fyToken;

        require (_totalSupply == 0, "Already initialized");
        cachedBase = minted = base.balanceOf(address(this));
        require (minted > 0, "Not enough base in");
        // Make sure that at the end of the transaction the strategy has enough tokens as to not expose itself to a rounding-down liquidity attack.
        _mint(to, minted);
    }

    /// @dev Start the strategy investments in the next pool
    /// @param minRatio Minimum allowed ratio between the reserves of the next pool, as a fixed point number with 18 decimals (base/fyToken)
    /// @param maxRatio Maximum allowed ratio between the reserves of the next pool, as a fixed point number with 18 decimals (base/fyToken)
    /// @notice When calling this function for the first pool, some underlying needs to be transferred to the strategy first, using a batchable router.
    function invest(bytes6 seriesId_, uint256 minRatio, uint256 maxRatio)
        external
        auth
        divested
    {
        require (_totalSupply > 0, "Init Strategy first");

        // Caching
        IPool pool_ =  IPool(ladle.pools(seriesId_));
        IFYToken fyToken_ = IFYToken(address(pool_.fyToken()));
        uint256 cached_ = cachedBase; // We could read the real balance, but this is a bit safer

        require(base == pool_.base(), "Mismatched base");
        // TODO: If there are ejected fyToken, consider restricting investing only to series of the same fyToken. Ask Allan.
        // There are some risks of getting stuck until maturity, but also simplifies the state machine

        // Find pool proportion p = tokenReserves/(tokenReserves + fyTokenReserves)
        // Deposit (investment * p) base to borrow (investment * p) fyToken
        //   (investment * p) fyToken + (investment * (1 - p)) base = investment
        //   (investment * p) / ((investment * p) + (investment * (1 - p))) = p
        //   (investment * (1 - p)) / ((investment * p) + (investment * (1 - p))) = 1 - p

        // The Pool mints based on cached values, not actual ones.
        uint256 baseInPool = pool_.getBaseBalance();
        uint256 fyTokenInPool = pool_.getFYTokenBalance() - pool_.totalSupply();

        uint256 baseToPool = (cached_ * baseInPool).divUp(baseInPool + fyTokenInPool);  // Rounds up
        uint256 fyTokenToPool = cached_ - baseToPool;        // fyTokenToPool is rounded down

        // Borrow fyToken with underlying as collateral
        (vaultId,) = ladle.build(seriesId_, baseId, 0);
        base.safeTransfer(baseJoin, fyTokenToPool);
        ladle.pour(vaultId, address(pool_), fyTokenToPool.i128(), fyTokenToPool.i128());

        // In the edge case that we have ejected from a pool, and then invested on another pool for 
        // the same series, we could reuse the fyToken. However, that is complex and `eject` should
        // have minimized the amount of available fyToken.

        // Mint LP tokens with (investment * p) fyToken and (investment * (1 - p)) base
        base.safeTransfer(address(pool_), baseToPool);
        (,, uint256 lpTokenMinted) = pool_.mint(address(this), address(this), minRatio, maxRatio);

        // Update state variables
        seriesId = seriesId_;
        fyToken = fyToken_;
        maturity = pool_.maturity();
        pool = pool_;

        emit Invested(address(pool_), cached_, lpTokenMinted);
    }

    /// @dev Divest out of a pool once it has matured
    function divest()
        external
        invested
    {
        // Caching
        IPool pool_ = pool;
        IFYToken fyToken_ = fyToken;
        require (uint32(block.timestamp) >= maturity, "Only after maturity");

        uint256 toDivest = pool_.balanceOf(address(this));
        
        // Burn lpTokens
        IERC20(address(pool_)).safeTransfer(address(pool_), toDivest);
        (, uint256 baseFromBurn, uint256 fyTokenFromBurn) = pool_.burn(address(this), address(this), 0, type(uint256).max); // We don't care about slippage, because the strategy holds to maturity
        
        // Redeem any fyToken
        IERC20(address(fyToken_)).safeTransfer(address(fyToken_), fyTokenFromBurn); // TODO: Necessary?
        uint256 baseFromRedeem = fyToken_.redeem(address(this), fyTokenFromBurn);
        // There is an edge case in which surplus fyToken from a previous ejection could have been used. Not worth the complexity.

        // Reset the base cache
        cachedBase = base.balanceOf(address(this));

        emit Divested(address(pool_), toDivest, baseFromBurn + baseFromRedeem);

        // Update state variables
        delete seriesId;
        delete fyToken;
        delete maturity;
        delete pool;
        delete vaultId;
    }

    /// @dev Divest out of a pool at any time. The obtained fyToken will be used to repay debt.
    /// Any surplus will be kept in the contract until maturity, at which point `redeemEjected`
    /// should be called.
    function eject(uint256 minRatio, uint256 maxRatio)
        external
        auth
    {
        // It would be complex to deal with concurrent ejections for different fyToken
        require (ejected.seriesId == bytes6(0) || ejected.seriesId == seriesId, "Already ejected");

        // Caching
        IPool pool_ = pool;
        IFYToken fyToken_ = fyToken;

        uint256 toDivest = pool_.balanceOf(address(this));
        
        // Burn lpTokens
        IERC20(address(pool_)).safeTransfer(address(pool_), toDivest);
        (, uint256 baseReceived, uint256 fyTokenReceived) = pool_.burn(address(this), address(this), minRatio, maxRatio);

        // Repay as much debt as possible
        uint256 debt = cauldron.balances(vaultId).art;
        uint256 toRepay = debt < fyTokenReceived ? fyTokenReceived : debt;
        IERC20(address(fyToken_)).safeTransfer(address(fyToken_), toRepay);
        ladle.pour(vaultId, address(this), -(toRepay).i128(), -(toRepay).i128());
        // There is an edge case in which surplus fyToken from a previous ejection could have been used. Not worth the complexity.

        // Reset the base cache
        cachedBase = base.balanceOf(address(this));

        // If there are any left, reset or update the ejected fyToken cache
        if (fyTokenReceived - toRepay > 0) {                      // if all fyToken were used we don't reset or update
            ejected.seriesId = seriesId;                          // if (ejected.seriesId == seriesId), this has no effect
            ejected.cached += (fyTokenReceived - toRepay).u128(); // if (ejected.seriesId != seriesId), ejected.cached should be 0
        }
        
        emit Ejected(address(pool_), toDivest, baseReceived + toRepay, fyTokenReceived - toRepay);

        // Update state variables
        delete seriesId;
        delete fyToken;
        delete pool;
        delete vaultId; // We either burned all the fyToken, or there is no debt left.
    }

    // ----------------------- EJECTED FYTOKEN --------------------------- //

    /// @dev Redeem ejected fyToken in the strategy for base
    function redeemEjected(uint256 redeemedFYToken)
        external
        divested
    {
        // Caching
        IFYToken fyToken_ = cauldron.series(ejected.seriesId).fyToken;
        require (address(fyToken_) != address(0), "Series not found");

        // Redeem fyToken
       uint256 receivedBase = fyToken_.redeem(address(this), redeemedFYToken);

        // Update the base cache
        cachedBase += receivedBase;

        // Update ejected and reset if done
        if ((ejected.cached -= redeemedFYToken.u128()) == 0) delete ejected;

        emit Redeemed(ejected.seriesId, redeemedFYToken, receivedBase);
    }

    // ----------------------- MINT & BURN --------------------------- //

    /// @dev Mint strategy tokens.
    /// @notice The base tokens that the user contributes need to have been transferred previously, using a batchable router.
    function mint(address to, uint256 minRatio, uint256 maxRatio)
        external
        returns (uint256 minted)
    {
        uint256 maturity_ = maturity;

        if (block.timestamp >= maturity_) {
            this.divest();
        }

        if (maturity_ == 0) {
            minted = _mintDivested(to);
        } else {
            minted = _mintInvested(to, minRatio, maxRatio);
        }
    }


    /// @dev Burn strategy tokens to withdraw base tokens.
    /// @notice If the strategy ejected from a previous investment, some fyToken might be received.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function burn(address baseTo, address ejectedFYTokenTo, uint256 minBaseReceived)
        external
        returns (uint256 withdrawal)
    {
        uint256 maturity_ = maturity;

        if (block.timestamp >= maturity_) {
            this.divest();
        }

        if (maturity_ == 0) {
            withdrawal = _burnDivested(baseTo, ejectedFYTokenTo);
        } else {
            withdrawal = _burnInvested(baseTo, ejectedFYTokenTo, minBaseReceived);
        }
    }

    /// @dev Mint strategy tokens while invested in a pool.
    /// @notice The base tokens that the user contributes need to have been transferred previously, using a batchable router.
    function _mintInvested(address to, uint256 minRatio, uint256 maxRatio)
        internal
        invested
        returns (uint256 minted)
    {
        // Caching
        IPool pool_ = pool;
        uint256 cached_ = cachedBase;

        // minted = supply * value(deposit) / value(strategy)

        // Find how much was deposited
        uint256 deposit = base.balanceOf(address(this)) - cached_;

        // Update the base cache
        cached_ += deposit;
        cachedBase = cached_ + deposit;

        // Add any ejected fyToken into the strategy value, at 1:1
        cached_ += ejected.cached;

        // Mint strategy tokens
        minted = _totalSupply * deposit / cached_;
        _mint(to, minted);

        // Now, put the funds into the Pool
        uint256 baseInPool = pool_.getBaseBalance();
        uint256 fyTokenInPool = pool_.getFYTokenBalance() - pool_.totalSupply();

        uint256 baseToPool = (cachedBase * baseInPool).divUp(baseInPool + fyTokenInPool);  // Rounds up
        uint256 fyTokenToPool = cachedBase - baseToPool;        // fyTokenToPool is rounded down

        // Borrow fyToken with underlying as collateral
        base.safeTransfer(baseJoin, fyTokenToPool);
        ladle.pour(vaultId, address(pool_), fyTokenToPool.i128(), fyTokenToPool.i128());

        // Mint LP tokens with (investment * p) fyToken and (investment * (1 - p)) base
        base.safeTransfer(address(pool_), baseToPool);
        pool_.mint(address(this), address(this), minRatio, maxRatio); // TODO: Can we do better slippage than this? Ask Allan.
    }

    /// @dev Burn strategy tokens to withdraw base tokens.
    /// @notice If the strategy ejected from a previous investment, some fyToken might be received.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function _burnInvested(address baseTo, address ejectedFYTokenTo, uint256 minBaseReceived)
        internal
        invested
        returns (uint256 withdrawal)
    {
        // Caching
        IPool pool_ = pool;
        IFYToken fyToken_ = fyToken;
        uint256 cached_ = cachedBase;

        // strategy * burnt/supply = withdrawal

        // Burn strategy tokens
        uint256 burnt = _balanceOf[address(this)];
        withdrawal = cached_ * burnt / _totalSupply;
        _burn(address(this), burnt);

        // Update cached base
        cachedBase = cached_ - withdrawal;

        // Burn lpTokens
        IERC20(address(pool_)).safeTransfer(address(pool_), withdrawal);
        (, uint256 baseFromBurn, uint256 fyTokenReceived) = pool_.burn(baseTo, address(this), 0, type(uint256).max);

        // Repay as much debt as possible
        uint256 debt = cauldron.balances(vaultId).art;
        uint256 toRepay = debt < fyTokenReceived ? fyTokenReceived : debt;
        IERC20(address(fyToken_)).safeTransfer(address(fyToken_), toRepay);
        ladle.pour(vaultId, address(this), -(toRepay.i128()), -(toRepay.i128()));

        // Sell any fyToken that are left
        uint256 toSell = fyTokenReceived - toRepay;
        uint256 baseFromSale;
        if (toSell > 0) {
            IERC20(address(fyToken_)).safeTransfer(address(pool_), toSell);
            baseFromSale = pool_.sellFYToken(address(this), 0);
        }

        // Slippage
        require (baseFromBurn + baseFromSale >= minBaseReceived, "Not enough base obtained");

        // If we have ejected fyToken, we give them out in the same proportion
        if (ejected.seriesId != bytes6(0)) _transferEjected(ejectedFYTokenTo, ejected.cached * burnt / _totalSupply);
    }

    /// @dev Mint strategy tokens with base tokens. It can be called only when not invested.
    /// @notice The base tokens that the user invests need to have been transferred previously, using a batchable router.
    function _mintDivested(address to)
        internal
        divested
        returns (uint256 minted)
    {
        // minted = supply * value(deposit) / value(strategy)
        uint256 cached_ = cachedBase + ejected.cached; // We value ejected fyToken at 1:1
        uint256 deposit = pool.balanceOf(address(this)) - cached_;
        cachedBase = cached_ + deposit;

        minted = _totalSupply * deposit / cached_;
        
        _mint(to, minted);
    }

    /// @dev Burn strategy tokens to withdraw base tokens. It can be called when not invested.
    /// @notice If the strategy ejected from a previous investment, some fyToken might be received.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function _burnDivested(address baseTo, address ejectedFYTokenTo)
        internal
        divested
        returns (uint256 withdrawal)
    {
        // strategy * burnt/supply = withdrawal
        uint256 burnt = _balanceOf[address(this)];
        withdrawal = base.balanceOf(address(this)) * burnt / _totalSupply;

        _burn(address(this), burnt);
        base.safeTransfer(baseTo, withdrawal);

        // If we have ejected fyToken, we we give them out in the same proportion
        if (ejected.seriesId != bytes6(0)) _transferEjected(ejectedFYTokenTo, ejected.cached * burnt / _totalSupply);
    }

    /// @dev Transfer out fyToken from the ejected cache
    function _transferEjected(address to, uint256 amount)
        internal
        returns (bool)
    {
            IFYToken fyToken_ = cauldron.series(ejected.seriesId).fyToken;
            require (address(fyToken_) != address(0), "Series not found"); // TODO: remove this require and put a try/catch in the transfer, to make sure we don't brick.
            IERC20(address(fyToken_)).safeTransfer(to, amount);
            ejected.cached -= amount.u128();
    }
}