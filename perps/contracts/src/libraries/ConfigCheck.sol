// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Config} from "../LevTypes.sol";

/// @notice The hard limits on LevExchange settings. A separately deployed library, to keep LevExchange under
///         the 24 KB contract size limit; it only runs when the owner changes the config.
library ConfigCheck {
    uint256 internal constant BPS = 10_000;

    function isValid(Config memory c) public pure returns (bool) {
        bool bad = c.openFeeStakeBps > 300 || c.openFeeSizeBps > 100 || c.profitFeeBps > 2000
            || c.poolFeeShareBps < 2000 || c.poolFeeShareBps > BPS || c.holdRateBpsPerHour > 50
            || c.crowdMultBps < BPS || c.crowdMultBps > 10 * BPS || c.liqEquityBps < 500 || c.liqEquityBps > 5000
            || c.keeperRewardBps > 5000 || c.longMaxWinBps < BPS || c.longMaxWinBps2 < c.longMaxWinBps
            || c.longMaxWinBps3 < c.longMaxWinBps2 || c.longMaxWinBps3 > 20 * BPS
            || c.maxWinTier3Cash < c.maxWinTier2Cash || c.shortMaxWinBps < 1000 || c.shortMaxWinBps > 20 * BPS
            || c.maxShortLeverage == 0 || c.maxShortLeverage > 10 || c.lev10LiquidityEth < c.lev5LiquidityEth
            || c.netCapLiquidityBps > 500 || c.coverageBps < 1000 || c.coverageBps > BPS || c.rugDropBps < 5000
            || c.rugDropBps > 9900 || c.rugCapBps > BPS || c.minHoldSeconds > 600 || c.staleSeconds < 60
            || c.hourlyLossBreakerBps > 5000 || c.minStake == 0
            // Exits must never be frozen for long: a dead feed settles within an hour, a rug lock ends within a day.
            || c.staleSeconds > 1 hours || c.rugLockSeconds < 10 minutes || c.rugLockSeconds > 1 days
            || c.freeHoldSeconds > 6 hours;
        return !bad;
    }
}
