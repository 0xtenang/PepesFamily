// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LevExchange} from "./LevExchange.sol";
import {LevExchangeAdmin} from "./LevExchangeAdmin.sol";
import {ILevPool} from "./interfaces/ILevPool.sol";
import {LevLogic} from "./libraries/LevLogic.sol";
import {Config, Side, Market, Position, RiskConfig, Trigger, Order} from "./LevTypes.sol";

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
    uint8 public constant QUOTE_PRICE_BAND = 11; // live, fast and slow prices disagree: the coin is being pushed
    uint8 public constant QUOTE_GROWING_TOO_FAST = 12; // the coin took its hourly share of new size already

    uint8 public constant ACTION_NONE = 0;
    uint8 public constant ACTION_LIQUIDATE = 1;
    uint8 public constant ACTION_MAX_WIN = 2;
    uint8 public constant ACTION_RUG_SETTLE = 3;
    uint8 public constant ACTION_TAKE_PROFIT = 4;
    uint8 public constant ACTION_STOP_LOSS = 5;

    uint8 public constant ORDER_FILL = 1;
    uint8 public constant ORDER_EXPIRED = 2;

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

    /// @notice What open positions are worth to traders, for pricing LP shares. Each position counts between losing
    ///         its stake and winning its own max win (IMD audit M-1: a bankrupt loser's extra loss never offsets
    ///         another trader's win, and a winner never counts past its own cap).
    /// @return owedLow  The lowest plausible value: at whichever of spot, fast and slow price is best for the
    ///                  pool, less each position's holding fee and the pool's smallest share of its close fee, but
    ///                  never more than the position can still pay (its stake plus margin; a bankrupt position pays
    ///                  no fees: IMD audit 964f33f1, L-4). Deposits buy in at cash - owedLow, the highest pool value.
    /// @return owedHigh The highest plausible value, at whichever of spot, fast and slow price is worst for the
    ///                  pool, with no credit for margin or fees owed. Withdrawals pay out at cash - owedHigh; the
    ///                  live price counts so an LP can't leave at the old price during a real move, and
    ///                  `LevPool.withdraw(minAssets)` lets the LP refuse a payout a pushed live price lowered.
    /// @return blocked  True while the valuation can't be trusted: a feed is down and not yet stale, a rug is
    ///                  unfolding or a rug hasn't been fully settled. LP deposits and withdrawals wait until it
    ///                  clears. A feed that has gone stale counts at its last good prices, as the exchange settles
    ///                  it (IMD audit M-2), so one dead coin can't freeze the pool.
    function liabilityRange() external view returns (int256 owedLow, int256 owedHigh, bool blocked) {
        Config memory c = exchange.getConfig();
        uint256 n = exchange.marketCount();
        int24[3][] memory ticks = new int24[3][](n);
        uint256[2][] memory index = new uint256[2][](n); // holding-fee index now: longs, shorts
        for (uint256 i; i < n; ++i) {
            Market memory m = exchange.marketData(i);
            if (m.longs.size == 0 && m.shorts.size == 0) continue;
            (bool ok, int24 spot, int24 fast, int24 slow,) = _tryRead(m);
            if (ok) {
                if (m.ruggedPending != 0 || LevLogic.isRug(c, spot, slow) || LevLogic.isRug(c, fast, slow)) blocked = true;
            } else {
                if (m.ruggedPending != 0 || !_stale(c, m)) blocked = true;
                spot = m.lastGoodFast;
                fast = m.lastGoodFast;
                slow = m.lastGoodTick;
            }
            ticks[i] = [spot, fast, slow];
            (uint256 gl, uint256 gs) = LevLogic.feeGrowth(c, block.timestamp - m.lastFeeUpdate, m.longs.size, m.shorts.size);
            index[i] = [m.longs.feeIndex + gl, m.shorts.feeIndex + gs];
        }
        (Position[] memory ps, uint256[] memory margins) = exchange.openPositionsData(0, exchange.openPositionCount());
        int256[3][] memory lo = new int256[3][](n);
        int256[3][] memory hi = new int256[3][](n);
        for (uint256 j; j < ps.length; ++j) {
            Position memory p = ps[j];
            uint256 mi = p.marketId;
            int256 stake = int256(uint256(p.stake));
            int256 held = stake + int256(margins[j]);
            int256 hold = int256(LevLogic.holdFee(p, index[mi][p.isLong ? 0 : 1], c, block.timestamp));
            for (uint256 k; k < 3; ++k) {
                int256 v = LevLogic.pnl(p, ticks[mi][k]); // capped at the position's max win
                hi[mi][k] += v < -stake ? -stake : v;
                lo[mi][k] += _owedLow(c, p, v, hold, held);
            }
        }
        for (uint256 i; i < n; ++i) {
            owedLow += _min3(lo[i][0], lo[i][1], lo[i][2]);
            owedHigh += _max3(hi[i][0], hi[i][1], hi[i][2]);
        }
    }

    /// @dev The least a position can take from the pool when it closes at pnl `v`: what is left to it after the
    ///      holding fee and the pool's share of the smallest close fee (after a keeper's cut), never below losing
    ///      everything it holds. A position with nothing left pays no fees at all.
    function _owedLow(Config memory c, Position memory p, int256 v, int256 hold, int256 held) internal pure returns (int256) {
        int256 left = held + v - hold;
        if (left <= 0) return -held;
        uint256 fee = (uint256(p.stake) * p.leverage * c.openFeeSizeBps) / BPS;
        if (fee > uint256(left)) fee = uint256(left);
        int256 credit = int256((fee * (BPS - c.keeperRewardBps) * c.poolFeeShareBps) / (BPS * BPS));
        return v - hold - credit;
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

    /// @notice Everything `open` would check, without reverting. `leverage` 0 means the highest allowed. The
    ///         entry includes the spread; `maxLeverage` includes the size tiers for this stake.
    function quoteOpen(uint256 marketId, bool isLong, uint8 leverage, uint256 stake) public view returns (Quote memory q) {
        Config memory c = exchange.getConfig();
        RiskConfig memory r = exchange.getRiskConfig();
        Market memory m = exchange.marketData(marketId);
        uint256 cash = pool.cash();
        bool ok;
        (ok, q.spotTick, q.fastTick, q.slowTick, q.liquidityEth) = _tryRead(m);
        if (!ok) {
            q.reason = QUOTE_ORACLE_DOWN;
            return q;
        }
        q.maxLeverage = _maxLeverage(c, r, m.maxLeverage, q.liquidityEth, isLong, stake);
        uint8 lev = leverage == 0 ? q.maxLeverage : leverage;
        uint256 size = stake * lev;
        int24 fill = isLong ? _max24(q.spotTick, q.fastTick) : _min24(q.spotTick, q.fastTick);
        q.entryTick = LevLogic.worsen(fill, LevLogic.spreadTicks(r, size, q.liquidityEth), isLong);
        q.maxWinBps = LevLogic.maxWinBps(c, cash, isLong, lev);
        q.netRoom = LevLogic.netRoom(c, m.netCapEth, m.longs.size, m.shorts.size, isLong, q.liquidityEth);
        uint256 coverRoom = (cash * c.coverageBps) / BPS;
        uint256 reserved = exchange.totalMaxWin();
        coverRoom = coverRoom > reserved ? coverRoom - reserved : 0;
        q.poolRoomStake = q.maxWinBps == 0 ? 0 : (coverRoom * BPS) / q.maxWinBps;
        q.fee = LevLogic.tradeFee(c, stake, size);
        q.reason = _quoteReason(c, r, m, q, isLong, lev, stake, cash);
    }

    function _quoteReason(
        Config memory c,
        RiskConfig memory r,
        Market memory m,
        Quote memory q,
        bool isLong,
        uint8 lev,
        uint256 stake,
        uint256 cash
    ) internal view returns (uint8) {
        uint256 size = stake * lev;
        if (exchange.opensPaused() || !m.active) return QUOTE_CLOSED;
        if (m.rugAt != 0 && block.timestamp < uint256(m.rugAt) + c.rugLockSeconds) return QUOTE_LOCKED;
        if (_breaker(c)) return QUOTE_BREAKER;
        if (stake < c.minStake) return QUOTE_STAKE;
        if (q.liquidityEth < c.minLiquidityEth) return QUOTE_LOW_LIQUIDITY;
        if (!LevLogic.bandsOk(r, q.spotTick, q.fastTick, q.slowTick)) return QUOTE_PRICE_BAND;
        if (lev == 0 || lev > q.maxLeverage) return QUOTE_LEVERAGE;
        if (q.netRoom < size) return QUOTE_COIN_FULL;
        uint256 grown = block.timestamp >= uint256(m.growthStart) + HOUR ? 0 : m.growthSize;
        if ((grown + size) * BPS > LevLogic.coinCap(c, m.netCapEth, q.liquidityEth) * r.hourlyGrowthBps) {
            return QUOTE_GROWING_TOO_FAST;
        }
        if (
            stake > q.poolRoomStake || (exchange.totalOpenSize() + size) * BPS > cash * r.platformSizeBps
                || exchange.openPositionCount() >= exchange.MAX_OPEN_POSITIONS()
        ) return QUOTE_POOL_FULL;
        if (_wouldLiquidate(c, q, isLong, lev, stake)) return QUOTE_WOULD_LIQUIDATE;
        return QUOTE_OK;
    }

    /// @dev Highest leverage the coin's liquidity, the curator, the side and this stake's size tier allow.
    function _maxLeverage(Config memory c, RiskConfig memory r, uint8 marketMax, uint256 liq, bool isLong, uint256 stake)
        internal
        pure
        returns (uint8 lev)
    {
        lev = LevLogic.allowedLeverage(c, marketMax, liq, isLong);
        while (lev > 1 && lev > LevLogic.sizeTierLeverage(r, stake * lev, liq)) lev--;
    }

    /// @notice The exit tick a close of position `id` would get right now (worse of live and fast price, the pump
    ///         band for longs, the spread), for setting the close's price limit. `ok` is false while it can't close
    ///         at a live price (feed down, rug under way, or settled at the rug price instead).
    function quoteClose(uint256 id) external view returns (bool ok, int24 exitTick) {
        Position memory p = exchange.positionData(id);
        if (p.owner == address(0)) return (false, 0);
        Config memory c = exchange.getConfig();
        RiskConfig memory r = exchange.getRiskConfig();
        Market memory m = exchange.marketData(p.marketId);
        if (!p.isLong && p.rugEpoch < m.rugEpoch) return (false, 0);
        int24 spot;
        int24 fast;
        int24 slow;
        uint256 liq;
        (ok, spot, fast, slow, liq) = _tryRead(m);
        if (!ok || (!p.isLong && LevLogic.isRug(c, spot, slow))) return (false, 0);
        exitTick = p.isLong ? _min24(spot, fast) : _max24(spot, fast);
        if (p.isLong) exitTick = LevLogic.capLongExit(r, exitTick, slow);
        exitTick = LevLogic.worsen(exitTick, LevLogic.spreadTicks(r, uint256(p.stake) * p.leverage, liq), !p.isLong);
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
        int256 margin = int256(exchange.marginOf(id));
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
            int256 eqNow = stake + margin + v.pnl - int256(v.holdFee);
            // a long's max win counts at the pump-band-capped price, as closeAtMaxWin counts it
            int256 winPnl = p.isLong
                ? LevLogic.pnl(p, LevLogic.capLongExit(exchange.getRiskConfig(), v.markTick, ok ? slow : m.lastGoodTick))
                : v.pnl;
            // Report only what the exchange would accept now: a down feed counts once it is stale, and a short
            // can't be closed while a rug the guard hasn't caught yet is under way.
            bool actable = ok ? (p.isLong || !LevLogic.isRug(c, spot, slow)) : _stale(c, m);
            if (actable) {
                if (winPnl >= maxWin) v.action = ACTION_MAX_WIN;
                else if (eqNow <= int256((uint256(p.stake) * c.liqEquityBps) / BPS)) v.action = ACTION_LIQUIDATE;
                else if (block.timestamp >= uint256(p.openedAt) + c.minHoldSeconds && (!ok || _nearFast(spot, fast))) {
                    v.action = _triggerAction(id, p, v.markTick);
                }
            }
        }
        v.equity = stake + margin + v.pnl - int256(v.holdFee);
    }

    /// @dev closeByTrigger waits while the live price is more than openBandSpotTicks from the fast one.
    function _nearFast(int24 spot, int24 fast) internal view returns (bool) {
        int256 d = int256(spot) - int256(fast);
        return (d < 0 ? -d : d) <= int256(uint256(exchange.getRiskConfig().openBandSpotTicks));
    }

    function _triggerAction(uint256 id, Position memory p, int24 fast) internal view returns (uint8) {
        Trigger memory t = exchange.triggerOf(id);
        if (t.hasTakeProfit && (p.isLong ? fast >= t.takeProfit : fast <= t.takeProfit)) return ACTION_TAKE_PROFIT;
        if (t.hasStopLoss && (p.isLong ? fast <= t.stopLoss : fast >= t.stopLoss)) return ACTION_STOP_LOSS;
        return ACTION_NONE;
    }

    /// @notice An owner's waiting orders, with their ids.
    function ordersOf(address owner) external view returns (uint256[] memory ids, Order[] memory orders) {
        ids = exchange.orderIdsOf(owner);
        orders = new Order[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            orders[i] = exchange.orderData(ids[i]);
        }
    }

    /// @notice Keeper helper: waiting orders in [offset, offset+limit) whose trigger the fast price has reached
    ///         (ORDER_FILL) or that have expired (ORDER_EXPIRED: anyone may cancel them, refunding the owner).
    function actionableOrders(uint256 offset, uint256 limit) external view returns (uint256[] memory ids, uint8[] memory kinds) {
        uint256[] memory page = exchange.openOrderIds(offset, limit);
        uint8[] memory all = new uint8[](page.length);
        uint256 n;
        for (uint256 i; i < page.length; ++i) {
            Order memory o = exchange.orderData(page[i]);
            if (block.timestamp > o.expiresAt) all[i] = ORDER_EXPIRED;
            else if (_fillable(o)) all[i] = ORDER_FILL;
            if (all[i] != 0) n++;
        }
        ids = new uint256[](n);
        kinds = new uint8[](n);
        uint256 k;
        for (uint256 i; i < page.length; ++i) {
            if (all[i] == 0) continue;
            ids[k] = page[i];
            kinds[k++] = all[i];
        }
    }

    /// @dev True when fillOrder would succeed now: trigger reached, every open check passes, the fill within the
    ///      order's slippage, and the escrow plus the owner's balance covering today's fee.
    function _fillable(Order memory o) internal view returns (bool) {
        Quote memory q = quoteOpen(o.marketId, o.isLong, o.leverage, o.stake);
        if (q.reason != QUOTE_OK || (o.above ? q.fastTick < o.triggerTick : q.fastTick > o.triggerTick)) return false;
        int256 limit = o.isLong ? int256(o.triggerTick) + int256(uint256(o.slipTicks)) : int256(o.triggerTick) - int256(uint256(o.slipTicks));
        if (o.isLong ? int256(q.entryTick) > limit : int256(q.entryTick) < limit) return false;
        return uint256(o.escrow) + exchange.balanceOf(o.owner) >= uint256(o.stake) + q.fee;
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

    /// @notice Sum of all open stakes, with margin added to them. The exchange holds exactly sum(balances) + this
    ///         + treasuryBalance + orderEscrow.
    function totalOpenStake() external view returns (uint256 total) {
        uint256 n = exchange.marketCount();
        for (uint256 i; i < n; ++i) {
            Market memory m = exchange.marketData(i);
            total += m.longs.stake + m.shorts.stake + m.longs.margin + m.shorts.margin;
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

    function _min3(int256 a, int256 b, int256 c) internal pure returns (int256) {
        int256 m = a < b ? a : b;
        return c < m ? c : m;
    }

    function _max3(int256 a, int256 b, int256 c) internal pure returns (int256) {
        int256 m = a > b ? a : b;
        return c > m ? c : m;
    }

    function _max24(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a : b;
    }

    function _min24(int24 a, int24 b) internal pure returns (int24) {
        return a < b ? a : b;
    }
}
