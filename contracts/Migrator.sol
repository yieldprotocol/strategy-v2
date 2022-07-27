// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.14;

import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/MinimalTransferHelper.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";


/// @dev The Migrator contract poses as a Pool to take all assets from a Strategy
/// during a call to `startPool`. Then it passes on those assets to an Exchange
/// contract, which is expected to immediately invest them in a new Strategy.
/// Immediately after calling `startPool` in the outgoing Strategy, `endPool`
/// should be called to stop anyone from minting outgoing Strategy tokens, and
/// the `startPool` function should be locked to ensure that new tokens for the
/// outgoing Strategy can never be minted.
contract Migrator is AccessControl {

    /// @dev Accept base from a calling strategy, send it to the strategy
    /// exchange, and register a migration from the old to the new strategies
    function mint(IStrategy oldStrategy, address, uint256 newStrategy_, uint256 exchange_)
        external
        auth
        returns (uint256, uint256, uint256)
    {
        // Convert the newStrategy and exchange parameters
        IStrategy newStrategy = IStrategy(address(bytes20(bytes32(newStrategy_))));
        IStrategy exchange = IStrategy(address(bytes20(bytes32(exchange_))));

        IERC20 base = oldStrategy.base();
        if (base != newStrategy.base()) revert BaseMismatch();

        // Accept base
        uint256 baseReceived = base.balanceOf(address(this));
        if (baseReceived == 0) revert NoBaseReceived();

        // Register the old strategy in the strategy exchange
        base.safeTransfer(address(exchange), baseReceived);
        exchange.register(oldStrategy, newStrategy);

        emit Migrated(address(oldStrategy), address(newStrategy), baseReceived);

        return (0, 0, 0);
    }

    /// @dev Mock burn
    function burn(address, address, uint256, uint256) external returns(uint256, uint256, uint256) {
        return (0, 0, 0);
    }

    /// @dev Mock maturity
    function maturity() external view returns(uint256) {
        return block.timestamp - 1;
    }

    /// @dev Mock fyToken
    function fyToken() external view returns(IFYToken) {
        return address(this);
    }

    /// @dev Mock balanceOf
    function balanceOf(address) external view returns(uint256) {
        return 0;
    }

    /// @dev Mock redeem
    function redeem(address, uint256) external returns(uint256) {
        return 0;
    }

    /// @dev Mock invariant function
    function invariant() external view returns (uint256) {
        return 1e18; // Starting value for a v2 pool invariant
    }
}