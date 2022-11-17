// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import {IStrategy} from "./interfaces/IStrategy.sol";
import {StrategyMigrator} from "./StrategyMigrator.sol";
import {AccessControl} from "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import {SafeERC20Namer} from "@yield-protocol/utils-v2/contracts/token/SafeERC20Namer.sol";
import {MinimalTransferHelper} from "@yield-protocol/utils-v2/contracts/token/MinimalTransferHelper.sol";
import {IERC20} from "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import {ERC20Rewards} from "@yield-protocol/utils-v2/contracts/token/ERC20Rewards.sol";
import {CastU256I128} from "@yield-protocol/utils-v2/contracts/cast/CastU256I128.sol";
import {IFYToken} from "@yield-protocol/vault-v2/contracts/interfaces/IFYToken.sol";
import {ICauldron} from "@yield-protocol/vault-v2/contracts/interfaces/ICauldron.sol";
import {ILadle} from "@yield-protocol/vault-v2/contracts/interfaces/ILadle.sol";
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
contract Strategy is AccessControl, ERC20Rewards, StrategyMigrator { // TODO: I'd like to import IStrategy
    using DivUp for uint256;
    using MinimalTransferHelper for IERC20;
    using MinimalTransferHelper for IFYToken;
    using MinimalTransferHelper for IPool;
    using CastU256I128 for uint256;

    event LadleSet(ILadle ladle);
    event TokenJoinReset(address join);

    event Invested(address indexed pool, uint256 baseInvested, uint256 lpTokensObtained);
    event Divested(address indexed pool, uint256 lpTokenDivested, uint256 baseObtained);
    event Ejected(address indexed pool, uint256 lpTokenDivested, uint256 baseObtained, uint256 fyTokenObtained);
    event Redeemed(bytes6 indexed seriesId, uint256 redeemedFYToken, uint256 receivedBase);
    event SoldEjected(bytes6 indexed seriesId, uint256 soldFYToken, uint256 returnedBase);

    // TODO: Global variables can be packed

    ILadle public ladle;                         // Gateway to the Yield v2 Collateralized Debt Engine
    ICauldron public immutable cauldron;         // Accounts in the Yield v2 Collateralized Debt Engine
    bytes6 public immutable baseId;              // Identifier for the base token in Yieldv2
    // IERC20 public immutable base;             // Base token for this strategy (inherited from StrategyMigrator)
    address public baseJoin;                     // Yield v2 Join to deposit token when borrowing

    bytes12 public vaultId;                      // VaultId for the Strategy debt
    bytes6 public seriesId;                      // Identifier for the current seriesId
    // IFYToken public override fyToken;         // Current fyToken for this strategy (inherited from StrategyMigrator)
    IPool public pool;                           // Current pool that this strategy invests in

    uint256 public baseValue;                    // While divested, base tokens owned by the strategy. While invested, value of the strategy holdings in base terms.
    uint256 public ejected;                      // In emergencies, the strategy can keep fyToken

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
            ejected > 0,
            "Not ejected"
        );
        _;
    }

    modifier notEjected() {
        require (
            ejected == 0,
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
        // Clear state variables from a potential migration
        delete seriesId;
        delete fyToken;
        delete maturity;
        delete pool;
        delete vaultId;

        require (_totalSupply == 0, "Already initialized");
        baseValue = minted = base.balanceOf(address(this));
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
    {
        require (_totalSupply > 0, "Init Strategy first");

        // Caching
        IPool pool_ =  IPool(ladle.pools(seriesId_));
        IFYToken fyToken_ = IFYToken(address(pool_.fyToken()));
        uint256 baseValue_ = baseValue; // We could read the real balance, but this is a bit safer

        require(base == pool_.base(), "Mismatched base");

        // Find pool proportion p = tokenReserves/(tokenReserves + fyTokenReserves)
        // Deposit (investment * p) base to borrow (investment * p) fyToken
        //   (investment * p) fyToken + (investment * (1 - p)) base = investment
        //   (investment * p) / ((investment * p) + (investment * (1 - p))) = p
        //   (investment * (1 - p)) / ((investment * p) + (investment * (1 - p))) = 1 - p

        // The Pool mints based on cached values, not actual ones.
        uint256 baseInPool = pool_.getBaseBalance();
        uint256 fyTokenInPool = pool_.getFYTokenBalance() - pool_.totalSupply();

        uint256 baseToPool = (baseValue_ * baseInPool).divUp(baseInPool + fyTokenInPool);  // Rounds up
        uint256 fyTokenToPool = baseValue_ - baseToPool;        // fyTokenToPool is rounded down

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

        emit Invested(address(pool_), baseValue_, lpTokenMinted);
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
        baseValue = base.balanceOf(address(this));

        // Transition to Divested
        delete seriesId;
        delete fyToken;
        delete maturity;
        delete pool;
        delete vaultId;

        emit Divested(address(pool_), toDivest, baseFromBurn + baseFromRedeem);
    }

    /// @dev Divest out of a pool at any time. The obtained fyToken will be used to repay debt.
    /// Any surplus will be kept in the contract until maturity, at which point `redeemEjected`
    /// should be called.
    function eject(uint256 minRatio, uint256 maxRatio)
        external
        auth
        invested
    {
        // Caching
        IPool pool_ = pool;
        IFYToken fyToken_ = fyToken;

        uint256 toDivest = pool_.balanceOf(address(this));

        // Burn lpTokens
        pool_.safeTransfer(address(pool_), toDivest);
        (, uint256 baseReceived, uint256 fyTokenReceived) = pool_.burn(address(this), address(this), minRatio, maxRatio);

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

        // Reset the base cache
        baseValue = base.balanceOf(address(this));

        // If there are any fyToken left, transition to ejected state
        if (ejected_ > 0) {
            ejected = ejected_;

            delete pool;

            emit Ejected(address(pool_), toDivest, baseReceived + toRepay, ejected_);
        } else { // Otherwise, transition to divested state
            delete seriesId;
            delete fyToken;
            delete maturity;
            delete pool;
            delete vaultId;

            emit Divested(address(pool_), toDivest, baseReceived + toRepay);
        }
    }

    // ----------------------- EJECTED FYTOKEN --------------------------- //

    /// @dev Buy ejected fyToken in the strategy at face value
    /// @param fyTokenTo Address to send the purchased fyToken to.
    /// @param baseTo Address to send any remaining base to.
    /// @return soldFYToken Amount of fyToken sold.
    function buyEjected(address fyTokenTo, address baseTo)
        external
        divested
        isEjected
        returns (uint256 soldFYToken, uint256 returnedBase)
    {
        // Caching
        bytes6 seriesId_ = seriesId;
        IFYToken fyToken_ = fyToken;

        uint256 baseIn = base.balanceOf(address(this)) - baseValue;
        uint256 fyTokenBalance = fyToken_.balanceOf(address(this));
        (soldFYToken, returnedBase) = baseIn > fyTokenBalance ? (fyTokenBalance, baseIn - fyTokenBalance) : (baseIn, 0);

        // Update ejected and reset if done
        if ((ejected -= soldFYToken) == 0) {
            // Transition to Divested
            delete seriesId;
            delete fyToken;
            delete maturity;
            delete vaultId; // We either burned all the fyToken, or there is no debt left.
        }

        // Update base cache
        baseValue += soldFYToken;

        // Transfer fyToken and base (if surplus)
        fyToken_.safeTransfer(fyTokenTo, soldFYToken);
        if (soldFYToken < baseIn) {
            base.safeTransfer(baseTo, baseIn - soldFYToken);
        }

        emit SoldEjected(seriesId_, soldFYToken, returnedBase);
    }

    // ----------------------- MINT & BURN --------------------------- //

    /// @dev Mint strategy tokens.
    /// @notice The base tokens that the user contributes need to have been transferred previously, using a batchable router.
    function mint(address to, uint256 minRatio, uint256 maxRatio)
        external
        returns (uint256 minted)
    {
        address pool_ = address(pool);

        // If we are invested and past maturity, divest
        if (pool_ != address(0) && block.timestamp >= maturity) {
            uint256 deposit = base.balanceOf(address(this)); // Cache the deposit
            this.divest();
            baseValue -= deposit; // Release the deposit
            pool_ = address(pool);
        }

        if (pool_ == address(0)) {
            minted = _mintDivested(to);
        } else {
            minted = _mintInvested(to, minRatio, maxRatio);
        }
    }

    /// @dev Burn strategy tokens to withdraw base tokens.
    /// @notice If the strategy ejected from a previous investment, some fyToken might be received.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function burn(address baseTo, address fyTokenTo, uint256 minBaseReceived)
        external
        returns (uint256 baseObtained, uint256 fyTokenObtained)
    {
        address pool_ = address(pool);

        // If we are invested and past maturity, divest
        if (pool_ != address(0) && block.timestamp >= maturity) {
            this.divest();
            pool_ = address(pool);
        }

        if (pool_ == address(0)) {
            (baseObtained, fyTokenObtained) = _burnDivested(baseTo, fyTokenTo);
        } else {
            (baseObtained, fyTokenObtained) = _burnInvested(baseTo, fyTokenTo, minBaseReceived);
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
        uint256 baseValue_ = baseValue;

        // minted = supply * value(deposit) / value(strategy)

        // Find how much was deposited, knowing that the strategy doesn't hold any base while invested
        uint256 deposit = base.balanceOf(address(this));

        // Update the base cache
        baseValue = baseValue_ + deposit;

        // Mint strategy tokens
        minted = _totalSupply * deposit / baseValue_;
        _mint(to, minted);

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
        pool_.mint(address(this), address(this), minRatio, maxRatio); // TODO: Can we do better slippage than this? Ask Allan.
    }

    /// @dev Burn strategy tokens to withdraw base tokens.
    /// @notice If the strategy ejected from a previous investment, some fyToken might be received.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function _burnInvested(address baseTo, address fyTokenTo, uint256 minBaseReceived)
        internal
        invested
        returns (uint256 baseObtained, uint256 fyTokenObtained)
    {
        // Caching
        IPool pool_ = pool;
        IFYToken fyToken_ = fyToken;
        uint256 baseValue_ = baseValue;
        uint256 availableDebt;
        { // Stack too deep
            uint256 totalSupply_ = _totalSupply;
            uint256 burnt = _balanceOf[address(this)];
            availableDebt = cauldron.balances(vaultId).art * burnt / totalSupply_;

            // Burn strategy tokens
            _burn(address(this), burnt);

            // Burn lpTokens
            uint256 withdrawal = pool.balanceOf(address(this)) * burnt / totalSupply_;
            pool_.safeTransfer(address(pool_), withdrawal);
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

        // Update cached base
        console2.log(baseValue_);
        console2.log(baseObtained + fyTokenObtained);
        baseValue = baseValue_ - baseObtained - fyTokenObtained; // TODO: Valuing fyToken at 1:1 is wrong, and this can take baseValue below zero

        // Slippage
        require (baseObtained >= minBaseReceived, "Not enough base obtained");
    }

    /// @dev Mint strategy tokens with base tokens. It can be called only when not invested.
    /// @notice The base tokens that the user invests need to have been transferred previously, using a batchable router.
    function _mintDivested(address to)
        internal
        divested
        returns (uint256 minted)
    {
        // minted = supply * value(deposit) / value(strategy)
        uint256 baseValue_ = baseValue;
        uint256 deposit = base.balanceOf(address(this)) - baseValue_;
        baseValue = baseValue_ + deposit;

        minted = _totalSupply * deposit / (baseValue_ + ejected); // We value ejected fyToken at 1:1

        _mint(to, minted);
    }

    /// @dev Burn strategy tokens to withdraw base tokens. It can be called when not invested.
    /// @notice If the strategy ejected from a previous investment, some fyToken might be received.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function _burnDivested(address baseTo, address ejectedFYTokenTo)
        internal
        divested
        returns (uint256 baseObtained, uint256 fyTokenObtained)
    {
        // strategy * burnt/supply = withdrawal
        uint256 baseValue_ = baseValue;
        uint256 totalSupply_ = _totalSupply;
        uint256 burnt = _balanceOf[address(this)];
        baseObtained = baseValue_ * burnt / _totalSupply;
        baseValue -= baseObtained; // TODO: Are we certain we don't leak value after `divest` or `eject`?

        _burn(address(this), burnt);
        base.safeTransfer(baseTo, baseObtained);

        // If we have ejected fyToken, we we give them out in the same proportion
        uint256 ejected_ = ejected;
        if (ejected_ > 0) fyTokenObtained = _transferEjected(ejectedFYTokenTo, (ejected_ * burnt).divUp(totalSupply_)); // Let's not leave a lonely wei
    }

    /// @dev Transfer out fyToken from the ejected cache
    function _transferEjected(address to, uint256 amount)
        internal
        returns (uint256 fyTokenObtained)
    {
        fyToken.safeTransfer(to, fyTokenObtained = amount);

        if ((ejected -= amount) == 0) {
            // Transition to Divested
            delete seriesId;
            delete fyToken;
            delete maturity;
            delete vaultId; // We either burned all the fyToken, or there is no debt left.

            emit Divested(address(0), 0, 0); // Signalling the transition from Ejected to Divested
        }
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

        // Burn lpTokens
        fyToken_.safeTransfer(address(pool_), fyTokenAmount);
        baseObtained = pool_.sellFYToken(to, 0); // TODO: Slippage
    }
}