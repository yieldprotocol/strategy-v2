// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {StrategyMigrator} from "./StrategyMigrator.sol";
import {AccessControl} from "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import {SafeERC20Namer} from "@yield-protocol/utils-v2/contracts/token/SafeERC20Namer.sol";
import {MinimalTransferHelper} from "@yield-protocol/utils-v2/contracts/token/MinimalTransferHelper.sol";
import {IERC20} from "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import {ERC20Rewards} from "@yield-protocol/utils-v2/contracts/token/ERC20Rewards.sol";
import {IFYToken} from "@yield-protocol/vault-v2/contracts/interfaces/IFYToken.sol";
import {ICauldron} from "@yield-protocol/vault-v2/contracts/interfaces/ICauldron.sol";
import {ILadle} from "@yield-protocol/vault-v2/contracts/interfaces/ILadle.sol";
import {IPool} from "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";

import "forge-std/console2.sol";

/// @dev The Strategy contract allows liquidity providers to provide liquidity in underlying
/// and receive strategy tokens that represent a stake in a YieldSpace pool contract.
/// Upon maturity, the strategy can `divest` from the mature pool, becoming a proportional
/// ownership underlying vault. When not invested, the strategy can `invest` into a Pool using
/// all its underlying.
/// The strategy can also `eject` from a Pool before maturity, immediately converting its assets
/// to underlying as much as possible. If any fyToken can't be exchanged for underlying, the
/// strategy will hold them until maturity when `redeemEjected` can be used.

