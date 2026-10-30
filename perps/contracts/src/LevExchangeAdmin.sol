// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ILevPool} from "./interfaces/ILevPool.sol";
import {LevLogic} from "./libraries/LevLogic.sol";
import {ConfigCheck} from "./libraries/ConfigCheck.sol";
import {Config, Side, Market, Position, RiskConfig, Trigger, Order} from "./LevTypes.sol";
import {LevExchangeBase} from "./LevExchangeBase.sol";

/// @title LevExchangeAdmin
/// @notice Listings, config, pauses, the rug guard, price refresh and reads of LevExchange. Never used on its own:
///         LevExchange delegatecalls into it, so this code always runs on LevExchange's storage.
contract LevExchangeAdmin is LevExchangeBase {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @dev Its own storage is never used; the owner and treasury here are placeholders.
    constructor() LevExchangeBase(address(0xdead), address(0xdead)) {}

    /// @notice Fire the rug guard on a coin whose fast price has crashed far below its slow price.
    function triggerRugGuard(uint256 marketId) external nonReentrant {
        Config memory c = _config;
        Market storage m = _market(marketId);
        if (m.rugAt != 0 && block.timestamp < uint256(m.rugAt) + c.rugLockSeconds) revert MarketLocked();
        (, int24 fast, int24 slow,) = m.oracle.read();
        if (!LevLogic.isRug(c, fast, slow)) revert NoRug();
        _accrue(m, c);
        uint32 epoch = m.rugEpoch + 1;
        m.rugEpoch = epoch;
        m.rugAt = uint64(block.timestamp);
        m.ruggedPending = m.shortCount; // every open short is now settled at the rug price
        rugTickOf[marketId][epoch] = fast;
        emit RugGuardTriggered(marketId, epoch, fast, slow);
    }

    /// @notice Record the coin's price, or start the stale clock if its feed is failing. Keepers call this.
    function refresh(uint256 marketId) external {
        Market storage m = _market(marketId);
        (bool ok,, int24 fast, int24 slow,) = _tryRead(m);
        if (ok) {
            _recordGood(m, fast, slow);
        } else {
            // A run of failures only counts while it is unbroken: after a gap the stale clock starts over.
            if (m.downSince == 0 || block.timestamp > uint256(m.lastFailAt) + STALE_PING_GAP) {
                m.downSince = uint64(block.timestamp);
                emit FeedDown(marketId, m.downSince);
            }
            m.lastFailAt = uint64(block.timestamp);
        }
        _accrue(m, _config);
    }

    function listMarket(IPriceOracle oracle, uint8 maxLeverage, uint256 netCapEth) external onlyOwner returns (uint256 id) {
        if (_markets.length >= MAX_MARKETS) revert TooManyMarkets();
        if (maxLeverage == 0 || maxLeverage > 10) revert BadConfig();
        (,, int24 slow,) = oracle.read();
        id = _markets.length;
        Market storage m = _markets.push();
        m.oracle = oracle;
        m.active = true;
        m.maxLeverage = maxLeverage;
        m.netCapEth = netCapEth;
        m.refTick = slow;
        m.lastGoodTick = slow;
        m.lastGoodFast = slow;
        m.lastGoodAt = uint64(block.timestamp);
        m.lastFeeUpdate = uint64(block.timestamp);
        emit MarketListed(id, address(oracle), maxLeverage, netCapEth, slow);
    }

    /// @notice Pause or resume a coin and change its curator caps. Open positions can always be closed.
    function setMarket(uint256 id, bool active, uint8 maxLeverage, uint256 netCapEth) external onlyOwner {
        if (maxLeverage == 0 || maxLeverage > 10) revert BadConfig();
        Market storage m = _market(id);
        m.active = active;
        m.maxLeverage = maxLeverage;
        m.netCapEth = netCapEth;
        emit MarketUpdated(id, active, maxLeverage, netCapEth);
    }

    function setConfig(Config calldata c) external onlyOwner {
        _validate(c);
        // Charge the time already passed at the old holding-fee rates before the new ones apply.
        Config memory old = _config;
        for (uint256 i; i < _markets.length; ++i) {
            _accrue(_markets[i], old);
        }
        _config = c;
        emit ConfigUpdated();
    }

    function setRiskConfig(RiskConfig calldata r) external onlyOwner {
        _validateRisk(r);
        _risk = r;
        emit RiskConfigUpdated();
    }

    // ------------------------------------------------------------ trader tools

    /// @notice Add collateral to your open position, from your balance (and any ETH sent). It moves the
    ///         liquidation price away; size and max win stay the same, and it comes back with the position.
    function addMargin(uint256 id, uint256 amount) external payable nonReentrant {
        if (msg.value > 0) {
            balanceOf[msg.sender] += msg.value;
            emit Deposited(msg.sender, msg.value);
        }
        Position memory p = _positions[id];
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (amount == 0 || balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        marginOf[id] += amount;
        Market storage m = _markets[p.marketId];
        (p.isLong ? m.longs : m.shorts).margin += amount;
        emit MarginAdded(id, amount);
    }

    /// @notice Set or clear your position's take-profit and stop-loss, as fast-price ticks. A level the fast price
    ///         has already reached is refused: close the position instead.
    function setTriggers(uint256 id, bool hasTakeProfit, int24 takeProfit, bool hasStopLoss, int24 stopLoss) external {
        Position memory p = _positions[id];
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (hasTakeProfit || hasStopLoss) {
            (, int24 fast,,) = _markets[p.marketId].oracle.read();
            if (
                (hasTakeProfit && (p.isLong ? takeProfit <= fast : takeProfit >= fast))
                    || (hasStopLoss && (p.isLong ? stopLoss >= fast : stopLoss <= fast))
            ) revert BadConfig();
        }
        _triggers[id] = Trigger({takeProfit: takeProfit, stopLoss: stopLoss, hasTakeProfit: hasTakeProfit, hasStopLoss: hasStopLoss});
        emit TriggersSet(id, hasTakeProfit, takeProfit, hasStopLoss, stopLoss);
    }

    /// @notice Open a position later, once the fast price reaches `triggerTick` (from below when `above`). The
    ///         stake and today's open fee move from your balance (and any ETH sent) into escrow.
    /// @param slipTicks The fill may be at most this far past the trigger against you (at most 1000, ~10%).
    function placeOrder(
        uint256 marketId,
        bool isLong,
        uint8 leverage,
        uint256 stake,
        int24 triggerTick,
        bool above,
        uint24 slipTicks,
        uint64 expiresAt
    ) external payable nonReentrant returns (uint256 orderId) {
        if (msg.value > 0) {
            balanceOf[msg.sender] += msg.value;
            emit Deposited(msg.sender, msg.value);
        }
        Config memory c = _config;
        Market storage m = _market(marketId);
        if (!m.active) revert MarketClosed();
        if (stake < c.minStake || stake > type(uint96).max) revert StakeTooSmall();
        if (leverage == 0 || leverage > m.maxLeverage || (!isLong && leverage > c.maxShortLeverage)) revert LeverageNotAllowed();
        if (slipTicks > 1000 || expiresAt <= block.timestamp || expiresAt > block.timestamp + 30 days) revert BadConfig();
        uint256 escrow = stake + LevLogic.tradeFee(c, stake, stake * leverage);
        if (balanceOf[msg.sender] < escrow) revert InsufficientBalance();
        balanceOf[msg.sender] -= escrow;
        orderEscrow += escrow;
        orderId = nextOrderId++;
        Order memory o = Order({
            owner: msg.sender,
            marketId: uint32(marketId),
            isLong: isLong,
            above: above,
            leverage: leverage,
            triggerTick: triggerTick,
            slipTicks: slipTicks,
            expiresAt: expiresAt,
            stake: uint96(stake),
            escrow: uint96(escrow)
        });
        _orders[orderId] = o;
        _openOrders.add(orderId);
        _ordersByOwner[msg.sender].add(orderId);
        emit OrderPlaced(orderId, msg.sender, marketId, o);
    }

    /// @notice Cancel your order (or anyone's once it has expired). The escrow goes back to the owner's balance.
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order memory o = _orders[orderId];
        if (o.owner == address(0)) revert NoOrder();
        if (msg.sender != o.owner && block.timestamp <= o.expiresAt) revert Unauthorized();
        _takeOrder(orderId);
        emit OrderCancelled(orderId);
    }

    /// @notice The guardian can pause; only the owner can unpause.
    function setOpensPaused(bool paused) external {
        if (msg.sender != owner() && !(msg.sender == guardian && paused)) revert Unauthorized();
        opensPaused = paused;
        emit OpensPaused(paused);
    }

    function setRouter(address router_) external onlyOwner {
        if (router != address(0)) revert AlreadySet();
        router = router_;
        emit RouterSet(router_);
    }

    function setGuardian(address g) external onlyOwner {
        guardian = g;
    }

    function setTreasury(address t) external onlyOwner {
        treasury = t;
    }

    function claimTreasury() external nonReentrant {
        uint256 amount = treasuryBalance;
        treasuryBalance = 0;
        _send(treasury, amount);
        emit TreasuryClaimed(treasury, amount);
    }

    function getConfig() external view returns (Config memory) {
        return _config;
    }

    function getRiskConfig() external view returns (RiskConfig memory) {
        return _risk;
    }

    function triggerOf(uint256 id) external view returns (Trigger memory) {
        return _triggers[id];
    }

    function orderData(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    function orderIdsOf(address owner_) external view returns (uint256[] memory) {
        return _ordersByOwner[owner_].values();
    }

    function openOrderCount() external view returns (uint256) {
        return _openOrders.length();
    }

    function openOrderIds(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _openOrders.length();
        if (offset >= n) return ids;
        uint256 end = offset + limit > n ? n : offset + limit;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            ids[i - offset] = _openOrders.at(i);
        }
    }

    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    function marketData(uint256 id) external view returns (Market memory) {
        return _market(id);
    }

    function positionData(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    function openPositionCount() external view returns (uint256) {
        return _openIds.length();
    }

    function openPositionIds(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _openIds.length();
        if (offset >= n) return ids;
        uint256 end = offset + limit > n ? n : offset + limit;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            ids[i - offset] = _openIds.at(i);
        }
    }

    function positionIdsOf(address owner_) external view returns (uint256[] memory) {
        return _byOwner[owner_].values();
    }
}
