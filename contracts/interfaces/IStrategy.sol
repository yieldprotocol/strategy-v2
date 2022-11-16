// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import {IStrategyMigrator} from "./IStrategyMigrator.sol";
import {IERC20} from "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import {IFYToken} from "@yield-protocol/vault-v2/contracts/interfaces/IFYToken.sol";
import {ICauldron} from "@yield-protocol/vault-v2/contracts/interfaces/ICauldron.sol";
import {ILadle} from "@yield-protocol/vault-v2/contracts/interfaces/ILadle.sol";
import {IPool} from "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";


/// @dev The Strategy contract allows liquidity providers to provide liquidity in underlying
/// and receive strategy tokens that represent a stake in a YieldSpace pool contract.
/// Upon maturity, the strategy can `divest` from the mature pool, becoming a proportional
/// ownership underlying vault. When not invested, the strategy can `invest` into a Pool using
/// all its underlying.
/// The strategy can also `eject` from a Pool before maturity, immediately converting its assets
/// to underlying as much as possible. If any fyToken can't be exchanged for underlying, the
/// strategy will hold them until maturity when `redeemEjected` can be used.
interface IStrategy is IStrategyMigrator {
    function ladle() external view returns(ILadle);                         // Gateway to the Yield v2 Collateralized Debt Engine
    function cauldron() external view returns(ICauldron);                   // Accounts in the Yield v2 Collateralized Debt Engine
    function baseId() external view returns(bytes6);                        // Identifier for the base token in Yieldv2
    function base() external view returns(IERC20);                          // Base token for this strategy (inherited from StrategyMigrator)
    function baseJoin() external view returns(address);                     // Yield v2 Join to deposit token when borrowing
    function vaultId() external view returns(bytes12);                      // VaultId for the Strategy debt
    function seriesId() external view returns(bytes6);                      // Identifier for the current seriesId
    function fyToken() external view returns(IFYToken);                     // Current fyToken for this strategy (inherited from StrategyMigrator)
    function pool() external view returns(IPool);                           // Current pool that this strategy invests in
    function baseValue() external view returns(uint256);                   // Base tokens owned by the strategy after the last operation
    function ejected() external view returns(uint256);                // In emergencies, the strategy can keep fyToken of one series

    /// @dev Mint the first strategy tokens, without investing
    function init(address to) external;

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

    /// @dev Buy ejected fyToken in the strategy at face value
    /// @param fyTokenTo Address to send the purchased fyToken to.
    /// @param baseTo Address to send any remaining base to.
    /// @return soldFYToken Amount of fyToken sold.
    function buyEjected(address fyTokenTo, address baseTo) external returns (uint256 soldFYToken, uint256 returnedBase);

    // ----------------------- MINT & BURN --------------------------- //

    /// @dev Mint strategy tokens.
    /// @notice The base tokens that the user contributes need to have been transferred previously, using a batchable router.
    function mint(address to, uint256 minRatio, uint256 maxRatio) external returns (uint256 minted);
 

    /// @dev Burn strategy tokens to withdraw base tokens.
    /// @notice If the strategy ejected from a previous investment, some fyToken might be received.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function burn(address baseTo, address ejectedFYTokenTo, uint256 minBaseReceived) external returns (uint256 withdrawal);
}
