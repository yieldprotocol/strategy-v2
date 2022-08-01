// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.6.0;

import "../../interfaces/IStrategy.sol";
// import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";

/// @dev The Exchange contract takes base currency from strategies, and uses
/// those assets to mint tokens from a different strategy. Then, the Exchange
/// allows swapping tokens from the first strategy for those of the second, at
/// the same rate that was obtained during the registration.
interface IExchange {
    /// @dev Accept base from the calling strategy, invest it in a dst strategy,
    /// and register the calling strategy to dst strategy relative token price.
    /// @notice The calling strategy needs to be decommissioned. If its token
    /// can still change in value relative to base there would be an arbitrage
    /// opportunity.
    /// This function can only be called when the dst strategy is invested in A
    /// pool that doesn't yet hsrc any fyToken, to simplify the implementation and
    /// minimize risks.
    /// It is not possible to verify that neither the src nor the dst strategy arbitrage
    /// not malicious, so this function must remain as `auth`
    function register(IStrategy srcStrategy, IStrategy dstStrategy) external returns (uint256 mintedStrategy, uint256 relativeValue);

    /// @dev Exchange tokens of a strategy for those of another at the registered rate
    function swap(IStrategy srcStrategy, address to) external returns (uint256 srcStrategyIn, uint256 dstStrategyOut);
}