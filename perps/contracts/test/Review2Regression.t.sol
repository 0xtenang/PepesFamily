// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {LevExchangeBase} from "../src/LevExchangeBase.sol";
import {LevLens} from "../src/LevLens.sol";
import {LevPool} from "../src/LevPool.sol";
import {Config} from "../src/LevTypes.sol";

/// Regressions for the second review (SECURITY_REVIEW.md): one test pins each fix.
contract Review2RegressionTest is Base {
    function _deep() internal {
        o0.setLiquidity(4000 ether);
        vm.prank(owner);
        exa.setMarket(0, true, 10, 100 ether);
    }

    /// F1: while a rug is unsettled, LP deposits and withdraw requests wait.
    function test_F1_lpActionsWaitForRugSettlement() public {
        uint256 shortId = _open(alice, 0, false, 5, 0.1 ether);
        o0.set(-20_000, -20_000, -3900);
        exa.triggerRugGuard(0);
        address eve = makeAddr("eve");
        vm.deal(eve, 10 ether);
        vm.prank(eve);
        vm.expectRevert(LevPool.ValuationPaused.selector);
        pool.deposit{value: 1 ether}();
        uint256 shares = pool.balanceOf(lp);
        vm.prank(lp);
        vm.expectRevert(LevPool.ValuationPaused.selector);
        pool.requestWithdraw(shares);
        ex.settleRugged(shortId);
        o0.setAll(-20_000); // the crash is over and priced in
        vm.prank(eve);
        pool.deposit{value: 1 ether}();
    }

    /// F2: a long can't be stacked against an offsetting short past twice the net cap per side.
    function test_F2_grossCapPerSide() public {
        // cap = min(5, 0.5% of 400) = 2 ETH net, so 4 ETH gross per side.
        _open(alice, 0, true, 10, 0.2 ether); // long 2
        _open(bob, 0, false, 5, 0.4 ether); // short 2, net 0
        _open(alice, 0, true, 10, 0.2 ether); // long 4
        _open(bob, 0, false, 5, 0.4 ether); // short 4
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.CoinFull.selector);
        ex.open(0, true, 10, 0.01 ether, MAX_TICK); // net is 0, but the long side is full
    }

    /// F4: the stale fallback needs an unbroken run of failed reads that is still going.
    function test_F4_staleNeedsUnbrokenFailures() public {
        uint256 id = _open(alice, 0, true, 2, 0.1 ether);
        o0.setFailing(true);
        exa.refresh(0); // marks the feed down
        _wait(700); // nobody pings for longer than the gap
        exa.refresh(0); // this restarts the run
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.OracleDown.selector);
        ex.close(id, MIN_TICK);
        // A feed that recovered quietly and fails for one block can't settle at an old price either.
        o0.setFailing(false);
        _wait(30);
        o0.setFailing(true);
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.OracleDown.selector);
        ex.close(id, MIN_TICK);
    }

    /// F8: a depositor pays for holding fees the pool is already owed.
    function test_F8_depositPaysForFeesOwed() public {
        _deep();
        uint256 id = _open(alice, 0, true, 10, 0.5 ether); // 5 ETH crowded long: 0.15%/h of size
        _wait(10 hours);
        address eve = makeAddr("eve");
        vm.deal(eve, 10 ether);
        vm.prank(eve);
        uint256 shares = pool.deposit{value: 1 ether}();
        _close(alice, id); // the pool collects the holding fees
        assertLe(pool.previewRedeem(shares), 1.0005 ether, "no windfall from fees owed before the deposit");
    }

    /// F9: LPs can always take out cash that isn't reserved for max wins, even when coverage is full.
    function test_F9_lpCanExitWhileCoverageIsFull() public {
        _deep();
        _open(alice, 0, true, 10, 0.99 ether); // reserves about 4 ETH = 50% of cash
        uint256 shares = pool.balanceOf(lp) / 4; // about 2 ETH
        vm.prank(lp);
        pool.requestWithdraw(shares);
        _wait(1 days);
        vm.prank(lp);
        pool.withdraw(0);
        assertGe(pool.cash(), ex.totalMaxWin(), "every reserved max win stays payable");
    }

    /// F10: a short can't take its full max win while a rug the guard hasn't caught yet is under way.
    function test_F10_shortsWaitForRugGuard() public {
        uint256 id = _open(alice, 0, false, 5, 0.1 ether);
        _wait(30); // past the minimum hold
        o0.set(-20_000, -2300, 0); // spot crashed 86%; fast is down 20%: the short's +100% max win
        assertEq(lens.getPosition(id).action, 0, "keepers aren't sent to close it");
        vm.expectRevert(LevExchangeBase.RugInProgress.selector);
        ex.closeAtMaxWin(id);
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.RugInProgress.selector);
        ex.close(id, MAX_TICK);
        o0.set(-20_000, -20_000, 0);
        exa.triggerRugGuard(0);
        ex.settleRugged(id); // settles at the +20% cap
    }

    /// F13: an open that the fast price would liquidate at once is refused, and the quote says so.
    function test_F13_noInstantlyLiquidatableOpens() public {
        o0.set(900, 0, 0); // spot 9.4% above fast
        assertEq(lens.quoteOpen(0, true, 10, 0.1 ether).reason, 10);
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.WouldLiquidate.selector);
        ex.open(0, true, 10, 0.1 ether, MAX_TICK);
    }

    /// F14: closing a position yourself pays what is left, even below the liquidation level.
    function test_F14_ownCloseBelowLiquidationLevelPaysLeftover() public {
        uint256 id = _open(alice, 0, true, 10, 0.1 ether);
        o0.setAll(-890); // about -8.5%: equity about 14% of stake
        _wait(30);
        uint256 bal = ex.balanceOf(alice);
        _close(alice, id);
        assertGt(ex.balanceOf(alice), bal, "the trader gets the leftover equity minus fees");
    }

    /// F15: once the loss breaker trips, new positions wait a full hour, even across the window boundary.
    function test_F15_breakerPausesAFullHour() public {
        Config memory c = exa.getConfig();
        c.hourlyLossBreakerBps = 500;
        vm.prank(owner);
        exa.setConfig(c);
        uint256 id = _open(alice, 0, true, 10, 0.2 ether); // starts the breaker window
        _wait(59 minutes);
        o0.setAll(UP_60);
        vm.prank(keeper);
        ex.closeAtMaxWin(id); // trips the breaker one minute before the window ends
        _wait(2 minutes); // a new window has started
        vm.prank(bob);
        vm.expectRevert(LevExchangeBase.BreakerTripped.selector);
        ex.open(1, true, 2, 0.01 ether, MAX_TICK);
        _wait(1 hours);
        _open(bob, 1, true, 2, 0.01 ether);
    }

    /// F31: the LP withdraw cooldown can't be set below an hour.
    function test_F31_cooldownFloor() public {
        vm.prank(owner);
        vm.expectRevert(LevPool.BadValue.selector);
        pool.setWithdrawCooldown(0);
    }

    /// F32: the owner can't freeze exits with an endless stale window or rug lock.
    function test_F32_configBoundsKeepExitsOpen() public {
        Config memory c = exa.getConfig();
        c.staleSeconds = 2 hours;
        vm.prank(owner);
        vm.expectRevert(LevExchangeBase.BadConfig.selector);
        exa.setConfig(c);
        c = exa.getConfig();
        c.rugLockSeconds = 2 days;
        vm.prank(owner);
        vm.expectRevert(LevExchangeBase.BadConfig.selector);
        exa.setConfig(c);
    }

    /// F34: the lens reports no action for a down feed that isn't stale yet.
    function test_F34_lensMatchesStaleRule() public {
        uint256 id = _open(alice, 0, true, 10, 0.1 ether);
        o0.setAll(-2000);
        exa.refresh(0); // last good fast price: deep under water
        o0.setFailing(true);
        assertEq(lens.getPosition(id).action, 0);
        for (uint256 i; i < 7; ++i) {
            exa.refresh(0);
            _wait(100);
        }
        exa.refresh(0);
        assertEq(lens.getPosition(id).action, 1);
    }

    /// F35: the guardian can pause but not undo the owner's pause.
    function test_F35_guardianCantUnpause() public {
        address g = makeAddr("guardian");
        vm.prank(owner);
        exa.setGuardian(g);
        vm.prank(owner);
        exa.setOpensPaused(true);
        vm.prank(g);
        vm.expectRevert(LevExchangeBase.Unauthorized.selector);
        exa.setOpensPaused(false);
    }

    /// F38: a holding-fee change doesn't apply to time that already passed.
    function test_F38_feeChangeNotRetroactive() public {
        uint256 id = _open(alice, 0, true, 10, 0.1 ether); // 1 ETH size, crowded: 0.15%/h
        _wait(5 hours);
        uint256 before = lens.getPosition(id).holdFee;
        Config memory c = exa.getConfig();
        c.holdRateBpsPerHour = 50;
        vm.prank(owner);
        exa.setConfig(c);
        assertApproxEqAbs(lens.getPosition(id).holdFee, before, 10);
    }

    /// Critic (high): pool value also marks positions at the live price, so LPs can't act on a move the 60 s
    /// average hasn't caught up with.
    function test_navMarksAtSpotToo() public {
        _deep();
        _open(alice, 0, true, 2, 0.5 ether);
        (uint256 low0,) = pool.navRange();
        o0.set(UP_17_5, 0, 0); // a one-block jump: spot up 17.5%, both averages unchanged
        (uint256 low1,) = pool.navRange();
        assertApproxEqRel(low0 - low1, 0.175 ether, 0.01e18, "withdrawals already price in the winner");
    }

    /// Critic (medium): whoever clears a max win gets a share of its fees.
    function test_maxWinCloserIsPaid() public {
        uint256 id = _open(alice, 0, true, 10, 0.1 ether);
        o0.setAll(UP_60);
        vm.prank(keeper);
        ex.closeAtMaxWin(id);
        assertGt(ex.balanceOf(keeper), 0);
        _assertSolvent();
    }
}
