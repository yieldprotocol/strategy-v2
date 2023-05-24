// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import {IStrategy} from "./../interfaces/IStrategy.sol";
import {StrategyMigrator} from "./../StrategyMigrator.sol";
import {AccessControl} from "@yield-protocol/utils-v2/src/access/AccessControl.sol";
import {SafeERC20Namer} from "@yield-protocol/utils-v2/src/token/SafeERC20Namer.sol";
import {MinimalTransferHelper} from "@yield-protocol/utils-v2/src/token/MinimalTransferHelper.sol";
import {IERC20} from "@yield-protocol/utils-v2/src/token/IERC20.sol";
import {ERC20Rewards} from "@yield-protocol/utils-v2/src/token/ERC20Rewards.sol";
import {Cast} from "@yield-protocol/utils-v2/src/utils/Cast.sol";
import {IFYToken} from "@yield-protocol/vault-v2/src/interfaces/IFYToken.sol";
import {ICauldron} from "@yield-protocol/vault-v2/src/interfaces/ICauldron.sol";
import {ILadle} from "@yield-protocol/vault-v2/src/interfaces/ILadle.sol";
import {IPool} from "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";

import "forge-std/console2.sol";

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

/// TODO: Put these docs in the right spot.
/// mint and burn are user functions. Users provide base and get strategy tokens on mint, and the reverse on burn. The strategy might be in different states while this happens.
/// invest, divest and eject are governance functions (even if divest is open to all). They instruct the strategy what to do with the pooled user funds:
/// invest: Only while divested. Put all the user funds in a pool. Become invested.
/// divest: Only while invested on a mature pool. Pull all funds from the pool. Become divested.
/// eject: Only while invested on a non-mature pool. Pull all funds from the pool. Become divested.
contract StrategyV3 is AccessControl, ERC20Rewards, StrategyMigrator { // TODO: I'd like to import IStrategy
    enum State {DEPLOYED, DIVESTED, INVESTED, EJECTED, DRAINED}

    using DivUp for uint256;
    using MinimalTransferHelper for IERC20;
    using MinimalTransferHelper for IFYToken;
    using MinimalTransferHelper for IPool;
    using Cast for uint256;

    event LadleSet(ILadle ladle);
    event TokenJoinReset(address join);

    event Invested(address indexed pool, uint256 baseInvested, uint256 poolTokensObtained);
    event Divested(address indexed pool, uint256 poolTokenDivested, uint256 baseObtained);
    event Ejected(address indexed pool, uint256 poolTokenDivested, uint256 baseObtained, uint256 fyTokenObtained);
    event Drained(address indexed pool, uint256 poolTokenDrained);
    event SoldEjected(bytes6 indexed seriesId, uint256 soldFYToken, uint256 returnedBase);

    // TODO: Global variables can be packed

    State public state;                          // The state determines which functions are available

    ILadle public ladle;                         // Gateway to the Yield v2 Collateralized Debt Engine
    ICauldron public immutable cauldron;         // Accounts in the Yield v2 Collateralized Debt Engine
    bytes6 public immutable baseId;              // Identifier for the base token in Yieldv2
    // IERC20 public immutable base;             // Base token for this strategy (inherited from StrategyMigrator)
    address public baseJoin;                     // Yield v2 Join to deposit token when borrowing

    bytes12 public vaultId;                      // VaultId for the Strategy debt
    bytes6 public seriesId;                      // Identifier for the current seriesId
    // IFYToken public override fyToken;         // Current fyToken for this strategy (inherited from StrategyMigrator)
    IPool public pool;                           // Current pool that this strategy invests in

    uint256 public value;                        // While divested, base tokens owned by the strategy. While invested, pool tokens owned by the strategy.
    uint256 public ejected;                      // In emergencies, the strategy can keep fyToken

    constructor(string memory name, string memory symbol, ILadle ladle_, IFYToken fyToken_)
        ERC20Rewards(name, symbol, SafeERC20Namer.tokenDecimals(address(fyToken_)))
        StrategyMigrator(
            IERC20(fyToken_.underlying()),
            fyToken_)
    {
        ladle = ladle_;
        cauldron = ladle_.cauldron();

        bytes6 baseId_;
        baseId = baseId_ = fyToken_.underlyingId();
        baseJoin = address(ladle_.joins(baseId_));

        _grantRole(StrategyV3.init.selector, address(this)); // Enable the `mint` -> `init` hook.
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
    /// @param vaultId_ If transitioning to invested, update vaultId state variable with this parameter
    function _transition(State target, bytes12 vaultId_) internal {
        if (target == State.INVESTED) {
            vaultId = vaultId_;
            bytes6 seriesId_;
            seriesId = seriesId_ = cauldron.vaults(vaultId).seriesId;
            IPool pool_;
            pool = pool_ = IPool(ladle.pools(seriesId_));
            fyToken = IFYToken(address(pool_.fyToken()));
            maturity = pool_.maturity();
        } else if (target == State.DIVESTED) {
            delete vaultId;
            delete seriesId;
            delete fyToken;
            delete maturity;
            delete pool;
        } else if (target == State.EJECTED) {
            delete vaultId;
            delete pool;
        } else if (target == State.DRAINED) {
            delete vaultId;
            delete seriesId;
            delete fyToken;
            delete maturity;
            delete pool;
        }
        state = target;
    }

    /// @dev Set a new Ladle
    /// @notice Use with extreme caution, only for Ladle replacements
    function setLadle(ILadle ladle_)
        external
        isState(State.DIVESTED)
        auth
    {
        ladle = ladle_;
        emit LadleSet(ladle_);
    }

    /// @dev Reset the base token join
    /// @notice Use with extreme caution, only for Join replacements
    function resetTokenJoin()
        external
        isState(State.DIVESTED)
        auth
    {
        baseJoin = address(ladle.joins(baseId));
        emit TokenJoinReset(baseJoin);
    }

    // ----------------------- STATE CHANGES --------------------------- //

    /// @dev Mint the first strategy tokens, without investing.
    /// @param to Receiver of the strategy tokens.
    function init(address to)
        external
        override
        isState(State.DEPLOYED)
        auth
        returns (uint256 baseIn, uint256 fyTokenIn, uint256 minted)
    {
        // Clear state variables from a potential migration
        delete seriesId;
        delete fyToken;
        delete maturity;
        delete pool;
        delete vaultId;

        require (_totalSupply == 0, "Already initialized");
        fyTokenIn = 0;
        value = baseIn = minted = base.balanceOf(address(this));
        require (minted > 0, "Not enough base in");
        // Make sure that at the end of the transaction the strategy has enough tokens as to not expose itself to a rounding-down liquidity attack.
        _mint(to, minted);

        _transition(State.DIVESTED, bytes12(0));
    }

    /// @dev Invest the strategy funds in a pool. Only when divested. Only for pools with no fyToken.
    /// @param seriesId_ SeriesId for the pool the strategy should invest into.
    /// @param minRatio Minimum allowed ratio between the reserves of the next pool, as a fixed point number with 18 decimals (base/fyToken)
    /// @param maxRatio Maximum allowed ratio between the reserves of the next pool, as a fixed point number with 18 decimals (base/fyToken)
    /// @param poolValue Amount of pool tokens obtained, which is now the value in pool terms of the strategy.
    /// @notice When calling this function for the first pool, some underlying needs to be transferred to the strategy first, using a batchable router.
    function invest(bytes6 seriesId_, uint256 minRatio, uint256 maxRatio)
        external
        auth
        isState(State.DIVESTED)
        returns (uint256 poolValue)
    {
        require (_totalSupply > 0, "Init Strategy first");

        // Caching
        IPool pool_ =  IPool(ladle.pools(seriesId_));
        uint256 baseValue = value; // We could read the real balance, but this is a bit safer

        require(base == pool_.base(), "Mismatched base");

        // Find pool proportion p = tokenReserves/(tokenReserves + fyTokenReserves)
        // Deposit (investment * p) base to borrow (investment * p) fyToken
        //   (investment * p) fyToken + (investment * (1 - p)) base = investment
        //   (investment * p) / ((investment * p) + (investment * (1 - p))) = p
        //   (investment * (1 - p)) / ((investment * p) + (investment * (1 - p))) = 1 - p

        // The Pool mints based on cached values, not actual ones.
        uint256 baseInPool = pool_.getBaseBalance();
        uint256 fyTokenInPool = pool_.getFYTokenBalance() - pool_.totalSupply();

        uint256 baseToPool = (baseValue * baseInPool).divUp(baseInPool + fyTokenInPool);  // Rounds up
        uint256 fyTokenToPool = baseValue - baseToPool;        // fyTokenToPool is rounded down

        // Borrow fyToken with underlying as collateral
        (bytes12 vaultId_,) = ladle.build(seriesId_, baseId, 0);
        base.safeTransfer(baseJoin, fyTokenToPool);
        ladle.pour(vaultId_, address(pool_), fyTokenToPool.i128(), fyTokenToPool.i128());

        // In the edge case that we have ejected from a pool, and then invested on another pool for
        // the same series, we could reuse the fyToken. However, that is complex and `eject` should
        // have minimized the amount of available fyToken.

        // Mint LP tokens with (investment * p) fyToken and (investment * (1 - p)) base
        base.safeTransfer(address(pool_), baseToPool);
        (,, poolValue) = pool_.mint(address(this), address(this), minRatio, maxRatio);

        // Reset the value cache
        value = poolValue;

        _transition(State.INVESTED, vaultId_);

        emit Invested(address(pool_), baseValue, poolValue);
    }

    /// @dev Divest out of a pool once it has matured. Only when invested and matured.
    /// @param baseValue Amount of base tokens obtained, which is now the value in base terms of the strategy.
    function divest()
        external
        isState(State.INVESTED)
        returns (uint256 baseValue)
    {
        // Caching
        IPool pool_ = pool;
        IFYToken fyToken_ = fyToken;
        require (uint32(block.timestamp) >= maturity, "Only after maturity");

        uint256 poolBalance = pool_.balanceOf(address(this));

        // Burn poolTokens
        pool_.safeTransfer(address(pool_), poolBalance);
        (, uint256 baseFromBurn, uint256 fyTokenFromBurn) = pool_.burn(address(this), address(this), 0, type(uint256).max); // We don't care about slippage, because the strategy holds to maturity

        // Redeem any fyToken
        uint256 baseFromRedeem = fyToken_.redeem(address(this), fyTokenFromBurn);

        // Reset the value cache
        value = baseValue = base.balanceOf(address(this));

        _transition(State.DIVESTED, bytes12(0));

        emit Divested(address(pool_), poolBalance, baseFromBurn + baseFromRedeem);
    }

    /// @dev Divest out of a pool at any time. The obtained fyToken will be used to repay debt.
    /// Any remaining fyToken will be sold if possible. Further remaining fyToken will be available to
    /// be bought at face value. If the strategy held pool tokens can't be burnt, they will be sent to msg.sender.
    /// Only when invested. Can lead to divested, ejected, or drained states.
    /// @return baseReceived The amount of base tokens obtained by burning pool tokens and swapping fyToken.
    /// @return fyTokenReceived The amount of fyTokens obtained by burning pool tokens and that couldn't be swapped for base.
    function eject()
        external
        auth
        isState(State.INVESTED)
        returns (uint256 baseReceived, uint256 fyTokenReceived)
    {
        // Caching
        IPool pool_ = pool;
        IFYToken fyToken_ = fyToken;

        uint256 poolBalance = pool_.balanceOf(address(this));

        // Burn lpTokens, if not possible, eject the pool tokens out. Slippage should be managed by the caller.
        try this.burnPoolTokens(pool_, poolBalance) returns (uint256 baseReceived_, uint256 fyTokenReceived_) {
            baseReceived = baseReceived_;
            fyTokenReceived = fyTokenReceived_;
            if (fyTokenReceived == 0) {
                // Reset the value cache
                value = base.balanceOf(address(this));
                _transition(State.DIVESTED, bytes12(0));
                emit Divested(address(pool_), poolBalance, baseReceived);
            } else {
                // Repay as much debt as possible
                uint256 debt = cauldron.balances(vaultId).art;
                uint256 toRepay = debt < fyTokenReceived ? debt : fyTokenReceived;
                fyToken_.safeTransfer(address(fyToken_), toRepay);
                ladle.pour(vaultId, address(this), -(toRepay).i128(), -(toRepay).i128());
                // There is an edge case in which surplus fyToken from a previous ejection could have been used. Not worth the complexity.

                // Sell fyToken if possible
                uint256 ejected_ = fyTokenReceived - toRepay;
                if (ejected_ > 0) {
                    try this._sellFYToken(pool_, fyToken, address(this), ejected_) returns (uint256) { // The pool might not have liquidity for this sale
                        ejected_ = 0;
                    } catch {}
                }

                // Reset the value cache
                value = base.balanceOf(address(this));
                ejected = fyToken_.balanceOf(address(this));
                _transition(State.EJECTED, bytes12(0));
                emit Ejected(address(pool_), poolBalance, baseReceived, fyTokenReceived);
            }
        } catch { // We can't burn, so we spit out the pool tokens and wait for recapitalization
            delete value;
            pool_.safeTransfer(msg.sender, poolBalance);
            _transition(State.DRAINED, bytes12(0));
            emit Drained(address(pool_), poolBalance);
        }
    }

    // ----------------------- EJECTED FYTOKEN --------------------------- //

    /// @dev Buy ejected fyToken in the strategy at face value. Only when ejected.
    /// @param fyTokenTo Address to send the purchased fyToken to.
    /// @param baseTo Address to send any remaining base to.
    /// @return soldFYToken Amount of fyToken sold.
    function buyEjected(address fyTokenTo, address baseTo)
        external
        isState(State.EJECTED)
        returns (uint256 soldFYToken, uint256 returnedBase)
    {
        // Caching
        IFYToken fyToken_ = fyToken;

        uint256 baseIn = base.balanceOf(address(this)) - value;
        uint256 fyTokenBalance = fyToken_.balanceOf(address(this));
        (soldFYToken, returnedBase) = baseIn > fyTokenBalance ? (fyTokenBalance, baseIn - fyTokenBalance) : (baseIn, 0);

        // Update ejected and transition to divested if done
        if ((ejected -= soldFYToken) == 0) {
            _transition(State.DIVESTED, bytes12(0));
            // There shouldn't be a reason to update the base cache
        }

        // Transfer fyToken and base (if surplus)
        fyToken_.safeTransfer(fyTokenTo, soldFYToken);
        if (soldFYToken < baseIn) {
            base.safeTransfer(baseTo, baseIn - soldFYToken);
        }

        emit SoldEjected(seriesId, soldFYToken, returnedBase);
    }

    /// @dev If we ejected the pool tokens, we can recapitalize the strategy to avoid a forced migration. Only when drained.
    /// @return baseIn Amount of base tokens used to restart
    function restart()
        external
        auth
        isState(State.DRAINED)
        returns (uint256 baseIn)
    {
        value = baseIn = base.balanceOf(address(this));
        _transition(State.DIVESTED, bytes12(0));
        emit Divested(address(0), 0, 0);
    }

    // ----------------------- MINT & BURN --------------------------- //

    /// @dev Mint strategy tokens while invested in a pool. Only when invested.
    /// @param to Receiver for the strategy tokens.
    /// @param minRatio Minimum ratio of base to fyToken accepted in the pool.
    /// @param maxRatio Maximum ratio of base to fyToken accepted in the pool.
    /// @return minted The amount of strategy tokens created.
    /// @notice The base tokens that the user contributes need to have been transferred previously, using a batchable router.
    function mint(address to, uint256 minRatio, uint256 maxRatio)
        external
        isState(State.INVESTED)
        returns (uint256 minted)
    {
        // Caching
        IPool pool_ = pool;
        uint256 value_ = value;

        // minted = supply * value(deposit) / value(strategy)

        // Find how much was deposited, knowing that the strategy doesn't hold any base while invested
        uint256 deposit = base.balanceOf(address(this));

        // Now, put the funds into the Pool
        uint256 baseInPool = pool_.getBaseBalance();
        uint256 fyTokenInPool = pool_.getFYTokenBalance() - pool_.totalSupply();

        uint256 baseToPool = (deposit * baseInPool).divUp(baseInPool + fyTokenInPool);  // Rounds up
        uint256 fyTokenToPool = deposit - baseToPool;        // fyTokenToPool is rounded down

        // Borrow fyToken with underlying as collateral
        base.safeTransfer(baseJoin, fyTokenToPool);
        ladle.pour(vaultId, address(pool_), fyTokenToPool.i128(), fyTokenToPool.i128());

        // Mint LP tokens with (investment * p) fyToken and (investment * (1 - p)) base
        base.safeTransfer(address(pool_), baseToPool);
        (,, uint256 poolTokensMinted) = pool_.mint(address(this), address(this), minRatio, maxRatio); // TODO: Can we do better slippage than this? Ask Allan.

        // Update the value cache
        value = value_ + poolTokensMinted;

        // Mint strategy tokens
        minted = _totalSupply * poolTokensMinted / value_;
        _mint(to, minted);
    }

    /// @dev Burn strategy tokens to withdraw base tokens. Only when invested.
    /// @param baseTo Receiver for the base obtained.
    /// @param fyTokenTo Receiver for the fyToken obtained, if any.
    /// @param minBaseReceived Minimum amount of base to be accepted.
    /// @return baseObtained The amount of base tokens obtained by burning strategy tokens.
    /// @return fyTokenObtained The amount of fyToken obtained by burning strategy tokens.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function burn(address baseTo, address fyTokenTo, uint256 minBaseReceived)
        external
        isState(State.INVESTED)
        returns (uint256 baseObtained, uint256 fyTokenObtained)
    {
        // Caching
        IPool pool_ = pool;
        IFYToken fyToken_ = fyToken;
        uint256 value_ = value;
        uint256 availableDebt;
        uint256 poolTokensBurnt;
        { // Stack too deep
            uint256 totalSupply_ = _totalSupply;
            uint256 burnt = _balanceOf[address(this)];
            availableDebt = cauldron.balances(vaultId).art * burnt / totalSupply_;

            // Burn strategy tokens
            _burn(address(this), burnt);

            // Burn poolTokens
            poolTokensBurnt = pool.balanceOf(address(this)) * burnt / totalSupply_;
            pool_.safeTransfer(address(pool_), poolTokensBurnt);
            (, baseObtained, fyTokenObtained) = pool_.burn(baseTo, address(this), 0, type(uint256).max);

            // Repay as much debt as possible
            uint256 toRepay = availableDebt < fyTokenObtained ? availableDebt : fyTokenObtained;
            fyToken_.safeTransfer(address(fyToken_), toRepay);
            ladle.pour(vaultId, address(this), -(toRepay.i128()), -(toRepay.i128()));
            fyTokenObtained -= toRepay;
            baseObtained += toRepay;
        }

        // Sell any fyToken that are left
        if (fyTokenObtained > 0) {
            try this._sellFYToken(pool_, fyToken_, baseTo, fyTokenObtained) returns (uint256 baseFromSale) { // The pool might not have liquidity for this sale
                baseObtained += baseFromSale;
            } catch {
                fyToken_.safeTransfer(fyTokenTo, fyTokenObtained);
            }
        }

        // Update cached value
        value = value_ - poolTokensBurnt;

        // Slippage
        require (baseObtained >= minBaseReceived, "Not enough base obtained");
    }

    /// @dev Mint strategy tokens with base tokens. Only when divested.
    /// @param to Receiver for the strategy tokens obtained.
    /// @return minted The amount of strategy tokens created.
    /// @notice The base tokens that the user invests need to have been transferred previously, using a batchable router.
    function mintDivested(address to)
        external
        isState(State.DIVESTED)
        returns (uint256 minted)
    {
        // minted = supply * value(deposit) / value(strategy)
        uint256 value_ = value;
        uint256 deposit = base.balanceOf(address(this)) - value_;
        value = value_ + deposit;

        minted = _totalSupply * deposit / value_;

        _mint(to, minted);
    }

    /// @dev Burn strategy tokens to withdraw base tokens. Only when divested.
    /// @param to Receiver for the base obtained.
    /// @return baseObtained The amount of base tokens obtained by burning strategy tokens.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function burnDivested(address to)
        external
        isState(State.DIVESTED)
        returns (uint256 baseObtained)
    {
        // strategy * burnt/supply = poolTokensBurnt
        uint256 value_ = value;
        uint256 burnt = _balanceOf[address(this)];
        baseObtained = value_ * burnt / _totalSupply;
        value -= baseObtained; // TODO: Are we certain we don't leak value after `divest` or `eject`?

        _burn(address(this), burnt);
        base.safeTransfer(to, baseObtained);
    }

    /// @dev Sell an amount of fyToken.
    /// @notice Only the Strategy itself can call this function. It is external and exists so that the transfer is reverted if the burn also reverts.
    /// @param pool_ Pool for the pool tokens.
    /// @param fyToken_ FYToken to sell.
    /// @param fyTokenAmount Amount of fyToken to sell.
    /// @return baseObtained Amount of base tokens obtained from sale of fyToken
    function _sellFYToken(IPool pool_, IFYToken fyToken_, address to, uint256 fyTokenAmount)
        external
        returns (uint256 baseObtained)
    {
        require (msg.sender ==  address(this), "Unauthorized");

        // Burn poolTokens
        fyToken_.safeTransfer(address(pool_), fyTokenAmount);
        baseObtained = pool_.sellFYToken(to, 0); // TODO: Slippage
    }

    /// @dev Burn an amount of pool tokens.
    /// @notice Only the Strategy itself can call this function. It is external and exists so that the transfer is reverted if the burn also reverts.
    /// @param pool_ Pool for the pool tokens.
    /// @param poolTokens Amount of tokens to burn.
    /// @return baseReceived Amount of base tokens received from pool tokens
    /// @return fyTokenReceived Amount of fyToken received from pool tokens
    function burnPoolTokens(IPool pool_, uint256 poolTokens)
        external
        returns (uint256 baseReceived, uint256 fyTokenReceived)
    {
        require (msg.sender ==  address(this), "Unauthorized");

        // Burn lpTokens
        pool_.safeTransfer(address(pool_), poolTokens);
        (, baseReceived, fyTokenReceived) = pool_.burn(address(this), address(this), 0, type(uint256).max);
    }
}