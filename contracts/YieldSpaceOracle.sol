// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.1;

// import "@yield-protocol/vault-interfaces/IOracle.sol";
import "./IOracleTmp.sol";

interface IPool {
    function getCache() external view returns (uint112, uint112, uint32);
}

library CastU256U112 {
    /// @dev Safely cast an uint256 to an uint112
    function u112(uint256 x) internal pure returns (uint112 y) {
        require (x <= type(uint112).max, "Cast overflow");
        y = uint112(x);
    }
}

/**
 * @title YieldSpaceOracle
 */
contract YieldSpaceOracle is IOracleTmp {
    using CastU256U112 for uint256;

    event Updated(uint112 twar, uint32 indexed twarTimestamp, uint112 ratioCumulative);

    uint8 public constant override decimals = 18;   // Ratio is presented with 18 decimals
    address public immutable override source;
    uint public constant PERIOD = 1 hours;

    uint112 public twar;
    uint32  public twarTimestamp;
    uint112 public ratioCumulative;

    constructor(IPool pool_) {
        source = address(pool_);
    }

    function update() external {
        (,, uint32 poolTimestamp) = IPool(source).getCache();
        require(twarTimestamp != poolTimestamp, "Up to date");
        _update();
    }

    /// @dev Update the cumulative ratioSeconds if PERIOD has passed.
    function _update() internal {
        (uint256 baseReserves, uint256 fyTokenReserves, uint32 poolTimestamp) = IPool(source).getCache();
        require(baseReserves > 0 && fyTokenReserves > 0, "No liquidity in the pool");

        (uint32 twarTimestamp_, uint112 ratioCumulative_) = (twarTimestamp, ratioCumulative);
        uint32 timeElapsed = poolTimestamp - twarTimestamp_;

        // ensure that at least one full period has passed since the last update on the pool
        if(timeElapsed >= PERIOD) {
            uint112 poolRatioCumulative = ((1e18 * baseReserves * poolTimestamp) / fyTokenReserves).u112();
            // cumulative ratio is in (ratio * seconds) units so for the average we simply wrap it after division by time elapsed
            uint112 twar_ = uint112((poolRatioCumulative - ratioCumulative_) / timeElapsed); // casting won't overflow
            (twar, twarTimestamp, ratioCumulative) = (twar_, poolTimestamp, poolRatioCumulative);
            emit Updated(twar_, poolTimestamp, poolRatioCumulative);
        }
    }

    /// @dev Return the cumulative ratioSeconds
    function peek(bytes32, bytes32, uint256)
        external view virtual override
        returns (uint256 twar_, uint256 twarTimestamp_)
    {
        (twar_, twarTimestamp_) = (twar, twarTimestamp);
        require(twarTimestamp_ != 0, "Not initialized");
    }

    /// @dev Update and return the time-weighted average ratio and the time of the last update
    function get(bytes32, bytes32, uint256)
        external virtual override
        returns (uint256 twar_, uint256 twarTimestamp_)
    {
        _update();
        (twar_, twarTimestamp_) = (twar, twarTimestamp);
    }
}
