// SPDX-License-Identifier: BUSL-1.1
// Audit of commit 6bb7c7f at https://hackmd.io/@devtooligan/YieldStrategyV2Review2022-12-07
// Fixes not applied, do not use in production.

pragma solidity >=0.8.13;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {StrategyMigrator} from "./StrategyMigrator.sol";
import {AccessControl} from "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import {SafeERC20Namer} from "@yield-protocol/utils-v2/contracts/token/SafeERC20Namer.sol";
import {MinimalTransferHelper} from "@yield-protocol/utils-v2/contracts/token/MinimalTransferHelper.sol";
import {IERC20} from "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import {ERC20Rewards} from "@yield-protocol/utils-v2/contracts/token/ERC20Rewards.sol";
import {IFYToken} from "@yield-protocol/vault-v2/contracts/interfaces/IFYToken.sol";
import {IPool} from "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";

/// @dev The Strategy contract allows liquidity providers to provide liquidity in yieldspace
/// pool tokens and receive strategy tokens that represent a stake in a YieldSpace pool contract.
/// Upon maturity, the strategy can `divest` from the mature pool, becoming a proportional
/// ownership underlying vault. When not invested, the strategy can `invest` into a Pool using
/// all its underlying.
/// The strategy can also `eject` from a Pool before maturity. Any fyToken obtained will be available
/// to be bought by anyone at face value. If the pool tokens can't be burned, they will be ejected
/// and the strategy can be recapitalized.
contract Strategy is AccessControl, ERC20Rewards, StrategyMigrator { // TODO: I'd like to import IStrategy
    enum State {DEPLOYED, DIVESTED, INVESTED, EJECTED, DRAINED}
    using MinimalTransferHelper for IERC20;
    using MinimalTransferHelper for IFYToken;
    using MinimalTransferHelper for IPool;

    event Invested(address indexed pool, uint256 baseInvested, uint256 lpTokensObtained);
    event Divested(address indexed pool, uint256 lpTokenDivested, uint256 baseObtained);
    event Ejected(address indexed pool, uint256 lpTokenDivested, uint256 baseObtained, uint256 fyTokenObtained);
    event Drained(address indexed pool, uint256 lpTokenDivested);
    event SoldFYToken(uint256 soldFYToken, uint256 returnedBase);

    State public state;                          // The state determines which functions are available

    // IERC20 public immutable base;             // Base token for this strategy (inherited from StrategyMigrator)
    // IFYToken public override fyToken;         // Current fyToken for this strategy (inherited from StrategyMigrator)
    IPool public pool;                           // Current pool that this strategy invests in

    uint256 public baseCached;                   // Base tokens held by the strategy
    uint256 public poolCached;                   // Pool tokens held by the strategy
    uint256 public fyTokenCached;                // In emergencies, the strategy can keep fyToken

    constructor(string memory name_, string memory symbol_, IFYToken fyToken_)
        ERC20Rewards(name_, symbol_, SafeERC20Namer.tokenDecimals(address(fyToken_)))
        StrategyMigrator(
            IERC20(fyToken_.underlying()),
            fyToken_)
    {
        // Deploy with a seriesId_ matching the migrating strategy if using the migration feature
        // Deploy with any series matching the desired base in any other case
        fyToken = fyToken_;

        base = IERC20(fyToken_.underlying());

        _grantRole(Strategy.init.selector, address(this)); // Enable the `mint` -> `init` hook.
    }

    modifier isState(State target) {
        require (
            target == state,
            "Not allowed in this state"
        );
        _;
    }

    /// @dev State and state variable management
    /// @param target State to transition to
    /// @param pool_ If transitioning to invested, update pool state variable with this parameter
    function _transition(State target, IPool pool_) internal {
        if (target == State.INVESTED) {
            pool = pool_;
            fyToken = IFYToken(address(pool_.fyToken()));
            maturity = pool_.maturity();
        } else if (target == State.DIVESTED) {
            delete fyToken;
            delete maturity;
            delete pool;
        } else if (target == State.EJECTED) {
            delete maturity;
            delete pool;
        } else if (target == State.DRAINED) {
            delete maturity;
            delete pool;
        }
        state = target;
    }

    // ----------------------- INVEST & DIVEST --------------------------- //

    /// @notice Mock pool mint called by a strategy when trying to migrate.
    /// @dev Will initialize the strategy and return strategy tokens.
    /// It is expected that base has been transferred in, but no fyTokens
    /// @return baseIn Amount of base tokens found in contract
    /// @return fyTokenIn This is always returned as 0 since they aren't used
    /// @return minted Amount of strategy tokens minted from base tokens which is the same as baseIn
    function mint(address, address, uint256, uint256)
        external
        override
        auth
        returns (uint256 baseIn, uint256 fyTokenIn, uint256 minted)
    {
        baseIn = minted = _init(msg.sender);
        fyTokenIn = 0; // Silence compiler warning
    }

    /// @dev Mint the first strategy tokens, without investing
    /// @param to Recipient for the strategy tokens
    /// @return minted Amount of strategy tokens minted from base tokens
    function init(address to)
        external
        auth
        isState(State.DEPLOYED)
        returns (uint256 minted)
    {
        minted = _init(to);
    }

    /// @dev Mint the first strategy tokens, without investing
    /// @param to Recipient for the strategy tokens
    /// @return minted Amount of strategy tokens minted from base tokens
    function _init(address to)
        internal
        isState(State.DEPLOYED)
        returns (uint256 minted)
    {
        // Clear fyToken in case we initialized through `mint`
        delete fyToken;

        baseCached = minted = base.balanceOf(address(this));
        require (minted > 0, "Not enough base in");
        // Make sure that at the end of the transaction the strategy has enough tokens as to not expose itself to a rounding-down liquidity attack.
        _mint(to, minted);

        _transition(State.DIVESTED, IPool(address(0)));
    }

    /// @dev Start the strategy investments in the next pool
    /// @param pool_ Pool to invest into
    /// @return poolTokensObtained Amount of pool tokens minted from base tokens
    /// @notice When calling this function for the first pool, some underlying needs to be transferred to the strategy first, using a batchable router.
    function invest(IPool pool_)
        external
        auth
        isState(State.DIVESTED)
        returns (uint256 poolTokensObtained)
    {
        // Caching
        IFYToken fyToken_ = IFYToken(address(pool_.fyToken()));
        uint256 baseCached_ = baseCached; // We could read the real balance, but this is a bit safer

        require(base == pool_.base(), "Mismatched base");

        // Mint LP tokens and initialize the pool
        delete baseCached;
        base.safeTransfer(address(pool_), baseCached_);
        (,, poolTokensObtained) = pool_.init(address(this));
        poolCached = poolTokensObtained;

        // Update state variables
        fyToken = fyToken_;
        maturity = pool_.maturity();
        pool = pool_;

        _transition(State.INVESTED, pool_);
        emit Invested(address(pool_), baseCached_, poolTokensObtained);
    }

    /// @dev Divest out of a pool once it has matured
    /// @return baseObtained Amount of base tokens obtained from burning pool tokens   
    function divest()
        external
        isState(State.INVESTED)
        returns (uint256 baseObtained)
    {
        // Caching
        IPool pool_ = pool;
        IFYToken fyToken_ = fyToken;
        require (uint32(block.timestamp) >= maturity, "Only after maturity");

        uint256 toDivest = pool_.balanceOf(address(this));

        // Burn lpTokens
        delete poolCached;
        pool_.safeTransfer(address(pool_), toDivest);
        (, uint256 baseFromBurn, uint256 fyTokenFromBurn) = pool_.burn(address(this), address(this), 0, type(uint256).max); // We don't care about slippage, because the strategy holds to maturity

        // Redeem any fyToken
        uint256 baseFromRedeem = fyToken_.redeem(address(this), fyTokenFromBurn);

        // Reset the base cache
        baseCached = base.balanceOf(address(this));

        // Transition to Divested
        _transition(State.DIVESTED, pool_);
        emit Divested(address(pool_), toDivest, baseObtained = baseFromBurn + baseFromRedeem);
    }

    // ----------------------- EJECT --------------------------- //

    /// @dev Divest out of a pool at any time. If possible the pool tokens will be burnt for base and fyToken, the latter of which
    /// must be sold to return the strategy to a functional state. If the pool token burn reverts, the pool tokens will be transferred
    /// to the caller as a last resort.
    /// @return baseReceived Amount of base tokens received from pool tokens
    /// @return fyTokenReceived Amount of fyToken received from pool tokens
    /// @notice The caller must take care of slippage when selling fyToken, if relevant.
    function eject()
        external
        auth
        isState(State.INVESTED)
        returns (uint256 baseReceived, uint256 fyTokenReceived)
    {
        // Caching
        IPool pool_ = pool;
        uint256 toDivest = pool_.balanceOf(address(this));

        // Burn lpTokens, if not possible, eject the pool tokens out. Slippage should be managed by the caller.
        delete poolCached;
        try this._burnPoolTokens(pool_, toDivest) returns (uint256 baseReceived_, uint256 fyTokenReceived_) {
            baseCached = baseReceived = baseReceived_;
            fyTokenCached = fyTokenReceived = fyTokenReceived_;
            if (fyTokenReceived > 0) {
                _transition(State.EJECTED, pool_);
                emit Ejected(address(pool_), toDivest, baseReceived, fyTokenReceived);
            } else {
                _transition(State.DIVESTED, pool_);
                emit Divested(address(pool_), toDivest, baseReceived);
            }

        } catch {
            pool_.safeTransfer(msg.sender, toDivest);
            _transition(State.DRAINED, pool_);
            emit Drained(address(pool_), toDivest);
        }
    }

    /// @dev Burn an amount of pool tokens.
    /// @notice Only the Strategy itself can call this function. It is external and exists so that the transfer is reverted if the burn also reverts.
    /// @param pool_ Pool for the pool tokens.
    /// @param poolTokens Amount of tokens to burn.
    /// @return baseReceived Amount of base tokens received from pool tokens
    /// @return fyTokenReceived Amount of fyToken received from pool tokens
    function _burnPoolTokens(IPool pool_, uint256 poolTokens)
        external
        returns (uint256 baseReceived, uint256 fyTokenReceived)
    {
        require (msg.sender ==  address(this), "Unauthorized");

        // Burn lpTokens
        pool_.safeTransfer(address(pool_), poolTokens);
        (, baseReceived, fyTokenReceived) = pool_.burn(address(this), address(this), 0, type(uint256).max);
    }

    /// @dev Buy ejected fyToken in the strategy at face value
    /// @param fyTokenTo Address to send the purchased fyToken to.
    /// @param baseTo Address to send any remaining base to.
    /// @return soldFYToken Amount of fyToken sold.
    /// @return returnedBase Amount of base unused and returned.
    function buyFYToken(address fyTokenTo, address baseTo)
        external
        isState(State.EJECTED)
        returns (uint256 soldFYToken, uint256 returnedBase)
    {
        // Caching
        IFYToken fyToken_ = fyToken;
        uint256 baseCached_ = baseCached;
        uint256 fyTokenCached_ = fyTokenCached;

        uint256 baseIn = base.balanceOf(address(this)) - baseCached_;
        (soldFYToken, returnedBase) = baseIn > fyTokenCached_ ? (fyTokenCached_, baseIn - fyTokenCached_) : (baseIn, 0);

        // Update base and fyToken cache
        baseCached = baseCached_ + soldFYToken; // soldFYToken is base not returned
        fyTokenCached = fyTokenCached_ -= soldFYToken;

        // Transition to divested if done
        if (fyTokenCached_ == 0) {
            // Transition to Divested
            _transition(State.DIVESTED, IPool(address(0)));
            emit Divested(address(0), 0, 0);
        }

        // Transfer fyToken and base (if surplus)
        fyToken_.safeTransfer(fyTokenTo, soldFYToken);
        if (soldFYToken < baseIn) {
            base.safeTransfer(baseTo, baseIn - soldFYToken);
        }

        emit SoldFYToken(soldFYToken, returnedBase);
    }

    /// @dev If we drained the strategy, we can recapitalize it with base to avoid a forced migration
    /// @return baseIn Amount of base tokens used to restart
    function restart()
        external
        auth
        isState(State.DRAINED)
        returns (uint256 baseIn)
    {
        require((baseCached = baseIn = base.balanceOf(address(this))) > 0, "No base to restart");
        _transition(State.DIVESTED, IPool(address(0)));
        emit Divested(address(0), 0, 0);
    }

    // ----------------------- MINT & BURN --------------------------- //

    /// @dev Mint strategy tokens with pool tokens. It can be called only when invested.
    /// @param to Recipient for the strategy tokens
    /// @return minted Amount of strategy tokens minted
    /// @notice The pool tokens that the user contributes need to have been transferred previously, using a batchable router.
    function mint(address to)
        external
        isState(State.INVESTED)
        returns (uint256 minted)
    {
        // Caching
        IPool pool_ = pool;
        uint256 poolCached_ = poolCached;

        // minted = supply * value(deposit) / value(strategy)

        // Find how much was deposited
        uint256 deposit = pool_.balanceOf(address(this)) - poolCached_;

        // Update the pool cache
        poolCached = poolCached_ + deposit;

        // Mint strategy tokens
        minted = _totalSupply * deposit / poolCached_;
        _mint(to, minted);
    }

    /// @dev Burn strategy tokens to withdraw pool tokens. It can be called only when invested.
    /// @param to Recipient for the pool tokens
    /// @return poolTokensObtained Amount of pool tokens obtained
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function burn(address to)
        external
        isState(State.INVESTED)
        returns (uint256 poolTokensObtained)
    {
        // Caching
        IPool pool_ = pool;
        uint256 poolCached_ = poolCached;
        uint256 totalSupply_ = _totalSupply;

        // Burn strategy tokens
        uint256 burnt = _balanceOf[address(this)];
        _burn(address(this), burnt);

        poolTokensObtained = pool.balanceOf(address(this)) * burnt / totalSupply_;
        pool_.safeTransfer(address(to), poolTokensObtained);

        // Update pool cache
        poolCached = poolCached_ - poolTokensObtained;
    }

    /// @dev Mint strategy tokens with base tokens. It can be called only when not invested and not ejected.
    /// @param to Recipient for the strategy tokens
    /// @return minted Amount of strategy tokens minted
    /// @notice The base tokens that the user invests need to have been transferred previously, using a batchable router.
    function mintDivested(address to)
        external
        isState(State.DIVESTED)
        returns (uint256 minted)
    {
        // minted = supply * value(deposit) / value(strategy)
        uint256 baseCached_ = baseCached;
        uint256 deposit = base.balanceOf(address(this)) - baseCached_;
        baseCached = baseCached_ + deposit;

        minted = _totalSupply * deposit / baseCached_;

        _mint(to, minted);
    }

    /// @dev Burn strategy tokens to withdraw base tokens. It can be called when not invested and not ejected.
    /// @param to Recipient for the base tokens
    /// @return baseObtained Amount of base tokens obtained
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function burnDivested(address to)
        external
        isState(State.DIVESTED)
        returns (uint256 baseObtained)
    {
        // strategy * burnt/supply = withdrawal
        uint256 baseCached_ = baseCached;
        uint256 burnt = _balanceOf[address(this)];
        baseObtained = baseCached_ * burnt / _totalSupply;
        baseCached -= baseObtained;

        _burn(address(this), burnt);
        base.safeTransfer(to, baseObtained);
    }
}