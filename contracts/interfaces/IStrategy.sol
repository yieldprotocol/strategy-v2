// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import "./IStrategyMigrator.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/ICauldron.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/ILadle.sol";
import "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";


/// @dev The Strategy contract allows liquidity providers to provide liquidity in underlying
/// and receive strategy tokens that represent a stake in a YieldSpace pool contract.
/// Upon maturity, the strategy can `divest` from the mature pool, becoming a proportional
/// ownership underlying vault. When not invested, the strategy can `invest` into a Pool using
/// all its underlying.
/// The strategy can also `eject` from a Pool before maturity, immediately converting its assets
/// to underlying as much as possible. If any fyToken can't be exchanged for underlying, the
/// strategy will hold them until maturity when `redeemEjected` can be used.
interface IStrategy is IStrategyMigrator {

    struct EjectedSeries {
        bytes6 seriesId;
        uint128 cached;
    }

    event Invested(address indexed pool, uint256 baseInvested, uint256 lpTokensObtained);
    event Divested(address indexed pool, uint256 lpTokenDivested, uint256 baseObtained);
    event Ejected(address indexed pool, uint256 lpTokenDivested, uint256 baseObtained, uint256 fyTokenObtained);
    event Redeemed(bytes6 indexed seriesId, uint256 redeemedFYToken, uint256 receivedBase);

    function ladle() external view returns(ILadle);                         // Gateway to the Yield v2 Collateralized Debt Engine
    function cauldron() external view returns(ICauldron);                   // Accounts in the Yield v2 Collateralized Debt Engine
    function baseId() external view returns(bytes6);                        // Identifier for the base token in Yieldv2
    function base() external view returns(IERC20);                          // Base token for this strategy (inherited from StrategyMigrator)
    function baseJoin() external view returns(address);                     // Yield v2 Join to deposit token when borrowing
    function vaultId() external view returns(bytes12);                      // VaultId for the Strategy debt
    function seriesId() external view returns(bytes6);                      // Identifier for the current seriesId
    function fyToken() external view returns(IFYToken);                     // Current fyToken for this strategy (inherited from StrategyMigrator)
    function pool() external view returns(IPool);                           // Current pool that this strategy invests in
    function cachedBase() external view returns(uint256);                   // Base tokens owned by the strategy after the last operation
    function ejected() external view returns(EjectedSeries memory);                // In emergencies, the strategy can keep fyToken of one series

    /// @dev Set a new Ladle and Cauldron
    /// @notice Use with extreme caution, only for Ladle replacements
    function setYield(ILadle ladle_) external;

    /// @dev Set a new base token id
    /// @notice Use with extreme caution, only for token reconfigurations in Cauldron
    function setTokenId(bytes6 baseId_) external;

    /// @dev Reset the base token join
    /// @notice Use with extreme caution, only for Join replacements
    function resetTokenJoin() external;

    // ----------------------- STATE CHANGES --------------------------- //

    /// @dev Mock pool mint hooked up to initialize the strategy and return strategy tokens.
    function mint(address, address, uint256, uint256) external override returns (uint256 baseIn, uint256 fyTokenIn, uint256 minted);

    /// @dev Mint the first strategy tokens, without investing
    function init(address to) external returns (uint256 minted);

    /// @dev Start the strategy investments in the next pool
    /// @param minRatio Minimum allowed ratio between the reserves of the next pool, as a fixed point number with 18 decimals (base/fyToken)
    /// @param maxRatio Maximum allowed ratio between the reserves of the next pool, as a fixed point number with 18 decimals (base/fyToken)
    /// @notice When calling this function for the first pool, some underlying needs to be transferred to the strategy first, using a batchable router.
    function invest(bytes6 seriesId_, uint256 minRatio, uint256 maxRatio) external;

    /// @dev Divest out of a pool once it has matured
    function divest() external;

    /// @dev Divest out of a pool at any time. The obtained fyToken will be used to repay debt.
    /// Any surplus will be kept in the contract until maturity, at which point `redeemEjected`
    /// should be called.
    function eject(uint256 minRatio, uint256 maxRatio) external;

    // ----------------------- EJECTED FYTOKEN --------------------------- //

    /// @dev Redeem ejected fyToken in the strategy for base
    function redeemEjected(uint256 redeemedFYToken) external;

    // ----------------------- MINT & BURN --------------------------- //

    /// @dev Mint strategy tokens.
    /// @notice The lp tokens that the user contributes need to have been transferred previously, using a batchable router.
    function mint(address to, uint256 minRatio, uint256 maxRatio) external returns (uint256 minted);

    /// @dev Burn strategy tokens to withdraw lp tokens. The lp tokens obtained won't be of the same pool that the investor deposited,
    /// if the strategy has swapped to another pool.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function burn(address baseTo, address ejectedFYTokenTo, uint256 minBaseReceived) external returns (uint256 withdrawal);

    /// @dev Mint strategy tokens with base tokens. It can be called only when a pool is not selected.
    /// @notice The base tokens that the user invests need to have been transferred previously, using a batchable router.
    function mintDivested(address to) external returns (uint256 minted);

    /// @dev Burn strategy tokens to withdraw base tokens. It can be called only when a pool is not selected.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function burnDivested(address baseTo, address ejectedFYTokenTo) external returns (uint256 withdrawal);

}