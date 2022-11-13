// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.14;

import {IPool} from "yieldspace-tv/interfaces/IPool.sol";
import {YieldMath, Math64x64, Exp64x64} from "yieldspace-tv/YieldMath.sol";


library YieldMathExtensions {

    using Math64x64 for int128;
    using Math64x64 for uint128;
    using Math64x64 for int256;
    using Math64x64 for uint256;
    using Exp64x64 for uint128;

    uint128 public constant ONE = 0x10000000000000000; // In 64.64
    uint256 public constant MAX = type(uint128).max;   // Used for overflow checks

    /// @dev Calculate the invariant for this pool
    function invariant(IPool pool) external view returns (uint128) {
        uint32 maturity = pool.maturity();
        uint32 timeToMaturity = (maturity > uint32(block.timestamp)) ? maturity - uint32(block.timestamp) : 0;
        return _invariant(
            pool.getBaseBalance(),
            pool.getFYTokenBalance(),
            pool.totalSupply(),
            timeToMaturity,
            pool.ts()
        );
    }

    function _invariant(uint128 baseReserves, uint128 fyTokenReserves, uint256 totalSupply, uint128 timeTillMaturity, int128 ts)
        internal pure returns(uint128)
    {
        if (totalSupply == 0) return 0;

        unchecked {
        // a = (1 - ts * timeTillMaturity)
        int128 a = int128(ONE).sub(ts.mul(timeTillMaturity.fromUInt()));
        require (a > 0, "YieldMath: Too far from maturity");

        uint256 sum =
        uint256(baseReserves.pow(uint128 (a), ONE)) +
        uint256(fyTokenReserves.pow(uint128 (a), ONE)) >> 1;
        require(sum < MAX, "YieldMath: Sum overflow");

        // We multiply the dividend by 1e18 to get a fixed point number with 18 decimals
        uint256 result = uint256(uint128(sum).pow(ONE, uint128(a))) * 1e18 / totalSupply;
        require (result < MAX, "YieldMath: Result overflow");

        return uint128(result);
        }
    }
}
