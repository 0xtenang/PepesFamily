// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Uniswap V3 pool stand-in with a settable price and liquidity, and real cumulative history for both.
contract MockV3Pool {
    struct Obs {
        uint64 time;
        int24 tick;
        uint128 liquidity;
        int56 tickCum; // tick cumulative at `time`
        uint160 splCum; // seconds-per-liquidity cumulative (X128) at `time`
    }

    address public immutable token0;
    address public immutable token1;
    uint16 public cardinalityNext;
    uint16 public cardinality = 1; // grows as soon as more is asked for
    Obs[] internal _obs;

    /// @param historyStart Backdate the first observation so TWAP windows work right away.
    constructor(address token0_, address token1_, int24 tick, uint128 liquidity, uint64 historyStart) {
        token0 = token0_;
        token1 = token1_;
        _obs.push(Obs({time: historyStart, tick: tick, liquidity: liquidity, tickCum: 0, splCum: 0}));
    }

    function setTick(int24 tick) external {
        _push(tick, _obs[_obs.length - 1].liquidity);
    }

    function setLiquidity(uint128 liquidity) external {
        _push(_obs[_obs.length - 1].tick, liquidity);
    }

    function liquidity() external view returns (uint128) {
        return _obs[_obs.length - 1].liquidity;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, _obs[_obs.length - 1].tick, 0, cardinality, cardinalityNext, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCums, uint160[] memory splCums)
    {
        tickCums = new int56[](secondsAgos.length);
        splCums = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            (tickCums[i], splCums[i]) = _cumAt(block.timestamp - secondsAgos[i]);
        }
    }

    function increaseObservationCardinalityNext(uint16 n) external {
        cardinalityNext = n;
        if (n > cardinality) cardinality = n;
    }

    function observationCount() external view returns (uint256) {
        return _obs.length;
    }

    function _push(int24 tick, uint128 liq) internal {
        Obs storage last = _obs[_obs.length - 1];
        if (last.time == block.timestamp) {
            last.tick = tick;
            last.liquidity = liq;
            return;
        }
        (int56 tc, uint160 sc) = _advance(last, block.timestamp);
        _obs.push(Obs({time: uint64(block.timestamp), tick: tick, liquidity: liq, tickCum: tc, splCum: sc}));
    }

    function _cumAt(uint256 t) internal view returns (int56, uint160) {
        require(t >= _obs[0].time, "OLD");
        uint256 lo = 0;
        uint256 hi = _obs.length - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_obs[mid].time <= t) lo = mid;
            else hi = mid - 1;
        }
        return _advance(_obs[lo], t);
    }

    function _advance(Obs memory o, uint256 t) internal pure returns (int56 tc, uint160 sc) {
        uint256 dt = t - o.time;
        tc = o.tickCum + int56(o.tick) * int56(uint56(dt));
        unchecked {
            sc = o.splCum + uint160((dt << 128) / (o.liquidity > 0 ? o.liquidity : 1));
        }
    }
}
