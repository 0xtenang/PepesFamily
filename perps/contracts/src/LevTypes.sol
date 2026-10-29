// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @dev Shared by LevExchange (which stores them), LevLens (which explains them) and LevRouter.

struct Config {
    uint16 openFeeStakeBps; // fee on open and close: this share of the stake...
    uint16 openFeeSizeBps; // ...or this share of position size, whichever is more
    uint16 profitFeeBps; // share of a winner's profit
    uint16 poolFeeShareBps; // share of every trading fee that goes to the pool
    uint16 holdRateBpsPerHour; // holding fee per hour, of position size, all to the pool
    uint32 crowdMultBps; // holding fee multiplier for the side with more open size on a coin
    uint32 freeHoldSeconds; // no holding fee before this age
    uint16 liqEquityBps; // liquidated once equity falls to this share of the stake
    uint16 keeperRewardBps; // share of a liquidated position's leftover equity paid to the liquidator
    uint32 longMaxWinBps; // max win while pool cash is below maxWinTier2Cash
    uint32 longMaxWinBps2;
    uint32 longMaxWinBps3;
    uint96 maxWinTier2Cash;
    uint96 maxWinTier3Cash;
    uint32 shortMaxWinBps; // extra cap on shorts
    uint8 maxShortLeverage;
    uint96 lev5LiquidityEth; // coin liquidity needed for 5x
    uint96 lev10LiquidityEth; // coin liquidity needed for 10x
    uint96 minLiquidityEth; // below this, a coin takes no new positions
    uint16 netCapLiquidityBps; // net size per coin, as a share of its ETH liquidity
    uint16 coverageBps; // open max wins may use at most this share of pool cash
    uint16 rugDropBps; // rug guard fires when the fast price is this far under the slow price
    uint16 rugCapBps; // shorts settle with at most this win after a rug
    uint32 rugLockSeconds; // no new positions on a coin this long after a rug
    uint32 minHoldSeconds;
    uint32 staleSeconds; // a price feed down this long lets positions settle at the last good price
    uint16 hourlyLossBreakerBps; // new positions pause after the pool loses this much within an hour; 0 disables
    uint96 minStake;
}

struct Side {
    uint256 size; // sum of position sizes
    uint256 stake; // sum of stakes
    uint256 maxWin; // sum of max wins
    uint256 expo; // sum of size * 1.0001^(refTick - entryTick): current value = expo * 1.0001^(tick - refTick)
    uint256 feeIndex; // cumulative holding fee per 1e18 of size
    uint256 sizeIndexSum; // sum of size * feeIndex at open / 1e18: holding fees owed = size * feeIndex / 1e18 - this
}

struct Market {
    IPriceOracle oracle;
    bool active;
    uint8 maxLeverage;
    int24 refTick; // slow price at listing; anchors `expo`
    int24 lastGoodTick; // last good slow price, for NAV
    int24 lastGoodFast; // last good fast price, for settling positions while the feed is down
    uint64 lastGoodAt;
    uint64 downSince; // start of the current unbroken run of failed reads, 0 while healthy
    uint64 lastFailAt; // last failed read; a gap longer than STALE_PING_GAP restarts the run
    uint64 lastFeeUpdate;
    uint32 rugEpoch;
    uint64 rugAt;
    uint32 shortCount; // open short positions
    uint32 ruggedPending; // shorts the rug guard caught that are not settled yet
    uint256 netCapEth;
    Side longs;
    Side shorts;
}

struct Position {
    address owner;
    uint32 marketId;
    uint32 rugEpoch;
    uint64 openedAt;
    bool isLong;
    uint8 leverage;
    int24 entryTick;
    uint32 maxWinBps;
    uint96 stake;
    uint256 feeIndex;
}
