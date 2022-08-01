// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import "./interfaces/IExchange.sol";
import "../interfaces/IStrategy.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/ICauldron.sol";
import "@yield-protocol/vault-v2/contracts/interfaces/IFYToken.sol";
import "@yield-protocol/utils-v2/contracts/access/AccessControl.sol";
import "@yield-protocol/utils-v2/contracts/token/MinimalTransferHelper.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";


/// @dev The Migrator contract poses as a Pool to take all assets from a Strategy
/// during a call to `startPool`. Then it passes on those assets to an Exchange
/// contract, which is expected to immediately invest them in a new Strategy.
/// The migrator will state its fyToken is that of the destination Strategy.
/// Before maturity, no one can mint strategy tokens because the migrator is not
/// mintable. No tokens of any kind should ever be sent again to the source Strategy
/// or they will be lost.
contract Migrator is AccessControl {
    using MinimalTransferHelper for IERC20;

    /// Migrator ready to migrate `srcStrategy` to `dstStrategy`
    event Prepared(IStrategy indexed dstStrategy);

    /// `srcStrategy` migrated its assets of `baseTokens` base to `dstStrategy`
    event Migrated(IStrategy indexed srcStrategy, IStrategy indexed dstStrategy, uint256 baseTokens);

    /// `prepare` needs to be called before `srcStrategy.setNextPool()`
    error NotPrepared();

    /// The fyToken in the strategies don't match
    error FYTokenMismatch(IFYToken srcFYToken, IFYToken dstFYToken);

    /// No base tokens were received
    error NoBaseReceived();

    /// Mock srcStrategy totalSupply
    uint256 public totalSupply;

    /// Mock pool fyToken;
    IFYToken public fyToken;

    /// Mock pool base;
    IERC20 public base;

    /// Cauldron
    ICauldron public immutable cauldron;

    constructor(ICauldron cauldron_) {
        cauldron = cauldron_;
    }

    /// @dev During calling `strategy.setNextPool` a call is made to the cauldron to match the fyToken
    /// used by the next pool with the fyToken registerd in the Cauldron with the `seriesId` passed onto
    /// `setNextPool`. Call `migrator.prepare(dstStrategy)` before
    /// `srcStrategy.setNextPool(IPool(address(migrator)), dstStrategy.seriesId())`
    function prepare(IStrategy dstStrategy)
        external
        auth
    {
        fyToken = cauldron.series(dstStrategy.seriesId()).fyToken;
        base = IERC20(fyToken.underlying());
        emit Prepared(dstStrategy);
    }

    /// @dev Accept base from a calling strategy, send it to the strategy
    /// exchange, and register a migration from the src to the new strategies
    /// We are hacking the `minRatio` and `maxRatio` parameters to pass in them
    /// the `dstStrategy` address and the `exchange` address, respectively.
    /// @notice Unlike in a real Pool contract, this function is `auth` to ApproveFailed
    /// abuse. That means that the source strategy needs to be given permission to `mint`
    /// into the migrator contract.
    /// @notice The migrator needs to be seeded with 1 wei of each base
    /// @notice The destination strategy can be any, as long as its current fyToken matches
    /// what the migrator is prepared to do.
    /// @param srcStrategy The strategy to migrate from.
    /// @param ignored Ignored
    /// @param dstStrategy_ The strategy to migrate to, casted onto an uint256
    /// @param exchange_ The exchange contract, casted onto an uint256
    function mint(IStrategy srcStrategy, address ignored, uint256 dstStrategy_, uint256 exchange_)
        external
        auth
        returns (uint256, uint256, uint256)
    {
        if (base == IERC20(address(0)) || fyToken == IFYToken(address(0))) revert NotPrepared();

        // Towards the exchange, mock as if we are the srcStrategy with regards to totalSupply
        totalSupply = srcStrategy.totalSupply();

        // Convert the dstStrategy and exchange parameters
        IStrategy dstStrategy = IStrategy(address(bytes20(bytes32(dstStrategy_))));
        IExchange exchange = IExchange(address(bytes20(bytes32(exchange_))));

        if (fyToken != dstStrategy.fyToken()) revert FYTokenMismatch(fyToken, dstStrategy.fyToken());

        // Use all base, except 1 wei
        uint256 baseUsed = base.balanceOf(address(this));
        if (baseUsed == 0) revert NoBaseReceived();

        // Register the src strategy in the strategy exchange
        base.safeTransfer(address(exchange), baseUsed);
        exchange.register(srcStrategy, dstStrategy);
        delete totalSupply;
        delete fyToken;
        delete base;

        emit Migrated(srcStrategy, dstStrategy, baseUsed);

        return (0, 0, 0);
    }

    /// @dev Mock strategy burn
    function burn(address, address, uint256, uint256) external returns(uint256, uint256, uint256) {
        return (0, 0, 0);
    }

    /// @dev Mock pool balanceOf
    function balanceOf(address) external view returns(uint256) {
        return 0;
    }

    /// @dev Mock pool maturity
    function maturity() external view returns(uint32) {
        return 0;
    }

    /// @dev Mock pool getBaseBalance
    function getBaseBalance() external view returns(uint128) {
        return 0;
    }

    /// @dev Mock pool getFYTokenBalance
    function getFYTokenBalance() external view returns(uint128) {
        return 0;
    }

    /// @dev Mock pool ts
    function ts() external view returns(int128) {
        return 0;
    }
}