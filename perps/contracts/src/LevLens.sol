// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LevExchange} from "./LevExchange.sol";
import {LevExchangeAdmin} from "./LevExchangeAdmin.sol";
import {ILevPool} from "./interfaces/ILevPool.sol";
import {LevLogic} from "./libraries/LevLogic.sol";
import {Config, Side, Market, Position} from "./LevTypes.sol";

/// @title LevLens
/// @notice Read-only previews for apps and keepers (what `open` would do, where each position stands) and the
///         pool's valuation of open positions. It uses the same LevLogic math as LevExchange, so a preview matches
///         what the exchange will do.
contract LevLens {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant HOUR = 3600;

    uint8 public constant QUOTE_OK = 0;
    uint8 public constant QUOTE_CLOSED = 1;
    uint8 public constant QUOTE_LOCKED = 2;
    uint8 public constant QUOTE_ORACLE_DOWN = 3;
    uint8 public constant QUOTE_LOW_LIQUIDITY = 4;
    uint8 public constant QUOTE_LEVERAGE = 5;
    uint8 public constant QUOTE_COIN_FULL = 6;
    uint8 public constant QUOTE_POOL_FULL = 7;
    uint8 public constant QUOTE_STAKE = 8;
    uint8 public constant QUOTE_BREAKER = 9;
    uint8 public constant QUOTE_WOULD_LIQUIDATE = 10;

    uint8 public constant ACTION_NONE = 0;
    uint8 public constant ACTION_LIQUIDATE = 1;
    uint8 public constant ACTION_MAX_WIN = 2;
    uint8 public constant ACTION_RUG_SETTLE = 3;

    struct MarketView {
        address oracle;
        bool active;
        uint8 maxLeverage;
        uint256 netCapEth;
        int24 refTick;
        int24 lastGoodTick;
        uint64 lastGoodAt;
        uint64 downSince;
        uint32 rugEpoch;
        uint64 rugAt;
        uint256 longSize;
        uint256 shortSize;
        uint256 longStake;
        uint256 shortStake;
        uint256 longMaxWin;
        uint256 shortMaxWin;
    }

    struct Quote {
        uint8 reason; // QUOTE_*
        int24 spotTick;
        int24 fastTick;
        int24 slowTick;
        int24 entryTick;
        uint256 liquidityEth;
        uint8 maxLeverage;
        uint256 fee;
        uint32 maxWinBps;
        uint256 netRoom; // more size this side can take on the coin
        uint256 poolRoomStake; // largest stake the pool can still cover at this max win
    }

    struct PositionView {
        Position position;
        uint256 size;
        int24 markTick; // fast price, used for liquidation and max win
        int256 pnl; // capped at max win
        uint256 holdFee;
        int256 equity;
        uint8 action; // ACTION_*
    }

    /// @dev Called through LevExchange's address: LevExchange forwards these reads to LevExchangeAdmin's code.
    LevExchangeAdmin public immutable exchange;
    ILevPool public immutable pool;

    constructor(LevExchange exchange_) {
        exchange = LevExchangeAdmin(payable(address(exchange_)));
        pool = exchange_.pool();
    }

    // ------------------------------------------------------------ pool value

    /// @notice What open positions are worth to traders, for pricing LP shares.
    /// @return owedLow  The lowest plausible value: at whichever of spot, fast and slow price is best for the
    ///                  pool, minus holding fees and pool fee shares already owed. Deposits buy in at
    ///                  cash - owedLow, the highest pool value.
    /// @return owedHigh The highest plausible value, at whichever price is worst for the pool, with no credit for
    ///                  fees owed. Withdrawals pay out at cash - owedHigh.
    /// @return blocked  True while the valuation can't be trusted: a feed is down, a rug is unfolding or a rug
    ///                  hasn't been fully settled. LP deposits and withdrawals wait until it clears.
    function liabilityRange() external view returns (int256 owedLow, int256 owedHigh, bool blocked) {
        Config memory c = exchange.getConfig();
        uint256 n = exchange.marketCount();
        for (uint256 i; i < n; ++i) {
            Market memory m = exchange.marketData(i);
            if (m.longs.size == 0 && m.shorts.size == 0) continue;
            (bool ok, int24 spot, int24 fast, int24 slow,) = _tryRead(m);
            if (!ok || m.ruggedPending != 0 || LevLogic.isRug(c, spot, slow) || LevLogic.isRug(c, fast, slow)) {
                blocked = true;
            }
            if (!ok) {
                spot = m.lastGoodFast;
                fast = m.lastGoodFast;
                slow = m.lastGoodTick;
            }
            int256 a = _marketLiability(m, spot);
            int256 b = _marketLiability(m, fast);
            int256 d = _marketLiability(m, slow);
            int256 lo = a < b ? a : b;
            if (d < lo) lo = d;
            int256 hi = a > b ? a : b;
            if (d > hi) hi = d;
            owedLow += lo - int256(_feesOwedLowerBound(c, m, m.longs, m.shorts) + _feesOwedLowerBound(c, m, m.shorts, m.longs));
            owedHigh += hi;
        }
    }

    function _marketLiability(Market memory m, int24 tick) internal pure returns (int256) {
        return LevLogic.sideLiability(m.longs, true, m.refTick, tick) + LevLogic.sideLiability(m.shorts, false, m.refTick, tick);
    }

    /// @dev Holding fees one side already owes the pool, less the most the free first hour could waive, plus the
    ///      pool's share of the smallest close fee each position will pay. A floor, so deposits never pay for fees
    ///      that might not arrive.
    function _feesOwedLowerBound(Config memory c, Market memory m, Side memory s, Side memory other)
        internal
        view
        returns (uint256)
    {
        if (s.size == 0) return 0;
        // feeGrowth's first side is this one, so its first result is this side's pending growth.
        (uint256 grown,) = LevLogic.feeGrowth(c, block.timestamp - m.lastFeeUpdate, s.size, other.size);
        uint256 indexNow = s.feeIndex + grown;
        uint256 accrued = (s.size * indexNow) / ONE;
        accrued = accrued > s.sizeIndexSum ? accrued - s.sizeIndexSum : 0;
        uint256 freeWaiver = (s.size * c.holdRateBpsPerHour * c.crowdMultBps * c.freeHoldSeconds) / (BPS * BPS * HOUR);
        uint256 hold = accrued > freeWaiver ? accrued - freeWaiver : 0;
        uint256 closeFeeShare = (s.size * c.openFeeSizeBps * c.poolFeeShareBps) / (BPS * BPS);
        return hold + closeFeeShare;
    }

    // ---------------------------------------------------------------- markets

    function getMarket(uint256 id) public view returns (MarketView memory v) {
        Market memory m = exchange.marketData(id);
        v = MarketView({
            oracle: address(m.oracle),
            active: m.active,
            maxLeverage: m.maxLeverage,
            netCapEth: m.netCapEth,
            refTick: m.refTick,
            lastGoodTick: m.lastGoodTick,
            lastGoodAt: m.lastGoodAt,
            downSince: m.downSince,
            rugEpoch: m.rugEpoch,
            rugAt: m.rugAt,
            longSize: m.longs.size,
            shortSize: m.shorts.size,
            longStake: m.longs.stake,
            shortStake: m.shorts.stake,
            longMaxWin: m.longs.maxWin,
            shortMaxWin: m.shorts.maxWin
        });
    }

    /// @notice Everything `open` would check, without reverting. `leverage` 0 means the highest allowed.
    function quoteOpen(uint256 marketId, bool isLong, uint8 leverage, uint256 stake) public view returns (Quote memory q) {
        Config memory c = exchange.getConfig();
        Market memory m = exchange.marketData(marketId);
        uint256 cash = pool.cash();
        bool ok;
        (ok, q.spotTick, q.fastTick, q.slowTick, q.liquidityEth) = _tryRead(m);
        if (!ok) {
            q.reason = QUOTE_ORACLE_DOWN;
            return q;
        }
        q.entryTick = isLong ? _max24(q.spotTick, q.fastTick) : _min24(q.spotTick, q.fastTick);
        q.maxLeverage = LevLogic.allowedLeverage(c, m.maxLeverage, q.liquidityEth, isLong);
        uint8 lev = leverage == 0 ? q.maxLeverage : leverage;
        q.maxWinBps = LevLogic.maxWinBps(c, cash, isLong, lev);
        q.netRoom = LevLogic.netRoom(c, m.netCapEth, m.longs.size, m.shorts.size, isLong, q.liquidityEth);
        uint256 coverRoom = (cash * c.coverageBps) / BPS;
        uint256 reserved = exchange.totalMaxWin();
        coverRoom = coverRoom > reserved ? coverRoom - reserved : 0;
        q.poolRoomStake = q.maxWinBps == 0 ? 0 : (coverRoom * BPS) / q.maxWinBps;
        uint256 size = stake * lev;
        q.fee = LevLogic.tradeFee(c, stake, size);

        if (exchange.opensPaused() || !m.active) q.reason = QUOTE_CLOSED;
        else if (m.rugAt != 0 && block.timestamp < uint256(m.rugAt) + c.rugLockSeconds) q.reason = QUOTE_LOCKED;
        else if (_breaker(c)) q.reason = QUOTE_BREAKER;
        else if (stake < c.minStake) q.reason = QUOTE_STAKE;
        else if (q.liquidityEth < c.minLiquidityEth) q.reason = QUOTE_LOW_LIQUIDITY;
        else if (lev > q.maxLeverage) q.reason = QUOTE_LEVERAGE;
        else if (q.netRoom < size) q.reason = QUOTE_COIN_FULL;
        else if (stake > q.poolRoomStake) q.reason = QUOTE_POOL_FULL;
        else if (_wouldLiquidate(c, q, isLong, lev, stake)) q.reason = QUOTE_WOULD_LIQUIDATE;
    }

    function _wouldLiquidate(Config memory c, Quote memory q, bool isLong, uint8 lev, uint256 stake)
        internal
        pure
        returns (bool)
    {
        if (stake == 0) return false;
        Position memory p;
        p.isLong = isLong;
        p.leverage = lev;
        p.entryTick = q.entryTick;
        p.maxWinBps = q.maxWinBps;
        p.stake = uint96(stake);
        return int256(stake) + LevLogic.pnl(p, q.fastTick) <= int256((stake * c.liqEquityBps) / BPS);
    }

    // -------------------------------------------------------------- positions

    function getPosition(uint256 id) public view returns (PositionView memory v) {
        Position memory p = exchange.positionData(id);
        if (p.owner == address(0)) return v;
        Config memory c = exchange.getConfig();
        Market memory m = exchange.marketData(p.marketId);
        v.position = p;
        v.size = uint256(p.stake) * p.leverage;
        (uint256 gl, uint256 gs) = LevLogic.feeGrowth(c, block.timestamp - m.lastFeeUpdate, m.longs.size, m.shorts.size);
        uint256 indexNow = p.isLong ? m.longs.feeIndex + gl : m.shorts.feeIndex + gs;
        v.holdFee = LevLogic.holdFee(p, indexNow, c, block.timestamp);
        int256 stake = int256(uint256(p.stake));
        if (!p.isLong && p.rugEpoch < m.rugEpoch) {
            v.markTick = exchange.rugTickOf(p.marketId, p.rugEpoch + 1);
            v.pnl = LevLogic.pnl(p, v.markTick);
            int256 cap = int256((uint256(p.stake) * c.rugCapBps) / BPS);
            if (v.pnl > cap) v.pnl = cap;
            v.action = ACTION_RUG_SETTLE;
        } else {
            (bool ok, int24 spot, int24 fast, int24 slow,) = _tryRead(m);
            v.markTick = ok ? fast : m.lastGoodFast;
            v.pnl = LevLogic.pnl(p, v.markTick);
            int256 maxWin = int256((uint256(p.stake) * p.maxWinBps) / BPS);
            int256 eqNow = stake + v.pnl - int256(v.holdFee);
            // Report only what the exchange would accept now: a down feed counts once it is stale, and a short
            // can't be closed while a rug the guard hasn't caught yet is under way.
            bool actable = ok ? (p.isLong || !LevLogic.isRug(c, spot, slow)) : _stale(c, m);
            if (actable) {
                if (v.pnl >= maxWin) v.action = ACTION_MAX_WIN;
                else if (eqNow <= int256((uint256(p.stake) * c.liqEquityBps) / BPS)) v.action = ACTION_LIQUIDATE;
            }
        }
        v.equity = stake + v.pnl - int256(v.holdFee);
    }

    function positionsOf(address owner) external view returns (PositionView[] memory views) {
        uint256[] memory ids = exchange.positionIdsOf(owner);
        views = new PositionView[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            views[i] = getPosition(ids[i]);
        }
    }

    /// @notice Keeper helper: open positions in [offset, offset+limit) that need a liquidation, max-win close or
    ///         rug settlement, with the action each needs.
    function actionable(uint256 offset, uint256 limit) external view returns (uint256[] memory ids, uint8[] memory actions) {
        uint256[] memory page = exchange.openPositionIds(offset, limit);
        uint256 n;
        uint8[] memory all = new uint8[](page.length);
        for (uint256 i; i < page.length; ++i) {
            all[i] = getPosition(page[i]).action;
            if (all[i] != ACTION_NONE) n++;
        }
        ids = new uint256[](n);
        actions = new uint8[](n);
        uint256 k;
        for (uint256 i; i < page.length; ++i) {
            if (all[i] == ACTION_NONE) continue;
            ids[k] = page[i];
            actions[k++] = all[i];
        }
    }

    /// @notice Sum of all open stakes. The exchange holds exactly sum(balances) + this + treasuryBalance.
    function totalOpenStake() external view returns (uint256 total) {
        uint256 n = exchange.marketCount();
        for (uint256 i; i < n; ++i) {
            Market memory m = exchange.marketData(i);
            total += m.longs.stake + m.shorts.stake;
        }
    }

    // --------------------------------------------------------------- internal

    /// @dev Mirrors LevExchange._requireStale.
    function _stale(Config memory c, Market memory m) internal view returns (bool) {
        return m.downSince != 0 && block.timestamp >= uint256(m.downSince) + c.staleSeconds
            && block.timestamp <= uint256(m.lastFailAt) + exchange.STALE_PING_GAP() && m.lastGoodAt <= m.downSince;
    }

    function _breaker(Config memory c) internal view returns (bool) {
        return block.timestamp < exchange.breakerUntil()
            || LevLogic.breakerTripped(c, exchange.hourStart(), exchange.hourPoolPnl(), exchange.hourStartCash(), block.timestamp);
    }

    function _tryRead(Market memory m) internal view returns (bool ok, int24 spot, int24 fast, int24 slow, uint256 liq) {
        try m.oracle.read() returns (int24 s, int24 f, int24 sl, uint256 l) {
            return (true, s, f, sl, l);
        } catch {
            return (false, 0, 0, 0, 0);
        }
    }

    function _max24(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a : b;
    }

    function _min24(int24 a, int24 b) internal pure returns (int24) {
        return a < b ? a : b;
    }
}
