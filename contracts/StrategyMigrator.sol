// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import "@yield-protocol/vault-v2/contracts/interfaces/IFYToken.sol";
import "@yield-protocol/utils-v2/contracts/token/IERC20.sol";
import "@yield-protocol/utils-v2/contracts/token/ERC20Permit.sol";


/// @dev The Migrator contract poses as a Pool to receive all assets from a Strategy
/// during a roll operation.
contract StrategyMigrator {

    /// Mock pool base - Must match that of the calling strategy
    IERC20 public base;

    /// Mock pool fyToken - Must be set to a real fyToken registered to a series in the Cauldron, any will do
    IFYToken public fyToken;

    constructor(IERC20 base_, IFYToken fyToken_) {
        base = base_;
        fyToken = fyToken_;
    }

    /// @dev Mock pool mint. Called within `startPool`. This contract must hold 1 wei of base.
    function mint(address, address, uint256, uint256)
        external
        virtual
        returns (uint256, uint256, uint256)
    {
        return (0, 0, 0);
    }

    /// @dev Mock pool burn and make it revert so that `endPool`never suceeds, and `burnForBase` can never be called.
    function burn(address, address, uint256, uint256)
        external
        returns  (uint256, uint256, uint256)
    {
        revert();
    }

    /// @dev Mock pool balanceOf
    function totalSupply(address) external view returns(uint256) {
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