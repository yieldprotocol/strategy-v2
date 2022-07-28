// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import "./interfaces/IExchange.sol";
import "../interfaces/IStrategy.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/IFYToken.sol";
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
    using MinimalTransferHelper for IERC20;
    
    /// `srcStrategy` migrated its assets of `baseTokens` base to `dstStrategy`
    event Migrated(IStrategy indexed srcStrategy, IStrategy indexed dstStrategy, uint256 baseTokens);

    /// The bases in the strategies don't match
    error BaseMismatch(IERC20 srcBase, IERC20 dstBase);

    /// No base tokens were received
    error NoBaseReceived();

    /// @dev Accept base from a calling strategy, send it to the strategy
    /// exchange, and register a migration from the src to the new strategies
    function mint(IStrategy srcStrategy, address, uint256 dstStrategy_, uint256 exchange_)
        external
        auth
        returns (uint256, uint256, uint256)
    {
        // Convert the dstStrategy and exchange parameters
        IStrategy dstStrategy = IStrategy(address(bytes20(bytes32(dstStrategy_))));
        IExchange exchange = IExchange(address(bytes20(bytes32(exchange_))));

        IERC20 base = srcStrategy.base();
        if (base != dstStrategy.base()) revert BaseMismatch(base, dstStrategy.base());

        // Accept base
        uint256 baseReceived = base.balanceOf(address(this));
        if (baseReceived == 0) revert NoBaseReceived();

        // Register the src strategy in the strategy exchange
        base.safeTransfer(address(exchange), baseReceived);
        exchange.register(srcStrategy, dstStrategy);

        emit Migrated(srcStrategy, dstStrategy, baseReceived);

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
        return IFYToken(address(this));
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