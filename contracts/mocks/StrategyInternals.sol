// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;

import "../Strategy.sol";


/// @dev The Pool contract exchanges base for fyToken at a price defined by a specific formula.
contract StrategyInternals is Strategy {

    constructor(string memory name, string memory symbol, uint8 decimals, ILadle ladle_, IERC20 base_, bytes6 baseId_)
        Strategy(name, symbol, decimals, ladle_, base_, baseId_)
    { }

    /// @dev Invest available funds from the strategy into YieldSpace LP - Borrow and mint
    function borrowAndInvest(uint256 tokenInvested)
        public
        returns (uint256)
    {
        return _borrowAndInvest(tokenInvested);
    }

    /// @dev Divest from YieldSpace LP into available funds for the strategy - Burn and repay
    function divestAndRepay(uint256 lpBurnt)
        public
        returns (uint256, uint256)
    {
        return _divestAndRepay(lpBurnt);
    }

    /// @dev Check if the pool reserves have deviated more than the acceptable amount, and update the local pool cache.
    function poolDeviated()
        public
        returns (bool)
    {
        return _poolDeviated();
    }
}
