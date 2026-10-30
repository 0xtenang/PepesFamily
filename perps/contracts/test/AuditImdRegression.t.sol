// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LevExchange} from "../src/LevExchange.sol";
import {LevExchangeAdmin} from "../src/LevExchangeAdmin.sol";
import {LevExchangeBase} from "../src/LevExchangeBase.sol";
import {LevPool} from "../src/LevPool.sol";
import {LevLens} from "../src/LevLens.sol";
import {RiskConfig} from "../src/LevTypes.sol";
import {ILevPool, ILevExchange, ILevNav} from "../src/interfaces/ILevPool.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/// @notice The IMD Swarm audit of 19ac59a (job 1425b92e): its four proofs, kept as regression tests.
contract AuditImdRegressionTest is Test {
    LevPool pool;
    LevExchange ex;
    LevExchangeAdmin exa;
    LevLens lens;
    MockOracle o0;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    function _setUp(RiskConfig memory r, uint256 liq, uint256 netCap, uint256 lpCash) internal {
        vm.warp(1_750_000_000);
        pool = new LevPool{value: 0.001 ether}(owner);
        ex = new LevExchange(ILevPool(address(pool)), owner, makeAddr("treasury"), address(new LevExchangeAdmin()));
        exa = LevExchangeAdmin(payable(address(ex)));
        lens = new LevLens(ex);
        vm.startPrank(owner);
        pool.setExchange(ILevExchange(address(ex)));
        pool.setNavSource(ILevNav(address(lens)));
        exa.setRiskConfig(r);
        o0 = new MockOracle(0, liq);
        exa.listMarket(o0, 10, netCap);
        vm.stopPrank();
        vm.deal(lp, 100 ether);
        vm.prank(lp);
        pool.deposit{value: lpCash}();
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        ex.deposit{value: 10 ether}();
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        ex.deposit{value: 10 ether}();
    }

    function _defaultRisk() internal pure returns (RiskConfig memory) {
        return RiskConfig({
            openBandSpotTicks: 488,
            openBandTrendTicks: 1823,
            pumpBandTicks: 4055,
            spreadBaseBps: 10,
            spreadImpactBps: 20_000,
            spreadMaxBps: 300,
            sizeTier5xBps: 10,
            sizeTier2xBps: 25,
            hourlyGrowthBps: 5000,
            platformSizeBps: 30_000
        });
    }

    function _neutralRisk() internal pure returns (RiskConfig memory) {
        return RiskConfig({
            openBandSpotTicks: 30_000,
            openBandTrendTicks: 30_000,
            pumpBandTicks: 30_000,
            spreadBaseBps: 0,
            spreadImpactBps: 0,
            spreadMaxBps: 0,
            sizeTier5xBps: 500,
            sizeTier2xBps: 500,
            hourlyGrowthBps: 60_000,
            platformSizeBps: 100_000
        });
    }

    /// H-1: a stop-loss armed one tick under the lagging fast price, after the live price crashed 30%, used to exit
    /// at fast - 5% (the clamp) and the pool paid the gap. Now the trigger waits while live and fast are apart, and
    /// once it fires it never pays more than a close at the same prices.
    function test_IMD_H1_stopLossCantExitACrashAtTheLaggingPrice() public {
        _setUp(_defaultRisk(), 4000 ether, 100 ether, 50 ether);
        vm.prank(alice);
        uint256 id = ex.open(0, true, 5, 1 ether, type(int24).max);
        vm.warp(block.timestamp + 60);

        o0.set(-3567, 0, 0); // live -30%, fast not moved yet
        vm.prank(alice);
        exa.setTriggers(id, false, 0, true, -1);
        o0.set(-3567, -1, 0);

        // live and fast 3566 ticks apart: the trigger waits, for the owner and for keepers alike
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.PriceBand.selector);
        ex.closeByTrigger(id);
        vm.prank(keeper);
        vm.expectRevert(LevExchangeBase.PriceBand.selector);
        ex.closeByTrigger(id);
        assertEq(lens.getPosition(id).action, lens.ACTION_NONE(), "lens must not report a trigger that would revert");

        // the fast price catches up to within the band: the trigger fires, and pays no more than a close
        o0.set(-1200, -800, 0);
        uint256 b0 = ex.balanceOf(alice);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        ex.close(id, type(int24).min);
        uint256 viaClose = ex.balanceOf(alice) - b0;
        uint256 poolAfterClose = pool.cash();
        vm.revertToState(snap);
        assertEq(lens.getPosition(id).action, lens.ACTION_STOP_LOSS());
        vm.prank(alice);
        ex.closeByTrigger(id);
        assertLe(ex.balanceOf(alice) - b0, viaClose, "a trigger close must not pay more than a close");
        assertGe(pool.cash(), poolAfterClose, "the pool must not lose more through the trigger path");
    }

    /// H-1, the same for a short: a 30% pump the fast price hasn't caught.
    function test_IMD_H1_shortStopLossWaitsOnAPump() public {
        _setUp(_defaultRisk(), 4000 ether, 100 ether, 50 ether);
        vm.prank(alice);
        uint256 id = ex.open(0, false, 5, 1 ether, type(int24).min);
        vm.warp(block.timestamp + 60);
        o0.set(2624, 0, 0);
        vm.prank(alice);
        exa.setTriggers(id, false, 0, true, 1);
        o0.set(2624, 1, 0);
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.PriceBand.selector);
        ex.closeByTrigger(id);
    }

    /// M-1: a bankrupt long's loss past its stake no longer offsets another long's win in the value withdrawals pay.
    function test_IMD_M1_bankruptLoserDoesNotInflateNav() public {
        _setUp(_neutralRisk(), 4000 ether, 5 ether, 8 ether);
        vm.prank(alice);
        ex.open(0, true, 2, 0.5 ether, type(int24).max);
        o0.setAll(6932);
        vm.warp(block.timestamp + 60);
        vm.prank(bob);
        uint256 b = ex.open(0, true, 10, 0.1 ether, type(int24).max);
        o0.setAll(2000); // bob is 0.389 ETH down on a 0.1 ETH stake
        vm.warp(block.timestamp + 60);
        uint256 before = pool.nav();
        ex.liquidate(b);
        assertLe(before, pool.nav(), "nav overstated while a bankrupt long is open");
    }

    /// M-1, the other direction (the old "capped winners" limit): a winner past its own max win counts at its cap,
    /// so a depositor can't buy in cheap just before it is closed.
    function test_IMD_M1_winnerPastItsCapCountsAtItsCap() public {
        _setUp(_neutralRisk(), 4000 ether, 5 ether, 8 ether);
        vm.prank(alice);
        uint256 a = ex.open(0, true, 10, 0.1 ether, type(int24).max); // max win 0.4 ETH
        vm.prank(bob);
        ex.open(0, true, 1, 1 ether, type(int24).max);
        o0.setAll(4700); // alice far past her cap, bob up ~60%
        vm.warp(block.timestamp + 60);
        (uint256 lowBefore, uint256 highBefore) = pool.navRange();
        vm.prank(keeper);
        ex.closeAtMaxWin(a);
        (uint256 lowAfter, uint256 highAfter) = pool.navRange();
        // closing at max win pays exactly what the valuation already counted (plus fees the pool keeps)
        assertGe(lowAfter, lowBefore, "low value rose across a max-win close: the winner was counted past its cap");
        assertGe(highAfter, highBefore);
    }

    /// M-2: one open position on a coin whose feed died froze every LP deposit and withdrawal. Once the feed is
    /// stale (the exchange settles at the last good price), the pool values it there instead.
    function test_IMD_M2_staleMarketDoesNotFreezeThePool() public {
        _setUp(_neutralRisk(), 400 ether, 5 ether, 20 ether);
        vm.prank(alice);
        uint256 id = ex.open(0, true, 1, 0.01 ether, type(int24).max);
        vm.prank(alice);
        exa.addMargin(id, 1 ether);

        o0.setFailing(true);
        exa.refresh(0);
        // before staleSeconds, the valuation still pauses
        (,, bool blocked) = lens.liabilityRange();
        assertTrue(blocked, "a freshly failed feed must pause the valuation");
        for (uint256 i; i < 864; ++i) {
            vm.warp(vm.getBlockTimestamp() + 100);
            exa.refresh(0);
        }
        (,, blocked) = lens.liabilityRange();
        assertFalse(blocked, "a stale market should be valued at its last good price, not block the pool");
        uint256 shares = pool.balanceOf(lp);
        vm.prank(lp);
        pool.requestWithdraw(shares);
        vm.deal(bob, 10 ether);
        vm.prank(bob);
        pool.deposit{value: 1 ether}();

        // without pings the stale run lapses and the valuation pauses again, as the exchange's settlement does
        vm.warp(vm.getBlockTimestamp() + 1000);
        (,, blocked) = lens.liabilityRange();
        assertTrue(blocked);
    }

    /// L-1: the owner gets no keeper share for clearing their own position at max win...
    function test_IMD_L1_noKeeperShareForOwnMaxWin() public {
        _setUp(_neutralRisk(), 4000 ether, 5 ether, 8 ether);
        vm.prank(alice);
        uint256 id = ex.open(0, true, 10, 0.1 ether, type(int24).max);
        o0.setAll(4700);
        vm.warp(block.timestamp + 60);
        uint256 b0 = ex.balanceOf(alice);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        ex.close(id, type(int24).min);
        uint256 viaClose = ex.balanceOf(alice) - b0;
        vm.revertToState(snap);
        vm.prank(alice);
        ex.closeAtMaxWin(id);
        assertEq(ex.balanceOf(alice) - b0, viaClose, "owner got a keeper share via closeAtMaxWin");
        // a keeper still gets one
        vm.revertToState(snap);
        vm.prank(keeper);
        ex.closeAtMaxWin(id);
        assertGt(ex.balanceOf(keeper), 0);
    }

    /// ...or for liquidating their own position.
    function test_IMD_L1_noKeeperShareForOwnLiquidation() public {
        _setUp(_neutralRisk(), 4000 ether, 5 ether, 8 ether);
        vm.prank(alice);
        uint256 id = ex.open(0, true, 10, 0.4 ether, type(int24).max);
        o0.setAll(-890); // -8.5% at 10x: equity just under 15% of the stake
        vm.warp(block.timestamp + 60);
        uint256 b0 = ex.balanceOf(alice);
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        ex.liquidate(id);
        assertGt(ex.balanceOf(keeper), 0, "precondition: liquidation leaves equity for a reward");
        vm.revertToState(snap);
        vm.prank(alice);
        ex.liquidate(id);
        assertEq(ex.balanceOf(alice), b0, "owner got a keeper share via liquidate");
    }

    /// M-1 makes the valuation read every open position, so their number is capped: at the cap an LP deposit
    /// still costs well under a block.
    function test_IMD_M1_openPositionsCappedAndValuationFits() public {
        _setUp(_neutralRisk(), 40_000 ether, 500 ether, 80 ether);
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        ex.deposit{value: 50 ether}();
        uint256 cap = ex.MAX_OPEN_POSITIONS();
        for (uint256 i; i < cap; ++i) {
            vm.prank(alice);
            ex.open(0, i % 2 == 0, 2, 0.01 ether, i % 2 == 0 ? type(int24).max : type(int24).min);
        }
        (uint8 reason,) = _quoteReason();
        assertEq(reason, lens.QUOTE_POOL_FULL());
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.PoolFull.selector);
        ex.open(0, true, 2, 0.01 ether, type(int24).max);

        vm.deal(bob, 10 ether);
        uint256 g = gasleft();
        vm.prank(bob);
        pool.deposit{value: 1 ether}();
        uint256 used = g - gasleft();
        emit log_named_uint("deposit gas with the maximum open positions", used);
        assertLt(used, 20_000_000);
    }

    function _quoteReason() internal view returns (uint8 reason, uint256 unused) {
        reason = lens.quoteOpen(0, true, 2, 0.01 ether).reason;
        unused = 0;
    }
}
