// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {TickRatio} from "../libraries/TickRatio.sol";

interface IUniswapV3PoolLike {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

/// @title UniV3Oracle
/// @notice Price feed from a coin/WETH Uniswap V3 pool, using the pool's own history. No keeper needed.
/// @dev Liquidity is the harmonic mean of in-range liquidity over `slowWindow`, valued at the slow price, and never
///      more than the WETH the pool really holds: a narrow range position adds virtual depth but little WETH, and
///      parked WETH adds a balance but no in-range depth, so faking depth needs both. Curator caps per coin
///      (maxLeverage, netCapEth) still bound what any reading unlocks.
///      `read` refuses to report until the pool keeps more observations than `slowWindow` has seconds. Uniswap
///      writes at most one observation per second, so the history can then never be run short on purpose to
///      force the feed into its stale fallback. Call `prepare` (in steps if needed) before listing.
contract UniV3Oracle is IPriceOracle {
    IUniswapV3PoolLike public immutable pool;
    IERC20 public immutable weth;
    bool public immutable coinIsToken0;
    uint32 public immutable fastWindow;
    uint32 public immutable slowWindow;

    error NotWethPool();
    error BadWindows();
    error HistoryTooShort();

    constructor(IUniswapV3PoolLike pool_, IERC20 weth_, uint32 fastWindow_, uint32 slowWindow_) {
        if (fastWindow_ == 0 || slowWindow_ <= fastWindow_) revert BadWindows();
        address t0 = pool_.token0();
        address t1 = pool_.token1();
        if (t0 != address(weth_) && t1 != address(weth_)) revert NotWethPool();
        pool = pool_;
        weth = weth_;
        coinIsToken0 = t1 == address(weth_);
        fastWindow = fastWindow_;
        slowWindow = slowWindow_;
    }

    /// @notice Ask the pool to store more observations. Anyone can pay for this.
    function prepare(uint16 cardinality) external {
        pool.increaseObservationCardinalityNext(cardinality);
    }

    function read() external view returns (int24 spotTick, int24 fastTick, int24 slowTick, uint256 liquidityEth) {
        (, int24 tick,, uint16 cardinality,,,) = pool.slot0();
        if (cardinality <= slowWindow) revert HistoryTooShort();
        uint32[] memory ago = new uint32[](3);
        ago[0] = slowWindow;
        ago[1] = fastWindow;
        ago[2] = 0;
        (int56[] memory cum, uint160[] memory spl) = pool.observe(ago);
        int24 slow = _mean(cum[2] - cum[0], slowWindow);
        int24 fast = _mean(cum[2] - cum[1], fastWindow);
        liquidityEth = _ethDepth(spl[0], spl[2], slow);
        uint256 held = weth.balanceOf(address(pool));
        if (held < liquidityEth) liquidityEth = held;
        // Pool ticks price token0 in token1. We want the coin priced in ETH.
        if (coinIsToken0) return (tick, fast, slow, liquidityEth);
        return (-tick, -fast, -slow, liquidityEth);
    }

    /// @dev ETH-side virtual reserves of the time-weighted in-range liquidity, at the slow pool tick.
    function _ethDepth(uint160 splStart, uint160 splEnd, int24 slowPoolTick) internal view returns (uint256) {
        uint160 delta;
        unchecked {
            delta = splEnd - splStart; // the accumulator is meant to wrap
        }
        if (delta == 0) return 0;
        uint256 liquidity = (uint256(slowWindow) << 128) / delta;
        uint256 sqrtPrice = TickRatio.sqrtRatio(slowPoolTick);
        // WETH is token1 when the coin is token0: amount1 = L * sqrtP. Otherwise amount0 = L / sqrtP.
        return coinIsToken0 ? (liquidity * sqrtPrice) / 1e18 : (liquidity * 1e18) / sqrtPrice;
    }

    function _mean(int56 delta, uint32 window) internal pure returns (int24) {
        int56 w = int56(uint56(window));
        int56 m = delta / w;
        if (delta < 0 && delta % w != 0) m--;
        return int24(m);
    }
}
