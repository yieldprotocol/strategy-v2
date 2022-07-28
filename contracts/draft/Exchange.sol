// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import "./interfaces/IExchange.sol"; // Imports IExchange, IStrategy
import "@yield-protocol/utils-v2/contracts/math/WMul.sol";
import "@yield-protocol/utils-v2/contracts/math/WDiv.sol";
import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/MinimalTransferHelper.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";

library CastU256U96 {
    /// @dev Safely cast an uint256 to an uint96
    function u96(uint256 x) internal pure returns (uint96 y) {
        require (x <= type(uint96).max, "Cast overflow");
        y = uint96(x);
    }
}

/// @dev The Exchange contract takes base currency from strategies, and uses
/// those assets to mint tokens from a different strategy. Then, the Exchange
/// allows swapping tokens from the first strategy for those of the second, at
/// the same rate that was obtained during the registration.
contract Exchange is AccessControl, IExchange {
    using MinimalTransferHelper for IERC20;
    using WMul for uint256;
    using WDiv for uint256;
    using CastU256U96 for uint256;

    struct RelativeValue {
        IStrategy dstStrategy;
        uint96 value;
    }

    /// A strategy was registered, meaning all its assets were used to mint `mintedStrategy` tokens from
    /// `dstStrategy`, and that for that operation the relative value between `srcStrategy` and `dstStrategy`
    /// tokens is `relativeValue`.
    event Registered(IStrategy indexed srcStrategy, IStrategy indexed dstStrategy, uint256 mintedStrategy, uint256 relativeValue);

    /// `srcStrategyIn` tokens from `srcStrategy` from the caller were burnt for `dstStrategyOut` tokens from `dstStrategy`
    event Swap(IStrategy indexed srcStrategy, IStrategy indexed dstStrategy, uint256 srcStrategyIn, uint256 dstStrategyOut);

    /// The strategy in question hasn't been registered
    error StrategyNotRegistered(IStrategy strategy);

    /// @dev Registered `srcStrategy`/`dstStrategy` pairs and the relative value of their tokens at registration time.
    mapping(IStrategy => RelativeValue) public relativeValues; 

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
    function register(IStrategy srcStrategy, IStrategy dstStrategy)
        external
        override
        auth
        returns (uint256 mintedStrategy, uint256 relativeValue)
    {
        // Accept base
        IERC20 base = dstStrategy.base();
        uint256 baseReceived = base.balanceOf(address(this));

        // Mint LP tokens with base
        IPool pool = dstStrategy.pool();
        base.safeTransfer(address(pool), baseReceived);
        pool.mint(address(dstStrategy), address(0), 0, type(uint256).max); // This will revert if the pool has any fyToken, which is what we want.

        // Invest in dst strategy
        mintedStrategy = dstStrategy.mint(address(this));
        relativeValue = mintedStrategy.wdiv(srcStrategy.totalSupply()); // We round down everywhere, meaning some wei will be locked in this contract.

        // Store dst vs src strategy tokens relative value
        relativeValues[srcStrategy] = RelativeValue(
            dstStrategy,
            relativeValue.u96()
        );

        emit Registered(srcStrategy, dstStrategy, mintedStrategy, relativeValue);
    }

    /// @dev Exchange tokens of a strategy for those of another at the registered rate
    function swap(IStrategy srcStrategy, address to)
        external
        override
        returns (uint256 srcStrategyIn, uint256 dstStrategyOut)
    {
        RelativeValue memory relativeValue = relativeValues[srcStrategy];
        if (relativeValue.dstStrategy == IStrategy(address(0))) revert StrategyNotRegistered(srcStrategy);

        // Accept srcStrategy tokens
        srcStrategyIn = srcStrategy.balanceOf(address(this));

        // Burn srcStrategy tokens (by sending them to 0x00)
        IERC20(srcStrategy).safeTransfer(address(0), srcStrategyIn);
        
        // Send dstStrategy tokens in exchange
        dstStrategyOut = srcStrategyIn.wmul(relativeValue.value);
        IERC20(relativeValue.dstStrategy).safeTransfer(to, dstStrategyOut);

        emit Swap(srcStrategy, relativeValue.dstStrategy, srcStrategyIn, dstStrategyOut);
    }
}