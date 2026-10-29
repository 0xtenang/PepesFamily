// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Config, Side, Position} from "../LevTypes.sol";
import {TickRatio} from "./TickRatio.sol";

/// @notice Trading math shared by LevExchange (which acts on it) and LevLens (which previews it), so the two
///         can never disagree.
library LevLogic {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant HOUR = 3600;
    /// @dev A long's max win is at most its leverage times this (200% per 1x), so a low-leverage long can't
    ///      reserve far more of the pool than its price move could ever earn.
    uint256 internal constant LONG_WIN_PER_LEVERAGE_BPS = 20_000;

    /// @dev Trader P&L in wei at `tick`, capped at the position's max win.
    function pnl(Position memory p, int24 tick) internal pure returns (int256 v) {
        int256 move = int256(TickRatio.ratio(int256(tick) - int256(p.entryTick))) - int256(ONE);
        if (!p.isLong) move = -move;
        v = (int256(uint256(p.stake)) * move * int256(uint256(p.leverage))) / int256(ONE);
        int256 cap = int256((uint256(p.stake) * p.maxWinBps) / BPS);
        if (v > cap) v = cap;
    }

    /// @dev Holding fee owed, with the first `freeHoldSeconds` free (charged pro rata).
    function holdFee(Position memory p, uint256 indexNow, Config memory c, uint256 nowTs) internal pure returns (uint256) {
        uint256 age = nowTs - p.openedAt;
        if (age <= c.freeHoldSeconds) return 0;
        uint256 full = (uint256(p.stake) * p.leverage * (indexNow - p.feeIndex)) / ONE;
        return (full * (age - c.freeHoldSeconds)) / age;
    }

    /// @dev How much each side's fee index grows over `dt` seconds. The side with more open size pays the
    ///      crowd multiplier.
    function feeGrowth(Config memory c, uint256 dt, uint256 longSize, uint256 shortSize)
        internal
        pure
        returns (uint256 longGrowth, uint256 shortGrowth)
    {
        uint256 base = (uint256(c.holdRateBpsPerHour) * ONE * dt) / (BPS * HOUR);
        uint256 crowded = (base * c.crowdMultBps) / BPS;
        longGrowth = longSize > shortSize ? crowded : base;
        shortGrowth = shortSize > longSize ? crowded : base;
    }

    function allowedLeverage(Config memory c, uint8 marketMax, uint256 liq, bool isLong) internal pure returns (uint8 lev) {
        lev = liq >= c.lev10LiquidityEth ? 10 : liq >= c.lev5LiquidityEth ? 5 : 2;
        if (lev > marketMax) lev = marketMax;
        if (!isLong && lev > c.maxShortLeverage) lev = c.maxShortLeverage;
    }

    function maxWinBps(Config memory c, uint256 cash, bool isLong, uint8 leverage) internal pure returns (uint32 bps) {
        bps = cash >= c.maxWinTier3Cash ? c.longMaxWinBps3 : cash >= c.maxWinTier2Cash ? c.longMaxWinBps2 : c.longMaxWinBps;
        if (isLong) {
            uint256 byLeverage = uint256(leverage) * LONG_WIN_PER_LEVERAGE_BPS;
            if (bps > byLeverage) bps = uint32(byLeverage);
        } else {
            if (bps > c.shortMaxWinBps) bps = c.shortMaxWinBps;
            // A short can't win more than its leverage times 100% (the price can only fall to zero).
            uint256 natural = uint256(leverage) * BPS;
            if (bps > natural) bps = uint32(natural);
        }
    }

    /// @dev Most extra size this side can add. The coin's net position stays within `cap`, and each side's gross
    ///      size within 2 * `cap`, so pairing a high-leverage long with an offsetting short can't get around the
    ///      cap. When the other side is over the net cap, the room includes the size needed to rebalance it.
    function netRoom(Config memory c, uint256 netCapEth, uint256 longSize, uint256 shortSize, bool isLong, uint256 liq)
        internal
        pure
        returns (uint256)
    {
        uint256 liqCap = (liq * c.netCapLiquidityBps) / BPS;
        uint256 cap = netCapEth < liqCap ? netCapEth : liqCap;
        int256 net = int256(longSize) - int256(shortSize);
        if (!isLong) net = -net;
        uint256 netRoom_ = int256(cap) > net ? uint256(int256(cap) - net) : 0;
        uint256 side = isLong ? longSize : shortSize;
        uint256 grossRoom = 2 * cap > side ? 2 * cap - side : 0;
        return netRoom_ < grossRoom ? netRoom_ : grossRoom;
    }

    function tradeFee(Config memory c, uint256 base, uint256 size) internal pure returns (uint256) {
        uint256 a = base * c.openFeeStakeBps;
        uint256 b = size * c.openFeeSizeBps;
        return (a > b ? a : b) / BPS;
    }

    function breakerTripped(Config memory c, uint256 hourStart, int256 hourPoolPnl, uint256 hourStartCash, uint256 nowTs)
        internal
        pure
        returns (bool)
    {
        if (c.hourlyLossBreakerBps == 0 || nowTs >= hourStart + HOUR || hourPoolPnl >= 0) return false;
        return uint256(-hourPoolPnl) * BPS >= hourStartCash * c.hourlyLossBreakerBps;
    }

    /// @dev What one side's open positions are worth to traders at `tick`, clamped between "all stakes lost"
    ///      and "all max wins paid".
    function sideLiability(Side memory s, bool isLong, int24 refTick, int24 tick) internal pure returns (int256) {
        if (s.size == 0) return 0;
        uint256 value = (s.expo * TickRatio.ratio(int256(tick) - int256(refTick))) / ONE;
        int256 v = isLong ? int256(value) - int256(s.size) : int256(s.size) - int256(value);
        if (v > int256(s.maxWin)) return int256(s.maxWin);
        if (v < -int256(s.stake)) return -int256(s.stake);
        return v;
    }

    /// @dev True when `tick` is a rug's depth (rugDropBps) under `slow`.
    function isRug(Config memory c, int24 tick, int24 slow) internal pure returns (bool) {
        return TickRatio.ratio(int256(tick) - int256(slow)) * BPS <= ONE * (BPS - c.rugDropBps);
    }

    function expoOf(int24 refTick, int24 entry, uint256 size) internal pure returns (uint256) {
        return (size * TickRatio.ratio(int256(refTick) - int256(entry))) / ONE;
    }
}
