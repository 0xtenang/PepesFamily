// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LevExchange} from "../src/LevExchange.sol";
import {LevExchangeAdmin} from "../src/LevExchangeAdmin.sol";
import {LevPool} from "../src/LevPool.sol";
import {LevLens} from "../src/LevLens.sol";
import {RiskConfig} from "../src/LevTypes.sol";
import {ILevPool, ILevExchange, ILevNav} from "../src/interfaces/ILevPool.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/// @notice The IMD Swarm audit of 7379f64 (job 964f33f1), Long/Short findings: its proofs, kept as regression tests.
contract AuditImd2RegressionTest is Test {
    LevPool pool;
    LevExchange ex;
    LevExchangeAdmin exa;
    LevLens lens;
    MockOracle o;

    address owner = makeAddr("owner");
    address lp = makeAddr("lp");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_750_000_000);
        pool = new LevPool{value: 0.001 ether}(owner);
        ex = new LevExchange(ILevPool(address(pool)), owner, makeAddr("treasury"), address(new LevExchangeAdmin()));
        exa = LevExchangeAdmin(payable(address(ex)));
        lens = new LevLens(ex);
        vm.startPrank(owner);
        pool.setExchange(ILevExchange(address(ex)));
        pool.setNavSource(ILevNav(address(lens)));
        exa.setRiskConfig(
            RiskConfig({
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
            })
        );
        o = new MockOracle(0, 400 ether);
        exa.listMarket(o, 10, 5 ether);
        vm.stopPrank();
        vm.deal(lp, 100 ether);
        vm.prank(lp);
        pool.deposit{value: 8 ether}();
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        ex.deposit{value: 10 ether}();
    }

    /// M-3: a one-block push of the coin's live price used to reprice a matured withdrawal (mark and stress fee)
    /// with nothing the LP could do. The LP's minimum payout now makes that withdrawal fail; once the push is gone,
    /// the same floor passes and the LP gets the honest value.
    function test_IMD2_M3_minPayoutRefusesAPushedWithdrawal() public {
        vm.prank(alice);
        ex.open(0, true, 10, 0.2 ether, type(int24).max); // max win 0.8 ETH
        uint256 shares = pool.balanceOf(lp) / 2; // half: the other half covers the open max win
        vm.prank(lp);
        pool.requestWithdraw(shares);
        (, uint256 snapshot,) = pool.withdrawRequests(lp);
        vm.warp(block.timestamp + pool.withdrawCooldown());
        (uint256 low,) = pool.navRange();
        uint256 honest = (shares * low) / pool.totalSupply();
        if (honest > snapshot) honest = snapshot;
        uint256 floor = (honest * 995) / 1000;

        o.set(4000, 0, 0); // live price +49% for one block, averages unchanged
        vm.prank(lp);
        vm.expectRevert(LevPool.BelowMinimum.selector);
        pool.withdraw(floor);

        o.set(0, 0, 0);
        uint256 b0 = lp.balance;
        vm.prank(lp);
        pool.withdraw(floor);
        assertEq(lp.balance - b0, honest, "paid the honest value");
    }

    /// L-4: the deposit price credited the close fee of a position that was already bankrupt and will pay none.
    function test_IMD2_L4_bankruptPositionEarnsNoFeeCredit() public {
        vm.prank(alice);
        uint256 id = ex.open(0, true, 10, 0.2 ether, type(int24).max); // size 2 ETH
        vm.warp(block.timestamp + 60);
        o.setAll(-1625); // about -15%: equity below zero
        (, uint256 highBefore) = pool.navRange();
        vm.prank(makeAddr("keeper"));
        ex.liquidate(id);
        (uint256 lowAfter, uint256 highAfter) = pool.navRange();
        assertEq(lowAfter, highAfter, "no positions left");
        assertLe(highBefore, highAfter, "deposit-side value overstated before the liquidation");
    }

    /// L-4, a healthy position: the deposit price never credits more than the pool ends up booking when the
    /// position is closed (here by its owner, at the price the valuation used).
    function test_IMD2_L4_feeCreditIsALowerBound() public {
        vm.prank(alice);
        uint256 id = ex.open(0, true, 5, 0.2 ether, type(int24).max);
        vm.warp(block.timestamp + 3 hours); // past the free holding time
        o.setAll(-300);
        (, uint256 highBefore) = pool.navRange();
        vm.prank(alice);
        ex.close(id, type(int24).min);
        (, uint256 highAfter) = pool.navRange();
        assertLe(highBefore, highAfter, "deposit-side value credited fees that didn't arrive");
    }
}
