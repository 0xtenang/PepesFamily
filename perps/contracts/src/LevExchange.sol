// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ILevPool} from "./interfaces/ILevPool.sol";
import {LevLogic} from "./libraries/LevLogic.sol";
import {ConfigCheck} from "./libraries/ConfigCheck.sol";
import {Config, Side, Market, Position} from "./LevTypes.sol";
import {LevExchangeBase} from "./LevExchangeBase.sol";

/// @title LevExchange
/// @notice Leveraged longs and shorts on curated memecoins. The LevPool takes the other side of every position.
/// @dev Trader ETH sits here as internal balances and open stakes. The pool's money sits in LevPool.
///      Invariant: address(this).balance == sum(balanceOf) + open stakes + treasuryBalance.
///      This contract holds the money paths. Listings, config, the rug guard, refresh and reads run in
///      LevExchangeAdmin through `fallback` (delegatecall, same storage), so to callers it is one contract.
///      Read-only previews and the pool's valuation live in LevLens; session-key trades arrive through LevRouter.
contract LevExchange is LevExchangeBase {
    using EnumerableSet for EnumerableSet.UintSet;

    ILevPool public immutable pool;
    /// @notice Code for every function not defined here. Runs on this contract's storage.
    address public immutable admin;

    constructor(ILevPool pool_, address owner_, address treasury_, address admin_) LevExchangeBase(owner_, treasury_) {
        pool = pool_;
        admin = admin_;
    }

    // ---------------------------------------------------------------- balances

    receive() external payable {
        // The pool pays winners by sending ETH here; anyone else is depositing.
        if (msg.sender != address(pool)) _credit(msg.sender, msg.value);
    }

    /// @dev Everything else (listings, config, guard, refresh, reads) is LevExchangeAdmin's code on our storage.
    fallback() external payable {
        address target = admin;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function deposit() external payable {
        _credit(msg.sender, msg.value);
    }

    function depositFor(address user) external payable {
        _credit(user, msg.value);
    }

    function withdraw(uint256 amount) external nonReentrant {
        _withdraw(msg.sender, amount);
    }

    /// @notice Open a position. Any ETH sent is deposited first.
    /// @param limitTick Worst acceptable entry: longs revert above it, shorts below it.
    function open(uint256 marketId, bool isLong, uint8 leverage, uint256 stake, int24 limitTick)
        external
        payable
        nonReentrant
        returns (uint256)
    {
        if (msg.value > 0) _credit(msg.sender, msg.value);
        return _openPosition(msg.sender, marketId, isLong, leverage, stake, limitTick, NO_SLIP_BOUND);
    }

    /// @notice Close your own position at a fair price.
    /// @param limitTick Worst acceptable exit: longs revert below it, shorts above it.
    function close(uint256 id, int24 limitTick) external nonReentrant {
        _closePosition(msg.sender, id, limitTick, NO_SLIP_BOUND);
    }

    /// @dev The router has already checked the trader's session signature and limits. The fill must also stay
    ///      within `maxSlipTicks` of the fast price, so a stolen session key can't force a fill at a pushed price.
    function openFor(
        address trader,
        uint256 marketId,
        bool isLong,
        uint8 leverage,
        uint256 stake,
        int24 limitTick,
        uint256 maxSlipTicks
    ) external nonReentrant onlyRouter returns (uint256) {
        return _openPosition(trader, marketId, isLong, leverage, stake, limitTick, maxSlipTicks);
    }

    function closeFor(address trader, uint256 id, int24 limitTick, uint256 maxSlipTicks) external nonReentrant onlyRouter {
        _closePosition(trader, id, limitTick, maxSlipTicks);
    }

    /// @dev Always pays the trader's own address.
    function withdrawFor(address trader, uint256 amount) external nonReentrant onlyRouter {
        _withdraw(trader, amount);
    }

    /// @notice Liquidate a position whose equity has fallen to the liquidation level. Pays the caller a reward.
    function liquidate(uint256 id) external nonReentrant {
        Position memory p = _requireOpen(id);
        Config memory c = _config;
        Market storage m = _markets[p.marketId];
        if (!p.isLong && p.rugEpoch < m.rugEpoch) revert NotLiquidatable();
        _accrue(m, c);
        int256 pnl = LevLogic.pnl(p, _markTick(m, c, false));
        Side storage s = p.isLong ? m.longs : m.shorts;
        int256 equity = int256(uint256(p.stake)) + pnl - int256(LevLogic.holdFee(p, s.feeIndex, c, block.timestamp));
        bool atMax = pnl >= int256((uint256(p.stake) * p.maxWinBps) / BPS);
        if (atMax || equity > int256((uint256(p.stake) * c.liqEquityBps) / BPS)) revert NotLiquidatable();
        _finish(id, p, m, c, pnl, EXIT_LIQUIDATION, msg.sender);
    }

    /// @notice Close a position that has reached its max win. Anyone can call this; it frees pool room.
    function closeAtMaxWin(uint256 id) external nonReentrant {
        Position memory p = _requireOpen(id);
        Config memory c = _config;
        Market storage m = _markets[p.marketId];
        if (!p.isLong && p.rugEpoch < m.rugEpoch) revert NotAtMaxWin();
        _accrue(m, c);
        int256 pnl = LevLogic.pnl(p, _markTick(m, c, !p.isLong));
        if (pnl < int256((uint256(p.stake) * p.maxWinBps) / BPS)) revert NotAtMaxWin();
        _finish(id, p, m, c, pnl, EXIT_MAX_WIN, msg.sender);
    }

    /// @notice Settle a short that was open when the rug guard fired. Anyone can call this.
    function settleRugged(uint256 id) external nonReentrant {
        Position memory p = _requireOpen(id);
        Market storage m = _markets[p.marketId];
        if (p.isLong || p.rugEpoch >= m.rugEpoch) revert NotRugged();
        Config memory c = _config;
        _accrue(m, c);
        _settleRug(id, p, m, c);
    }

    function _openPosition(
        address trader,
        uint256 marketId,
        bool isLong,
        uint8 leverage,
        uint256 stake,
        int24 limitTick,
        uint256 maxSlipTicks
    ) internal returns (uint256 id) {
        Config memory c = _config;
        Market storage m = _market(marketId);
        _checkCanOpen(c, m, stake);
        Position memory np = _pricePosition(c, m, isLong, leverage, stake, limitTick, maxSlipTicks);
        np.owner = trader;
        np.marketId = uint32(marketId);

        uint256 fee = LevLogic.tradeFee(c, stake, stake * leverage);
        if (balanceOf[trader] < stake + fee) revert InsufficientBalance();
        balanceOf[trader] -= stake + fee;
        openStakeOf[trader] += stake;

        id = nextPositionId++;
        _positions[id] = np;
        _addPosition(m, np);
        _openIds.add(id);
        _byOwner[trader].add(id);

        uint256 toPool = (fee * c.poolFeeShareBps) / BPS;
        treasuryBalance += fee - toPool;
        hourPoolPnl += int256(toPool);
        if (toPool > 0) pool.receiveFromExchange{value: toPool}();
        emit Opened(id, trader, marketId, isLong, leverage, stake, np.entryTick, np.maxWinBps, fee);
    }

    function _checkCanOpen(Config memory c, Market storage m, uint256 stake) internal {
        if (opensPaused || !m.active) revert MarketClosed();
        if (m.rugAt != 0 && block.timestamp < uint256(m.rugAt) + c.rugLockSeconds) revert MarketLocked();
        if (stake < c.minStake || stake > type(uint96).max) revert StakeTooSmall();
        _rollHour();
        if (
            block.timestamp < breakerUntil
                || LevLogic.breakerTripped(c, hourStart, hourPoolPnl, hourStartCash, block.timestamp)
        ) revert BreakerTripped();
    }

    /// @dev Reads the price, checks every limit and returns the position to store (owner and market not set).
    function _pricePosition(
        Config memory c,
        Market storage m,
        bool isLong,
        uint8 leverage,
        uint256 stake,
        int24 limitTick,
        uint256 maxSlipTicks
    ) internal returns (Position memory np) {
        (int24 spot, int24 fast, int24 slow, uint256 liq) = m.oracle.read();
        _recordGood(m, fast, slow);
        if (liq < c.minLiquidityEth) revert LiquidityTooLow();
        if (leverage == 0 || leverage > LevLogic.allowedLeverage(c, m.maxLeverage, liq, isLong)) revert LeverageNotAllowed();
        // Fill at whichever price is worse for the trader.
        np.entryTick = isLong ? _max24(spot, fast) : _min24(spot, fast);
        if (isLong ? np.entryTick > limitTick : np.entryTick < limitTick) revert PriceMoved();
        if (maxSlipTicks != NO_SLIP_BOUND && _gap(isLong ? np.entryTick : fast, isLong ? fast : np.entryTick) > maxSlipTicks) {
            revert PriceMoved();
        }

        _accrue(m, c);
        if (LevLogic.netRoom(c, m.netCapEth, m.longs.size, m.shorts.size, isLong, liq) < stake * leverage) revert CoinFull();
        uint256 cash = pool.cash();
        np.maxWinBps = LevLogic.maxWinBps(c, cash, isLong, leverage);
        if ((totalMaxWin + (stake * np.maxWinBps) / BPS) * BPS > cash * c.coverageBps) revert PoolFull();

        np.rugEpoch = m.rugEpoch;
        np.openedAt = uint64(block.timestamp);
        np.isLong = isLong;
        np.leverage = leverage;
        np.stake = uint96(stake);
        np.feeIndex = isLong ? m.longs.feeIndex : m.shorts.feeIndex;
        // Don't open a position that the fast price would liquidate at once.
        if (int256(stake) + LevLogic.pnl(np, fast) <= int256((stake * c.liqEquityBps) / BPS)) revert WouldLiquidate();
    }

    function _addPosition(Market storage m, Position memory p) internal {
        Side storage s = p.isLong ? m.longs : m.shorts;
        uint256 size = uint256(p.stake) * p.leverage;
        uint256 maxWin = (uint256(p.stake) * p.maxWinBps) / BPS;
        s.size += size;
        s.stake += p.stake;
        s.maxWin += maxWin;
        s.expo += LevLogic.expoOf(m.refTick, p.entryTick, size);
        s.sizeIndexSum += (size * p.feeIndex) / ONE;
        if (!p.isLong) m.shortCount++;
        totalMaxWin += maxWin;
    }

    function _closePosition(address trader, uint256 id, int24 limitTick, uint256 maxSlipTicks) internal {
        Position memory p = _positions[id];
        if (p.owner != trader) revert NotPositionOwner();
        Config memory c = _config;
        if (block.timestamp < uint256(p.openedAt) + c.minHoldSeconds) revert TooSoon();
        Market storage m = _markets[p.marketId];
        _accrue(m, c);
        if (!p.isLong && p.rugEpoch < m.rugEpoch) {
            _settleRug(id, p, m, c);
            return;
        }

        (bool ok, int24 spot, int24 fast, int24 slow,) = _tryRead(m);
        int24 exitTick;
        uint8 kind = EXIT_CLOSE;
        if (ok) {
            _recordGood(m, fast, slow);
            if (!p.isLong) _requireNoRug(c, spot, slow);
            exitTick = p.isLong ? _min24(spot, fast) : _max24(spot, fast);
            if (p.isLong ? exitTick < limitTick : exitTick > limitTick) revert PriceMoved();
            if (maxSlipTicks != NO_SLIP_BOUND && _gap(p.isLong ? fast : exitTick, p.isLong ? exitTick : fast) > maxSlipTicks) {
                revert PriceMoved();
            }
        } else {
            _requireStale(m, c);
            exitTick = m.lastGoodFast;
            kind = EXIT_STALE;
        }
        _finish(id, p, m, c, LevLogic.pnl(p, exitTick), kind, address(0));
    }

    function _settleRug(uint256 id, Position memory p, Market storage m, Config memory c) internal {
        int256 pnl = LevLogic.pnl(p, rugTickOf[p.marketId][p.rugEpoch + 1]);
        int256 cap = int256((uint256(p.stake) * c.rugCapBps) / BPS);
        if (pnl > cap) pnl = cap;
        _finish(id, p, m, c, pnl, EXIT_RUG, address(0));
    }

    /// @dev What a closing position pays out. `kind` may change to EXIT_LIQUIDATION.
    struct Outcome {
        uint256 payout;
        uint256 fees;
        uint256 reward;
        uint256 hold;
        uint8 kind;
    }

    /// @dev Pays everyone and books the rest against the pool. `pnl` is already capped.
    function _finish(uint256 id, Position memory p, Market storage m, Config memory c, int256 pnl, uint8 kind, address keeper)
        internal
    {
        Side storage s = p.isLong ? m.longs : m.shorts;
        Outcome memory o = _outcome(p, c, pnl, LevLogic.holdFee(p, s.feeIndex, c, block.timestamp), kind, keeper);
        _removePosition(id, p, m, s);

        uint256 toPool = (o.fees * c.poolFeeShareBps) / BPS;
        treasuryBalance += o.fees - toPool;
        if (o.payout > 0) balanceOf[p.owner] += o.payout;
        if (o.reward > 0) balanceOf[keeper] += o.reward;
        // This contract held the stake. Whatever the trader, keeper and treasury don't take goes to the pool;
        // if they take more, the pool pays the difference.
        int256 poolDelta = int256(uint256(p.stake)) - int256(o.payout) - int256(o.reward) - int256(o.fees - toPool);
        _bookPool(c, poolDelta);
        emit Closed(id, p.owner, p.marketId, o.kind, pnl, o.hold, o.fees, o.payout, keeper, o.reward);
    }

    function _outcome(Position memory p, Config memory c, int256 pnl, uint256 hold, uint8 kind, address keeper)
        internal
        pure
        returns (Outcome memory o)
    {
        o.hold = hold;
        o.kind = kind;
        uint256 stake = p.stake;
        int256 equity = int256(stake) + pnl - int256(hold);
        // Only liquidate() books a loss with leftover equity as a liquidation. A position the trader or keeper
        // closes any other way is paid what is left, unless nothing is.
        if (equity <= 0 || kind == EXIT_LIQUIDATION) {
            // The trader loses the stake. What equity is left is the liquidation fee.
            uint256 left = equity > 0 ? uint256(equity) : 0;
            if (keeper != address(0)) o.reward = (left * c.keeperRewardBps) / BPS;
            o.fees = left - o.reward;
            o.kind = EXIT_LIQUIDATION;
        } else {
            uint256 eq = uint256(equity);
            uint256 profit = pnl > int256(hold) ? uint256(pnl - int256(hold)) : 0;
            o.fees = LevLogic.tradeFee(c, eq, stake * p.leverage) + (profit * c.profitFeeBps) / BPS;
            if (o.fees > eq) o.fees = eq;
            o.payout = eq - o.fees;
            // Pay whoever clears a max win a share of its fees, so it doesn't wait for our own keeper.
            if (kind == EXIT_MAX_WIN && keeper != address(0)) {
                o.reward = (o.fees * c.keeperRewardBps) / BPS;
                o.fees -= o.reward;
            }
        }
    }

    function _removePosition(uint256 id, Position memory p, Market storage m, Side storage s) internal {
        uint256 stake = p.stake;
        uint256 size = stake * p.leverage;
        uint256 maxWin = (stake * p.maxWinBps) / BPS;
        s.size -= size;
        s.stake -= stake;
        s.maxWin -= maxWin;
        s.expo -= LevLogic.expoOf(m.refTick, p.entryTick, size);
        s.sizeIndexSum -= (size * p.feeIndex) / ONE;
        if (!p.isLong) {
            m.shortCount--;
            if (p.rugEpoch < m.rugEpoch && m.ruggedPending > 0) m.ruggedPending--;
        }
        openStakeOf[p.owner] -= stake;
        totalMaxWin -= maxWin;
        _openIds.remove(id);
        _byOwner[p.owner].remove(id);
        delete _positions[id];
    }

    /// @dev Moves the pool's share and counts it toward the loss breaker, which pauses opens for a full hour
    ///      once it trips.
    function _bookPool(Config memory c, int256 poolDelta) internal {
        _rollHour();
        hourPoolPnl += poolDelta;
        if (
            poolDelta < 0 && LevLogic.breakerTripped(c, hourStart, hourPoolPnl, hourStartCash, block.timestamp)
                && breakerUntil < block.timestamp + HOUR
        ) breakerUntil = uint64(block.timestamp + HOUR);
        if (poolDelta > 0) pool.receiveFromExchange{value: uint256(poolDelta)}();
        else if (poolDelta < 0) pool.payToExchange(uint256(-poolDelta));
    }

    /// @param checkRug For shorts: refuse while the live price shows a rug the guard hasn't caught yet.
    function _markTick(Market storage m, Config memory c, bool checkRug) internal returns (int24) {
        (bool ok, int24 spot, int24 fast, int24 slow,) = _tryRead(m);
        if (ok) {
            _recordGood(m, fast, slow);
            if (checkRug) _requireNoRug(c, spot, slow);
            return fast;
        }
        _requireStale(m, c);
        return m.lastGoodFast;
    }

    /// @dev Stale settlement needs an unbroken run of failed reads, still going, that started after the last
    ///      good read and has lasted staleSeconds.
    function _requireStale(Market storage m, Config memory c) internal view {
        if (
            m.downSince == 0 || block.timestamp < uint256(m.downSince) + c.staleSeconds
                || block.timestamp > uint256(m.lastFailAt) + STALE_PING_GAP || m.lastGoodAt > m.downSince
        ) revert OracleDown();
    }

    /// @dev A short can't close while the live price sits a rug's depth under the slow price: the rug guard is
    ///      about to cap it.
    function _requireNoRug(Config memory c, int24 spot, int24 slow) internal pure {
        if (LevLogic.isRug(c, spot, slow)) revert RugInProgress();
    }

    function _rollHour() internal {
        if (block.timestamp >= uint256(hourStart) + HOUR) {
            hourStart = uint64(block.timestamp);
            hourStartCash = pool.cash();
            hourPoolPnl = 0;
        }
    }

    function _requireOpen(uint256 id) internal view returns (Position memory p) {
        p = _positions[id];
        if (p.owner == address(0)) revert NotOpen();
    }

    function _withdraw(address user, uint256 amount) internal {
        if (balanceOf[user] < amount) revert InsufficientBalance();
        balanceOf[user] -= amount;
        _send(user, amount);
        emit Withdrawn(user, amount);
    }

    function _credit(address user, uint256 amount) internal {
        balanceOf[user] += amount;
        emit Deposited(user, amount);
    }

    /// @dev How far `hi` is above `lo`, in ticks; 0 if it isn't.
    function _gap(int24 hi, int24 lo) internal pure returns (uint256) {
        return hi > lo ? uint256(int256(hi) - int256(lo)) : 0;
    }
}
