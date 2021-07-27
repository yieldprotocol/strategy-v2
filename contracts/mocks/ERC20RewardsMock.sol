// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;
import "../ERC20Rewards.sol";


contract ERC20RewardsMock is ERC20Rewards  {

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) ERC20Rewards(name, symbol, decimals) { }

    /// @dev Give tokens to anyone.
    function mint(address to, uint256 amount) public virtual {
        _mint(to, amount);
    }

    /// @dev Burn tokens from anyone.
    function burn(address from, uint256 amount) public virtual {
        _burn(from, amount);
    }
}