/// TODO: Put these docs in the right spot.
/// mint and burn are user functions. Users provide base and get strategy tokens on mint, and the reverse on burn. The strategy might be in different states while this happens.
/// invest, divest and eject are governance functions (even if divest is open to all). They instruct the strategy what to do with the pooled user funds:
/// invest: Only while divested. Put all the user funds in a pool. Become invested.
/// divest: Only while invested on a mature pool. Pull all funds from the pool. Become divested.
/// eject: Only while invested on a non-mature pool. Pull all funds from the pool. Become divested.
contract Strategy is AccessControl, ERC20Rewards, StrategyMigrator { // TODO: I'd like to import IStrategy
    using MinimalTransferHelper for IERC20;
    using MinimalTransferHelper for IFYToken;
    using MinimalTransferHelper for IPool;

    event LadleSet(ILadle ladle);

    event Invested(address indexed pool, uint256 baseInvested, uint256 lpTokensObtained);
    event Divested(address indexed pool, uint256 lpTokenDivested, uint256 baseObtained);
    event Ejected(address indexed pool, uint256 lpTokenDivested, uint256 baseObtained, uint256 fyTokenObtained);
    event EjectedToPool(address indexed pool, uint256 lpTokenDivested);
    event SoldFYToken(uint256 soldFYToken, uint256 returnedBase);

    ILadle public ladle;                         // Gateway to the Yield v2 Collateralized Debt Engine
    // IERC20 public immutable base;             // Base token for this strategy (inherited from StrategyMigrator)

    // IFYToken public override fyToken;         // Current fyToken for this strategy (inherited from StrategyMigrator)
    IPool public pool;                           // Current pool that this strategy invests in

    uint256 public cached;                       // While divested, base tokens held by the strategy; while invested, pool tokens held by the strategy
    uint256 public fyTokenCached;                // In emergencies, the strategy can keep fyToken

    constructor(string memory name, string memory symbol, uint8 decimals, ILadle ladle_, IFYToken fyToken_)
        ERC20Rewards(name, symbol, decimals)
        StrategyMigrator(
            IERC20(fyToken_.underlying()),
            fyToken_)
    {
        ladle = ladle_;

        // Deploy with a seriesId_ matching the migrating strategy if using the migration feature
        // Deploy with any series matching the desired base in any other case
        fyToken = fyToken_;

        base = IERC20(fyToken_.underlying());

        _grantRole(Strategy.init.selector, address(this)); // Enable the `mint` -> `init` hook.
    }

    modifier invested() {
        require (
            address(pool) != address(0),
            "Not invested"
        );
        _;
    }

    modifier divested() {
        require (
            address(pool) == address(0),
            "Not divested"
        );
        _;
    }

    modifier isEjected() {
        require (
            fyTokenCached > 0,
            "Not ejected"
        );
        _;
    }

    modifier notEjected() {
        require (
            fyTokenCached == 0,
            "Is ejected"
        );
        _;
    }

    /// @dev Set a new Ladle
    /// @notice Use with extreme caution, only for Ladle replacements
    function setLadle(ILadle ladle_)
        external
        divested
        auth
    {
        ladle = ladle_;
        emit LadleSet(ladle_);
    }

    // ----------------------- INVEST & DIVEST --------------------------- //

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
        // Clear state variables from a potential migration
        delete fyToken;
        delete maturity;
        delete pool;

        require (_totalSupply == 0, "Already initialized");
        cached = minted = base.balanceOf(address(this));
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
        notEjected
        returns (uint256 poolTokensObtained)
    {
        require (_totalSupply > 0, "Init Strategy first");

        // Caching
        IPool pool_ =  IPool(ladle.pools(seriesId_));
        IFYToken fyToken_ = IFYToken(address(pool_.fyToken()));
        uint256 cached_ = cached; // We could read the real balance, but this is a bit safer

        require(base == pool_.base(), "Mismatched base");
        require(pool_.getFYTokenBalance() - pool_.totalSupply() == 0, "Pool has fyToken");

        // Mint LP tokens
        base.safeTransfer(address(pool_), cached_);
        (,, poolTokensObtained) = pool_.mint(address(this), address(this), minRatio, maxRatio);
        cached = poolTokensObtained;

        // Update state variables
        fyToken = fyToken_;
        maturity = pool_.maturity();
        pool = pool_;

        emit Invested(address(pool_), cached_, poolTokensObtained);
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
        pool_.safeTransfer(address(pool_), toDivest);
        (, uint256 baseFromBurn, uint256 fyTokenFromBurn) = pool_.burn(address(this), address(this), 0, type(uint256).max); // We don't care about slippage, because the strategy holds to maturity

        // Redeem any fyToken
        uint256 baseFromRedeem = fyToken_.redeem(address(this), fyTokenFromBurn);

        // Reset the base cache
        cached = base.balanceOf(address(this));

        // Transition to Divested
        delete fyToken;
        delete maturity;
        delete pool;

        emit Divested(address(pool_), toDivest, baseFromBurn + baseFromRedeem);
    }

    // ----------------------- EJECT --------------------------- //

    /// @dev Divest out of a pool at any time. If possible the pool tokens will be burnt for base and fyToken, the latter of which
    /// must be sold to return the strategy to a functional state. If the pool token burn reverts, the pool tokens will be transferred
    /// to the caller as a last resort.
    function eject()
        external
        auth
        invested
    {
        // Caching
        IPool pool_ = pool;
        uint256 toDivest = pool_.balanceOf(address(this));

        // Burn lpTokens, if not possible, eject the pool tokens out. Slippage should be managed by the caller.
        try this._burnPoolTokens(pool_, toDivest, 0, type(uint256).max) returns (uint256 baseReceived, uint256 fyTokenReceived) {
            cached = baseReceived;
            fyTokenCached = fyTokenReceived;
        } catch {
            delete cached;
            pool_.safeTransfer(msg.sender, toDivest);
        }

        delete pool;

        if (fyTokenCached > 0) { // If there are any fyToken left, transition to ejected state
            emit Ejected(address(pool_), toDivest, cached, fyTokenCached);
        } else { // If there are no fyToken left, transition to divested state
            delete fyToken;
            delete maturity;
            emit Divested(address(pool_), toDivest, cached);
        }
    }

    /// @dev Burn an amount of pool tokens. This is its own function so that if it reverts the transfer of pool tokens is not executed
    function _burnPoolTokens(IPool pool_, uint256 poolTokens, uint256 minRatio, uint256 maxRatio)
        external
        returns (uint256 baseReceived, uint256 fyTokenReceived)
    {
        require (msg.sender ==  address(this), "Unauthorized");

        // Burn lpTokens
        pool_.safeTransfer(address(pool_), poolTokens);
        (, baseReceived, fyTokenReceived) = pool_.burn(address(this), address(this), minRatio, maxRatio);
    }

    /// @dev Buy ejected fyToken in the strategy at face value
    /// @param fyTokenTo Address to send the purchased fyToken to.
    /// @param baseTo Address to send any remaining base to.
    /// @return soldFYToken Amount of fyToken sold.
    /// @return returnedBase Amount of base unused and returned.
    function buyFYToken(address fyTokenTo, address baseTo)
        external
        divested
        isEjected
        returns (uint256 soldFYToken, uint256 returnedBase)
    {
        // Caching
        IFYToken fyToken_ = fyToken;
        uint256 fyTokenCached_ = fyTokenCached;

        uint256 baseIn = base.balanceOf(address(this)) - cached;
        (soldFYToken, returnedBase) = baseIn > fyTokenCached_ ? (fyTokenCached_, baseIn - fyTokenCached_) : (baseIn, 0);

        // Update ejected and reset if done
        if ((fyTokenCached_ -= soldFYToken) == 0) {
            // Transition to Divested
            delete fyToken;
            delete maturity;
            emit Divested(address(0), 0, 0);
        }

        // Update base cache
        cached += soldFYToken;

        // Transfer fyToken and base (if surplus)
        fyToken_.safeTransfer(fyTokenTo, soldFYToken);
        if (soldFYToken < baseIn) {
            base.safeTransfer(baseTo, baseIn - soldFYToken);
        }

        emit SoldFYToken(soldFYToken, returnedBase);
    }

    // ----------------------- MINT & BURN --------------------------- //

    /// @dev Mint strategy tokens with pool tokens. It can be called only when invested.
    /// @notice The pool tokens that the user contributes need to have been transferred previously, using a batchable router.
    function mintInvested(address to)
        external
        invested
        returns (uint256 minted)
    {
        // Caching
        IPool pool_ = pool;
        uint256 cached_ = cached;

        // minted = supply * value(deposit) / value(strategy)

        // Find how much was deposited
        uint256 deposit = pool_.balanceOf(address(this)) - cached_;

        // Update the base cache
        cached = cached_ + deposit;

        // Mint strategy tokens
        minted = _totalSupply * deposit / cached_;
        _mint(to, minted);
    }

    /// @dev Burn strategy tokens to withdraw pool tokens. It can be called only when invested.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function burnInvested(address to)
        external
        invested
        returns (uint256 poolTokensObtained)
    {
        // Caching
        IPool pool_ = pool;
        uint256 cached_ = cached;
        uint256 totalSupply_ = _totalSupply;

        // Burn strategy tokens
        uint256 burnt = _balanceOf[address(this)];
        _burn(address(this), burnt);

        poolTokensObtained = pool.balanceOf(address(this)) * burnt / totalSupply_;
        pool_.safeTransfer(address(to), poolTokensObtained);

        // Update cached base
        cached = cached_ - poolTokensObtained;
    }

    /// @dev Mint strategy tokens with base tokens. It can be called only when not invested and not ejected.
    /// @notice The base tokens that the user invests need to have been transferred previously, using a batchable router.
    function mintDivested(address to)
        external
        divested
        notEjected
        returns (uint256 minted)
    {
        // minted = supply * value(deposit) / value(strategy)
        uint256 cached_ = cached;
        uint256 deposit = base.balanceOf(address(this)) - cached_;
        cached = cached_ + deposit;

        minted = _totalSupply * deposit / cached_;

        _mint(to, minted);
    }

    /// @dev Burn strategy tokens to withdraw base tokens. It can be called when not invested and not ejected.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function _burnDivested(address baseTo)
        internal
        divested
        notEjected
        returns (uint256 baseObtained)
    {
        // strategy * burnt/supply = withdrawal
        uint256 cached_ = cached;
        uint256 burnt = _balanceOf[address(this)];
        baseObtained = cached_ * burnt / _totalSupply;
        cached -= baseObtained;

        _burn(address(this), burnt);
        base.safeTransfer(baseTo, baseObtained);
    }
}