// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.6.0;

import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/ILadle.sol";
import "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";
// import "@yield-protocol/utils-v2/contracts/token/IERC20Rewards.sol";
// import "@yield-protocol/utils-v2/contracts/auth/IAccessControl.sol";


interface IStrategyV1 is IERC20 {

    function base() external returns (IERC20);                // Base token for this strategy
    function baseId() external returns (bytes6);              // Identifier for the base token in Yieldv2
    function baseJoin() external returns (address);           // Yield v2 Join to deposit token when borrowing
    function ladle() external returns (ILadle);               // Gateway to the Yield v2 Collateralized Debt Engine
    function cauldron() external returns (ICauldron);         // Accounts in the Yield v2 Collateralized Debt Engine
    function pool() external returns (IPool);                 // Current pool that this strategy invests in
    function seriesId() external returns (bytes6);            // SeriesId for the current pool in Yield v2
    function fyToken() external returns (IFYToken);           // Current fyToken for this strategy
    function nextPool() external returns (IPool);             // Next pool that this strategy will invest in
    function nextSeriesId() external returns (bytes6);        // SeriesId for the next pool in Yield v2
    function cached() external returns (uint256);             // LP tokens owned by the strategy after the last operation
    function invariants(address) external returns (uint128);  // Value of pool invariant at start time

    /// @dev Set a new Ladle and Cauldron
    /// @notice Use with extreme caution, only for Ladle replacements
    function setYield(ILadle ladle_) external;

    /// @dev Set a new base token id
    /// @notice Use with extreme caution, only for token reconfigurations in Cauldron
    function setTokenId(bytes6 baseId_) external;

    /// @dev Reset the base token join
    /// @notice Use with extreme caution, only for Join replacements
    function resetTokenJoin() external;

    /// @dev Set the next pool to invest in
    function setNextPool(IPool pool_, bytes6 seriesId_) external;

    /// @dev Start the strategy investments in the next pool
    /// @param minRatio Minimum allowed ratio between the reserves of the next pool, as a fixed point number with 18 decimals (base/fyToken)
    /// @param maxRatio Maximum allowed ratio between the reserves of the next pool, as a fixed point number with 18 decimals (base/fyToken)
    /// @notice When calling this function for the first pool, some underlying needs to be transferred to the strategy first, using a batchable router.
    function startPool(uint256 minRatio, uint256 maxRatio) external;

    /// @dev Divest out of a pool once it has matured
    function endPool() external;

    /// @dev Mint strategy tokens.
    /// @notice The lp tokens that the user contributes need to have been transferred previously, using a batchable router.
    function mint(address to) external returns (uint256 minted);

    /// @dev Burn strategy tokens to withdraw lp tokens. The lp tokens obtained won't be of the same pool that the investor deposited,
    /// if the strategy has swapped to another pool.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function burn(address to) external returns (uint256 withdrawn);

    /// @dev Burn strategy tokens to withdraw base tokens. It can be called only when a pool is not selected.
    /// @notice The strategy tokens that the user burns need to have been transferred previously, using a batchable router.
    function burnForBase(address to) external returns (uint256 withdrawn);
}