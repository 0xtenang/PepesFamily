// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {LevExchangeBase} from "../src/LevExchangeBase.sol";
import {LevLens} from "../src/LevLens.sol";
import {RiskConfig} from "../src/LevTypes.sol";

/// @notice The 2026-10-30 risk rules at their defaults: price bands, the pump band, the size-based spread, size
///         tiers, the hourly growth limit, the platform cap and the stress-based withdrawal fee. Coins in Base have
///         400 ETH of liquidity and a 2 ETH cap (0.5% of it); the pool holds about 8 ETH.
contract RiskRulesTest is Base {
    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        exa.setRiskConfig(_defaultRisk());
    }

    function _setRisk(RiskConfig memory r) internal {
        vm.prank(owner);
        exa.setRiskConfig(r);
    }

    // ------------------------------------------------------------ price bands

    function test_noOpensWhileSpotIsPushed() public {
        o0.set(500, 0, 0); // spot 5.1% over the fast price
        assertEq(lens.quoteOpen(0, true, 2, 0.1 ether).reason, lens.QUOTE_PRICE_BAND());
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.PriceBand.selector);
        ex.open(0, true, 2, 0.1 ether, MAX_TICK);
        o0.set(400, 0, 0); // within 5%
        _open(alice, 0, true, 2, 0.1 ether);
    }

    function test_noOpensMidPump() public {
        o0.set(1900, 1900, 0); // fast 21% over slow
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.PriceBand.selector);
        ex.open(0, false, 2, 0.1 ether, MIN_TICK);
    }

    function test_closesStillWorkOutsideTheBands() public {
        uint256 id = _open(alice, 0, true, 2, 0.1 ether);
        _wait(60);
        o0.set(2500, 2500, 0);
        _close(alice, id);
        _assertSolvent();
    }

    // -------------------------------------------------------------- pump band

    /// A long's exit is priced at most 50% (4055 ticks) over the slow price, however high spot and fast are.
    function test_longExitCappedAtPumpBand() public {
        uint256 stake = 0.1 ether;
        uint256 id = _open(alice, 0, true, 4, stake);
        int24 entry = lens.getPosition(id).position.entryTick;
        _wait(60);
        o0.set(6000, 6000, 0); // +82%, slow unchanged
        uint256 before = ex.balanceOf(alice);
        (, int24 exitTick) = lens.quoteClose(id);
        int24 spread = entry; // opened at tick 0, so the entry is the spread
        assertEq(exitTick, 4055 - spread, "exit is the band minus the spread");
        _close(alice, id);
        int256 pnl = _pnl(stake, 4, true, entry, exitTick);
        uint256 eq = stake + uint256(pnl);
        uint256 fee = _max(eq * 100, stake * 4 * 25) / BPS + (uint256(pnl) * 1000) / BPS;
        assertApproxEqAbs(ex.balanceOf(alice) - before, eq - fee, 1e6);
        _assertSolvent();
    }

    function test_maxWinWaitsForThePumpToLast() public {
        uint256 id = _open(alice, 0, true, 2, 0.1 ether);
        _wait(60);
        o0.set(20_000, 20_000, 0); // +639%: 2x would be +1278%, past the 400% max win
        assertEq(lens.getPosition(id).action, lens.ACTION_NONE());
        vm.expectRevert(LevExchangeBase.NotAtMaxWin.selector);
        ex.closeAtMaxWin(id);
        o0.set(20_000, 20_000, 20_000); // the slow price caught up
        assertEq(lens.getPosition(id).action, lens.ACTION_MAX_WIN());
        vm.prank(keeper);
        ex.closeAtMaxWin(id);
        _assertSolvent();
    }

    // ----------------------------------------------------------------- spread

    /// Spread = 10 bps + 2 x size / liquidity: 0.2 ETH of size on 400 ETH is 10 bps more, 20 ticks in all.
    function test_spreadOnOpenAndClose() public {
        LevLens.Quote memory q = lens.quoteOpen(0, true, 2, 0.1 ether);
        assertEq(q.entryTick, 20);
        uint256 id = _open(alice, 0, true, 2, 0.1 ether);
        assertEq(lens.getPosition(id).position.entryTick, 20, "quote matches open");
        uint256 sid = _open(bob, 0, false, 2, 0.1 ether);
        assertEq(lens.getPosition(sid).position.entryTick, -20, "a short enters lower");
        _wait(60);
        (bool ok, int24 exitTick) = lens.quoteClose(id);
        assertTrue(ok);
        assertEq(exitTick, -20, "a long exits lower");
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.PriceMoved.selector);
        ex.close(id, -19);
        vm.prank(alice);
        ex.close(id, exitTick);
        _assertSolvent();
    }

    function test_spreadIsCapped() public {
        RiskConfig memory r = _defaultRisk();
        r.spreadMaxBps = 15;
        _setRisk(r);
        assertEq(lens.quoteOpen(0, true, 2, 0.1 ether).entryTick, 15);
    }

    // ------------------------------------------------------------- size tiers

    /// Above 0.1% of liquidity (0.4 ETH of size) at most 5x; above 0.25% (1 ETH) at most 2x.
    function test_leverageFallsWithSize() public {
        assertEq(lens.quoteOpen(0, true, 0, 0.04 ether).maxLeverage, 10);
        assertEq(lens.quoteOpen(0, true, 0, 0.1 ether).maxLeverage, 5);
        assertEq(lens.quoteOpen(0, true, 0, 0.3 ether).maxLeverage, 3); // 3x is 0.9 ETH: under the 2x tier
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.LeverageNotAllowed.selector);
        ex.open(0, true, 10, 0.1 ether, MAX_TICK);
        _open(alice, 0, true, 5, 0.1 ether);
    }

    // ---------------------------------------------------------- growth limits

    /// New size per coin per hour: at most 50% of its 2 ETH cap.
    function test_hourlyGrowthLimit() public {
        _open(alice, 0, true, 5, 0.1 ether);
        _open(bob, 0, true, 5, 0.1 ether); // 1 ETH this hour: the limit
        assertEq(lens.quoteOpen(0, true, 5, 0.02 ether).reason, lens.QUOTE_GROWING_TOO_FAST());
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.GrowingTooFast.selector);
        ex.open(0, true, 5, 0.02 ether, MAX_TICK);
        _wait(3601);
        _open(alice, 0, true, 5, 0.02 ether);
    }

    function test_platformCap() public {
        RiskConfig memory r = _neutralRisk();
        r.platformSizeBps = 5000; // open size across coins at most half of pool cash (~4 ETH)
        _setRisk(r);
        _open(alice, 0, true, 10, 0.2 ether);
        _open(alice, 1, true, 10, 0.2 ether);
        assertEq(lens.quoteOpen(2, true, 10, 0.01 ether).reason, lens.QUOTE_POOL_FULL());
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.PoolFull.selector);
        ex.open(2, true, 10, 0.01 ether, MAX_TICK);
        assertEq(ex.totalOpenSize(), 4 ether);
    }

    // --------------------------------------------------------- withdrawal fee

    function test_withdrawalFeeWhileTradersWin() public {
        assertEq(pool.withdrawFeeBps(), 0);
        _open(alice, 0, true, 5, 0.2 ether);
        _wait(60);
        o0.set(6932, 6932, 0); // 2x: the long is at its 0.8 ETH max win, ~10% of the pool
        assertEq(pool.withdrawFeeBps(), 150);
        uint256 shares = pool.balanceOf(lp);
        uint256 value = pool.previewRedeem(shares);
        vm.prank(lp);
        pool.requestWithdraw(shares);
        _wait(1 days);
        uint256 before = lp.balance;
        uint256 cashBefore = pool.cash();
        vm.prank(lp);
        pool.withdraw();
        uint256 got = lp.balance - before;
        assertEq(got, value - (value * 150) / BPS);
        assertEq(cashBefore - pool.cash(), got, "the fee stays in the pool");
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
