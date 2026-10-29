// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Price ratios from ticks: 1.0001^dTick (and its square root) as 18-decimal numbers.
library TickRatio {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BASE = 1_000_100_000_000_000_000; // 1.0001
    uint256 internal constant SQRT_BASE = 1_000_049_998_750_062_496; // sqrt(1.0001)
    /// @dev 1.0001^400000 is about 2.4e17, far past any move that still changes a payout.
    int256 internal constant MAX_DELTA = 400_000;
    int256 internal constant MAX_TICK = 887_272;

    /// @dev Saturates outside +/-MAX_DELTA instead of reverting, so closing a position can never fail on price math.
    function ratio(int256 dTick) internal pure returns (uint256) {
        if (dTick > MAX_DELTA) dTick = MAX_DELTA;
        else if (dTick < -MAX_DELTA) dTick = -MAX_DELTA;
        return _pow(BASE, dTick);
    }

    /// @notice sqrt(1.0001^tick): a Uniswap sqrt price, as an 18-decimal number instead of Q64.96.
    function sqrtRatio(int256 tick) internal pure returns (uint256) {
        if (tick > MAX_TICK) tick = MAX_TICK;
        else if (tick < -MAX_TICK) tick = -MAX_TICK;
        return _pow(SQRT_BASE, tick);
    }

    function _pow(uint256 base, int256 exp) private pure returns (uint256 r) {
        uint256 n = uint256(exp < 0 ? -exp : exp);
        uint256 b = base;
        r = ONE;
        while (n != 0) {
            if (n & 1 == 1) r = (r * b) / ONE;
            n >>= 1;
            if (n != 0) b = (b * b) / ONE;
        }
        if (exp < 0) r = (ONE * ONE) / r;
    }
}
