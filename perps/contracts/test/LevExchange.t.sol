// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {LevLens} from "../src/LevLens.sol";
import {Config} from "../src/LevTypes.sol";
import {LevExchange} from "../src/LevExchange.sol";
import {LevExchangeBase} from "../src/LevExchangeBase.sol";

contract LevExchangeTest is Base {
    // ------------------------------------------------------------ open/close

    function test_longWinPaysTraderAndBooksPool() public {
        uint256 stake = 0.1 ether;
        uint256 fee = _openFee(stake, 5);
        uint256 cash0 = pool.cash();
        uint256 id = _open(alice, 0, true, 5, stake);
        assertEq(ex.balanceOf(alice), 10 ether - stake - fee);
        assertEq(pool.cash(), cash0 + fee / 2, "pool gets half the open fee");
        assertEq(ex.treasuryBalance(), fee - fee / 2);

        o0.setAll(UP_10);
        _wait(30 minutes);
        _close(alice, id);

        int256 pnl = _pnl(stake, 5, true, 0, UP_10);
        uint256 eq = stake + uint256(pnl);
        uint256 closeFee = _max(eq * 100, stake * 5 * 25) / BPS;
        uint256 fees = closeFee + (uint256(pnl) * 1000) / BPS;
        uint256 payout = eq - fees;
        assertEq(ex.balanceOf(alice), 10 ether - stake - fee + payout, "trader payout");
        uint256 toPool = (fees * 5000) / BPS;
        assertEq(pool.cash(), cash0 + fee / 2 + stake - payout - (fees - toPool), "pool pays the win");
        assertEq(exa.openPositionCount(), 0);
        assertEq(ex.totalMaxWin(), 0);
        _assertSolvent();
    }

    function test_losingLongGoesToPool() public {
        uint256 stake = 0.2 ether;
        uint256 id = _open(alice, 0, true, 2, stake);
        uint256 cash0 = pool.cash();
        o0.setAll(-953); // about -9.5%
        _wait(20 minutes);
        _close(alice, id);
        int256 pnl = _pnl(stake, 2, true, 0, -953);
        assertLt(pnl, 0);
        uint256 eq = uint256(int256(stake) + pnl);
        uint256 fees = _max(eq * 100, stake * 2 * 25) / BPS;
        assertEq(pool.cash(), cash0 + stake - (eq - fees) - (fees - (fees * 5000) / BPS));
        _assertSolvent();
    }

    function test_fillsUseWorsePriceForTrader() public {
        o0.set(100, 0, 0); // live price above the fast average
        uint256 longId = _open(alice, 0, true, 2, 0.1 ether);
        uint256 shortId = _open(bob, 0, false, 2, 0.1 ether);
        assertEq(lens.getPosition(longId).position.entryTick, 100);
        assertEq(lens.getPosition(shortId).position.entryTick, 0);
    }

    function test_limitTickProtectsEntry() public {
        o0.setAll(500);
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.PriceMoved.selector);
        ex.open(0, true, 2, 0.1 ether, 400);
    }

    function test_openWithEthDepositsFirst() public {
        address carol = makeAddr("carol");
        vm.deal(carol, 1 ether);
        vm.prank(carol);
        ex.open{value: 0.5 ether}(0, true, 2, 0.1 ether, MAX_TICK);
        assertEq(ex.balanceOf(carol), 0.4 ether - _openFee(0.1 ether, 2));
    }

    function test_minHold() public {
        uint256 id = _open(alice, 0, true, 2, 0.1 ether);
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.TooSoon.selector);
        ex.close(id, MIN_TICK);
    }

    function test_onlyOwnerCloses() public {
        uint256 id = _open(alice, 0, true, 2, 0.1 ether);
        _wait(1 minutes);
        vm.prank(bob);
        vm.expectRevert(LevExchangeBase.NotPositionOwner.selector);
        ex.close(id, MIN_TICK);
    }

    // ------------------------------------------------------------- limits

    function test_leverageFollowsLiquidity() public {
        o0.setLiquidity(10 ether); // 5x tier
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.LeverageNotAllowed.selector);
        ex.open(0, true, 10, 0.01 ether, MAX_TICK);
        _open(alice, 0, true, 5, 0.01 ether);

        o0.setLiquidity(5 ether); // 2x tier
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.LeverageNotAllowed.selector);
        ex.open(0, true, 5, 0.01 ether, MAX_TICK);

        o0.setLiquidity(0.5 ether);
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.LiquidityTooLow.selector);
        ex.open(0, true, 2, 0.01 ether, MAX_TICK);
    }

    function test_shortLeverageCappedAtFive() public {
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.LeverageNotAllowed.selector);
        ex.open(0, false, 10, 0.1 ether, MIN_TICK);
        _open(alice, 0, false, 5, 0.1 ether);
    }

    function test_netCapPerCoin() public {
        // cap = min(5 ETH curator cap, 0.5% of 400 ETH) = 2 ETH of net size
        _open(alice, 0, true, 10, 0.2 ether); // 2 ETH long
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.CoinFull.selector);
        ex.open(0, true, 2, 0.01 ether, MAX_TICK);
        // A short that rebalances the coin is fine, even past the cap on the other side.
        _open(bob, 0, false, 5, 0.6 ether); // net is now 1 ETH short
        vm.prank(bob);
        vm.expectRevert(LevExchangeBase.CoinFull.selector);
        ex.open(0, false, 5, 0.25 ether, MIN_TICK); // would make it 2.25 ETH short
    }

    function test_coverageRule() public {
        o0.setLiquidity(4000 ether);
        vm.prank(owner);
        exa.setMarket(0, true, 10, 100 ether);
        // Pool cash about 8 ETH: open max wins may use 4 ETH. 1 ETH at +400% takes all of it.
        _open(alice, 0, true, 2, 0.99 ether);
        vm.prank(bob);
        vm.expectRevert(LevExchangeBase.PoolFull.selector);
        ex.open(0, true, 2, 0.05 ether, MAX_TICK);
    }

    function test_maxWinTiersFollowPoolCash() public {
        uint256 a = _open(alice, 0, true, 10, 0.01 ether);
        assertEq(lens.getPosition(a).position.maxWinBps, 40_000);
        vm.prank(lp);
        pool.deposit{value: 5 ether}(); // 13 ETH
        uint256 b = _open(alice, 1, true, 10, 0.01 ether);
        assertEq(lens.getPosition(b).position.maxWinBps, 60_000);
        vm.prank(lp);
        pool.deposit{value: 10 ether}(); // 23 ETH
        uint256 c = _open(alice, 2, true, 10, 0.01 ether);
        assertEq(lens.getPosition(c).position.maxWinBps, 100_000);
        // A low-leverage long's max win scales with its leverage (200% per 1x), whatever the tier.
        uint256 d = _open(alice, 2, true, 2, 0.01 ether);
        assertEq(lens.getPosition(d).position.maxWinBps, 40_000);
    }

    // ---------------------------------------------------------- max wins

    function test_longCappedAtMaxWin() public {
        uint256 stake = 0.1 ether;
        uint256 id = _open(alice, 0, true, 10, stake);
        o0.setAll(UP_60); // +600% at 10x, capped at +400%
        LevLens.PositionView memory v = lens.getPosition(id);
        assertEq(v.action, 2);
        assertEq(v.pnl, int256(stake * 4));
        uint256 before = ex.balanceOf(alice);
        vm.prank(keeper);
        ex.closeAtMaxWin(id);
        uint256 eq = stake * 5;
        uint256 fees = _max(eq * 100, stake * 10 * 25) / BPS + (stake * 4 * 1000) / BPS;
        assertEq(ex.balanceOf(alice), before + eq - fees);
        _assertSolvent();
    }

    function test_shortMaxWinIsPlusHundred() public {
        uint256 stake = 0.1 ether;
        uint256 id = _open(alice, 0, false, 5, stake);
        assertEq(lens.getPosition(id).position.maxWinBps, 10_000);
        o0.setAll(DOWN_50); // +250% at 5x, capped at +100%
        assertEq(lens.getPosition(id).pnl, int256(stake));
        vm.prank(keeper);
        ex.closeAtMaxWin(id);
        _assertSolvent();
    }

    function test_closeAtMaxWinRevertsBelowCap() public {
        uint256 id = _open(alice, 0, true, 2, 0.1 ether);
        o0.setAll(UP_10);
        vm.expectRevert(LevExchangeBase.NotAtMaxWin.selector);
        ex.closeAtMaxWin(id);
    }

    // -------------------------------------------------------- liquidations

    function test_liquidationPaysKeeper() public {
        uint256 stake = 0.1 ether;
        uint256 id = _open(alice, 0, false, 5, stake);
        o0.setAll(UP_17_5); // -87.5% at 5x short
        assertEq(lens.getPosition(id).action, 1);
        uint256 cash0 = pool.cash();
        vm.prank(keeper);
        ex.liquidate(id);
        int256 pnl = _pnl(stake, 5, false, 0, UP_17_5);
        uint256 left = uint256(int256(stake) + pnl);
        uint256 reward = (left * 2500) / BPS;
        assertEq(ex.balanceOf(keeper), reward);
        uint256 fees = left - reward;
        assertEq(pool.cash(), cash0 + stake - reward - (fees - (fees * 5000) / BPS));
        _assertSolvent();
    }

    function test_liquidateRevertsWhenHealthy() public {
        uint256 id = _open(alice, 0, false, 5, 0.1 ether);
        o0.setAll(UP_10);
        vm.prank(keeper);
        vm.expectRevert(LevExchangeBase.NotLiquidatable.selector);
        ex.liquidate(id);
    }

    function test_liquidationUsesFastPriceNotSpot() public {
        uint256 id = _open(alice, 0, false, 5, 0.1 ether);
        o0.set(UP_17_5 * 3, 0, 0); // a one-block spike in the live price
        vm.prank(keeper);
        vm.expectRevert(LevExchangeBase.NotLiquidatable.selector);
        ex.liquidate(id);
    }

    function test_gapPastZeroLosesOnlyStake() public {
        uint256 stake = 0.1 ether;
        uint256 id = _open(alice, 0, true, 10, stake);
        uint256 bal = ex.balanceOf(alice);
        uint256 cash0 = pool.cash();
        o0.setAll(DOWN_50); // -500% at 10x
        vm.prank(keeper);
        ex.liquidate(id);
        assertEq(ex.balanceOf(alice), bal, "trader loses the stake, nothing more");
        assertEq(ex.balanceOf(keeper), 0);
        assertEq(pool.cash(), cash0 + stake, "pool keeps the whole stake");
        _assertSolvent();
    }

    // --------------------------------------------------- holding fees (#1)

    function test_crowdedSidePaysTriple() public {
        uint256 longId = _open(alice, 0, true, 10, 0.1 ether); // 1 ETH long
        uint256 shortId = _open(bob, 0, false, 5, 0.1 ether); // 0.5 ETH short
        _wait(11 hours);
        // Index grows 0.05%/h for shorts, 0.15%/h for the crowded longs; the first hour is free (10/11 charged).
        uint256 longFee = lens.getPosition(longId).holdFee;
        uint256 shortFee = lens.getPosition(shortId).holdFee;
        assertApproxEqAbs(longFee, (1 ether * 15 * 11 * 10) / (BPS * 11), 10);
        assertApproxEqAbs(shortFee, (0.5 ether * 5 * 11 * 10) / (BPS * 11), 10);
        _close(alice, longId);
        _close(bob, shortId);
        _assertSolvent();
    }

    function test_noHoldingFeeInFirstHour() public {
        uint256 id = _open(alice, 0, true, 2, 0.1 ether);
        _wait(59 minutes);
        assertEq(lens.getPosition(id).holdFee, 0);
    }

    /// The 2x short from the simulator: coin falls 50% over 24 hours, crowded side, our rules.
    function test_simulatorExampleShort() public {
        vm.prank(lp);
        pool.deposit{value: 20 ether}(); // room for a 1 ETH stake
        o0.setLiquidity(4000 ether);
        vm.prank(owner);
        exa.setMarket(0, true, 10, 100 ether);
        uint256 stake = 1 ether;
        uint256 fee = _openFee(stake, 2);
        uint256 id = _open(alice, 0, false, 2, stake);
        o0.setAll(DOWN_50);
        _wait(24 hours);
        uint256 bal = ex.balanceOf(alice);
        _close(alice, id);
        int256 pnl = _pnl(stake, 2, false, 0, DOWN_50); // about +100%, at the +100% short cap
        if (pnl > int256(stake)) pnl = int256(stake);
        uint256 hold = (2 ether * 15 * 24 * 23) / (BPS * 24); // 3x crowded, 23 of 24 hours charged
        uint256 eq = uint256(int256(stake) + pnl) - hold;
        uint256 fees = _max(eq * 100, 2 ether * 25) / BPS + ((uint256(pnl) - hold) * 1000) / BPS;
        uint256 net = ex.balanceOf(alice) - bal;
        assertApproxEqAbs(net, eq - fees, 1e6);
        // Trader nets about +80% of the stake after all fees.
        assertApproxEqRel(net - stake - fee, 0.8 ether, 0.02e18);
        _assertSolvent();
    }

    // ------------------------------------------------------ rug guard

    function test_rugGuardSettlesShortsAtTwentyPercent() public {
        uint256 shortId = _open(alice, 0, false, 2, 0.1 ether);
        uint256 longId = _open(bob, 0, true, 2, 0.1 ether);
        o0.set(-16_200, -16_200, 0); // fast price 80% under slow
        vm.prank(keeper);
        exa.triggerRugGuard(0);

        // New positions wait an hour.
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.MarketLocked.selector);
        ex.open(0, false, 2, 0.1 ether, MIN_TICK);

        LevLens.PositionView memory v = lens.getPosition(shortId);
        assertEq(v.action, 3);
        assertEq(v.pnl, 0.02 ether);
        uint256 bal = ex.balanceOf(alice);
        vm.prank(keeper);
        ex.settleRugged(shortId);
        uint256 eq = 0.12 ether;
        uint256 fees = _max(eq * 100, 0.2 ether * 25) / BPS + (0.02 ether * 1000) / BPS;
        assertEq(ex.balanceOf(alice), bal + eq - fees);

        // Longs keep running and get liquidated normally.
        vm.prank(keeper);
        ex.liquidate(longId);

        _wait(1 hours);
        _open(alice, 0, false, 2, 0.1 ether);
        _assertSolvent();
    }

    function test_rugGuardNeedsARealCrash() public {
        o0.set(-10_000, -10_000, 0); // only -63%
        vm.expectRevert(LevExchangeBase.NoRug.selector);
        exa.triggerRugGuard(0);
    }

    function test_ownerCloseAfterRugAlsoCapped() public {
        uint256 id = _open(alice, 0, false, 2, 0.1 ether);
        o0.set(-20_000, -20_000, 0);
        exa.triggerRugGuard(0);
        _wait(1 minutes);
        uint256 bal = ex.balanceOf(alice);
        _close(alice, id);
        uint256 eq = 0.12 ether;
        uint256 fees = _max(eq * 100, 0.2 ether * 25) / BPS + (0.02 ether * 1000) / BPS;
        assertEq(ex.balanceOf(alice), bal + eq - fees);
    }

    // ------------------------------------------------------ stale feed

    function test_staleFeedSettlesAtLastGoodPrice() public {
        uint256 id = _open(alice, 0, true, 2, 0.1 ether);
        o0.setAll(UP_10);
        exa.refresh(0); // records +10% as the last good slow price
        o0.setFailing(true);
        _wait(1 minutes);
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.OracleDown.selector);
        ex.close(id, MIN_TICK);

        // A keeper keeps pinging the dead feed; the stale clock needs an unbroken run of failures.
        for (uint256 i; i < 7; ++i) {
            exa.refresh(0);
            _wait(100);
        }
        exa.refresh(0);
        _close(alice, id);
        assertEq(exa.openPositionCount(), 0);
        _assertSolvent();
    }

    // ------------------------------------------------------ breaker

    function test_hourlyLossBreaker() public {
        Config memory c = exa.getConfig();
        c.hourlyLossBreakerBps = 500;
        vm.prank(owner);
        exa.setConfig(c);

        uint256 id = _open(alice, 0, true, 10, 0.2 ether);
        o0.setAll(UP_60);
        vm.prank(keeper);
        ex.closeAtMaxWin(id); // pool pays about 0.7 ETH, more than 5% of 8 ETH

        vm.prank(bob);
        vm.expectRevert(LevExchangeBase.BreakerTripped.selector);
        ex.open(1, true, 2, 0.01 ether, MAX_TICK);
        assertEq(lens.quoteOpen(1, true, 2, 0.01 ether).reason, 9);

        _wait(1 hours);
        _open(bob, 1, true, 2, 0.01 ether);
    }

    // ------------------------------------------------------ admin

    function test_configHardLimits() public {
        Config memory c = exa.getConfig();
        c.poolFeeShareBps = 1000; // below the 20% floor
        vm.prank(owner);
        vm.expectRevert(LevExchangeBase.BadConfig.selector);
        exa.setConfig(c);
    }

    function test_pausedMarketStillCloses() public {
        uint256 id = _open(alice, 0, true, 2, 0.1 ether);
        vm.prank(owner);
        exa.setMarket(0, false, 10, 5 ether);
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.MarketClosed.selector);
        ex.open(0, true, 2, 0.1 ether, MAX_TICK);
        _wait(1 minutes);
        _close(alice, id);
    }

    function test_guardianPausesOpens() public {
        address g = makeAddr("guardian");
        vm.prank(owner);
        exa.setGuardian(g);
        vm.prank(g);
        exa.setOpensPaused(true);
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.MarketClosed.selector);
        ex.open(0, true, 2, 0.1 ether, MAX_TICK);
        vm.prank(bob);
        vm.expectRevert(LevExchangeBase.Unauthorized.selector);
        exa.setOpensPaused(false);
    }

    function test_treasuryClaim() public {
        _open(alice, 0, true, 2, 0.1 ether);
        uint256 t = ex.treasuryBalance();
        exa.claimTreasury();
        assertEq(treasury.balance, t);
        assertEq(ex.treasuryBalance(), 0);
    }

    function test_quoteMatchesOpen() public {
        LevLens.Quote memory q = lens.quoteOpen(0, false, 5, 0.1 ether);
        assertEq(q.reason, 0);
        assertEq(q.maxLeverage, 5);
        assertEq(q.maxWinBps, 10_000);
        assertEq(q.fee, _openFee(0.1 ether, 5));
        assertEq(q.netRoom, 2 ether);
        assertEq(lens.quoteOpen(0, false, 10, 0.1 ether).reason, 5);
        assertEq(lens.quoteOpen(0, true, 10, 0.3 ether).reason, 6);
    }

    // ------------------------------------------------------ fuzz

    /// Random opens, price moves and exits never break the books.
    function testFuzz_booksAlwaysBalance(uint256 seed) public {
        uint256[] memory ids = new uint256[](24);
        uint256 n;
        for (uint256 step; step < 40; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 action = seed % 5;
            uint256 m = (seed >> 8) % 3;
            if (action <= 1 && n < ids.length) {
                bool isLong = (seed >> 16) % 2 == 0;
                uint8 lev = [2, 5, 10][(seed >> 24) % 3];
                if (!isLong && lev > 5) lev = 5;
                uint256 stake = 0.001 ether + ((seed >> 32) % 0.05 ether);
                address who = (seed >> 40) % 2 == 0 ? alice : bob;
                vm.prank(who);
                try ex.open(m, isLong, uint8(lev), stake, isLong ? MAX_TICK : MIN_TICK) returns (uint256 id) {
                    ids[n++] = id;
                } catch {}
            } else if (action == 2) {
                int24 t = int24(int256((seed >> 48) % 12_000) - 6000);
                [o0, o1, o2][m].set(t, t, t / 2);
            } else if (n > 0) {
                uint256 k = (seed >> 56) % n;
                uint256 id = ids[k];
                _wait(10 + (seed >> 64) % 3 hours);
                LevLens.PositionView memory v = lens.getPosition(id);
                if (v.position.owner != address(0)) {
                    if (v.action == 1) {
                        vm.prank(keeper);
                        ex.liquidate(id);
                    } else if (v.action == 2) {
                        vm.prank(keeper);
                        ex.closeAtMaxWin(id);
                    } else {
                        vm.prank(v.position.owner);
                        ex.close(id, v.position.isLong ? MIN_TICK : MAX_TICK);
                    }
                }
                ids[k] = ids[--n];
            }
            _assertSolvent();
            // Coverage is checked at open; payouts shrink cash and reservations together, so cash always covers them.
            assertLe(ex.totalMaxWin(), pool.cash(), "every open max win is payable");
        }
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}

