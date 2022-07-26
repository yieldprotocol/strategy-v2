// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.14;

import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/SafeERC20Namer.sol";
import "@yield-protocol/utils-v2/contracts/token/MinimalTransferHelper.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/utils-v2/contracts/token/ERC20Rewards.sol";
import "@yield-protocol/utils-v2/contracts/cast/CastU256I128.sol";
import "@yield-protocol/utils-v2/contracts/cast/CastU128I128.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/DataTypes.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/ICauldron.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/ILadle.sol";
import "@yield-protocol/yieldspace-tv/src/interfaces/IPool.sol";
import "@yield-protocol/yieldspace-tv/src/YieldMathExtensions.sol";


library DivUp {
    /// @dev Divide a between b, rounding up
    function divUp(uint256 a, uint256 b) internal pure returns(uint256 c) {
        // % 0 panics even inside the unchecked, and so prevents / 0 afterwards
        // https://docs.soliditylang.org/en/v0.8.9/types.html 
        unchecked { a % b == 0 ? c = a / b : c = a / b + 1; } 
    }
}

/// @dev The Exchange contract takes base currency from strategies, and uses
/// those assets to mint tokens from a different strategy. Then, the Exchange
/// allows swapping tokens from the first strategy for those of the second, at
/// the same rate that was obtained during the registration.
contract Exchange is AccessControl {

    struct RelativeValue {
        IStrategy: strategy;
        uint96: value
    }

    mapping(IStrategy => RelativeValue) public relativeValues; 

    /// @dev Accept base from the calling strategy, invest it in a new strategy,
    /// and register the calling strategy to new strategy relative token price.
    /// @notice The calling strategy needs to be decommissioned. If its token
    /// can still change in value relative to base there would be an arbitrage
    /// opportunity.
    /// This function can only be called when the new strategy is invested in A
    /// pool that doesn't yet hold any fyToken, to simplify the implementation and
    /// minimize risks.
    /// It is not possible to verify that neither the old nor the new strategy arbitrage
    /// not malicious, so this function must remain as `auth`
    function register(IStrategy oldStrategy, IStrategy newStrategy)
        external
        auth
        returns (uint256 mintedStrategy, uint256 relativeValue)
    {
        // Accept base
        IERC20 base = newStrategy.base();
        uint256 baseReceived = base.balanceOf(address(this));

        // Mint LP tokens with base
        IPool pool = newStrategy.pool();
        require()
        base.safeTransfer(address(pool), baseReceived);
        pool.mint(address(newStrategy), address(0), 0, type(uint256).max);

        // Invest in new strategy
        mintedStrategy = newStrategy.mint(address(this), 0);
        relativeValue = mintedStrategy.wdiv(oldStrategy.totalSupply())

        // Store new vs old strategy tokens relative value
        relativeValues[oldStrategy] = RelativeValue(
            newStrategy,
            relativeValue.u96()
        )

        emit Registered(address(oldStrategy), address(newStrategy), mintedStrategy, relativeValue);
    }

    /// @dev Exchange tokens of a strategy for those of another at the registered rate
    function swap(IStrategy oldStrategy, address to) external returns (uint256 oldStrategyIn, uint256 newStrategyOut) {
        RelativeValue memory relativeValue = relativeValues[oldStrategy];
        if (relativeValue.strategy == address(0)) error StrategyNotFound(oldStrategy);

        // Accept oldStrategy tokens
        uint256 oldStrategyIn = oldStrategy.balanceOf(address(this));

        // Burn oldStrategy tokens (by sending them to 0x00)
        oldStrategy.safeTransfer(oldStrategyIn, address(0));
        
        // Send newStrategy tokens in exchange
        newStrategyOut = oldStrategyReceived.wmul(relativeValue.value);
        relativeValue.strategy.safeTransfer(msg.sender, newStrategySent);

        emit Swap(address(oldStrategy), address(relativeValue.strategy), oldStrategyIn, newStrategyOut);
    }
}