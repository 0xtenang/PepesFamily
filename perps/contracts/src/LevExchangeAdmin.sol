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
