// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;
import "../ERC20Rewards.sol";


contract ERC20RewardsMock is ERC20Rewards  {

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) ERC20Rewards(name, symbol, decimals) { }

    /// @dev Give tokens to whoever asks for them.
    function mint(address to, uint256 amount) public virtual {
        _mint(to, amount);
    }
}