/// Regressions for issues found in review.
contract ReviewRegressionTest is Base {
    function test_stuckMaxWinNowSettlesAsLoss() public {
        uint256 id = _open(alice, 0, false, 5, 0.1 ether);
        o0.setAll(DOWN_50);
        _wait(300 hours); // holding fees exceed stake + max win
        assertEq(lens.getPosition(id).action, 2);
        uint256 bal = ex.balanceOf(alice);
        ex.closeAtMaxWin(id);
        assertEq(ex.balanceOf(alice), bal, "nothing left to pay out");
        assertEq(exa.openPositionCount(), 0);
        _assertSolvent();
    }

    function test_netCapCantFlipToOverCapOtherSide() public {
        _open(alice, 0, true, 10, 0.2 ether); // net long 2 ETH at cap 2
        o0.setLiquidity(100 ether); // cap now 0.5 ETH
        vm.prank(bob);
        vm.expectRevert(LevExchangeBase.CoinFull.selector);
        ex.open(0, false, 5, 0.8 ether, MIN_TICK); // would end 2 ETH net short
        // Rebalancing is allowed up to the gross cap per side (2 x 0.5 ETH): 1 ETH of shorts.
        _open(bob, 0, false, 5, 0.2 ether);
        vm.prank(bob);
        vm.expectRevert(LevExchangeBase.CoinFull.selector);
        ex.open(0, false, 5, 0.01 ether, MIN_TICK);
    }

    function test_staleCloseUsesLastFastPrice() public {
        uint256 id = _open(alice, 0, true, 5, 0.1 ether);
        _wait(60);
        o0.set(DOWN_50, DOWN_50, -300); // crash: fast is down 50%, slow only 3%
        exa.refresh(0);
        o0.setFailing(true);
        for (uint256 i; i < 7; ++i) {
            exa.refresh(0);
            _wait(100);
        }
        exa.refresh(0);
        uint256 bal = ex.balanceOf(alice);
        vm.prank(alice);
        ex.close(id, MIN_TICK);
        assertEq(ex.balanceOf(alice), bal, "the crashed long settles as the loss it was");
    }

    function test_lpWithdrawalDoesNotTripBreaker() public {
        uint256 shares = pool.balanceOf(lp) / 8;
        vm.prank(lp);
        pool.requestWithdraw(shares);
        _wait(1 days);
        _open(alice, 0, true, 2, 0.01 ether); // starts the breaker hour
        vm.prank(lp);
        pool.withdraw(0);
        _open(bob, 1, true, 2, 0.01 ether);
    }

    function test_depositDoesNotHideTradingLoss() public {
        Config memory c = exa.getConfig();
        c.hourlyLossBreakerBps = 500;
        vm.prank(owner);
        exa.setConfig(c);
        uint256 id = _open(alice, 0, true, 10, 0.2 ether);
        o0.setAll(UP_60);
        ex.closeAtMaxWin(id); // pool pays about 0.7 ETH
        vm.prank(lp);
        pool.deposit{value: 20 ether}(); // cash is now far above where it started
        vm.prank(bob);
        vm.expectRevert(LevExchangeBase.BreakerTripped.selector);
        ex.open(1, true, 2, 0.01 ether, MAX_TICK);
    }
}
