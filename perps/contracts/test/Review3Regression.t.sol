// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {LevExchangeBase} from "../src/LevExchangeBase.sol";

/// @notice Regression tests for the 2026-10-30 review of the risk rules and trader tools (SECURITY_REVIEW.md,
///         round 3). Each was first written as a probe that proved the issue.
contract Review3RegressionTest is Base {
    /// R3-1 (High): a trigger set at a level already reached turned closeByTrigger into a close at the lagging fast
    /// price. Such levels are refused, and a trigger exit counts the live price up to the 5% open band.
    function test_R3_1_triggerCantBeAlreadyHit() public {
        uint256 id = _open(alice, 0, true, 5, 0.1 ether);
        _wait(60);
        o0.set(-2000, -200, 0); // spot crashed ~18%, fast -2%
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.BadConfig.selector);
        exa.setTriggers(id, true, type(int24).min, false, 0);
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.BadConfig.selector);
        exa.setTriggers(id, false, 0, true, 0); // a stop above the fast price is already hit
    }

    function test_R3_1_triggerExitCountsTheLivePrice() public {
        uint256 id = _open(alice, 0, true, 5, 0.1 ether);
        vm.prank(alice);
        exa.setTriggers(id, false, 0, true, -100); // stop at -1%
        _wait(60);
        o0.set(-2000, -200, 0); // the stop fires on fast; spot is far lower
        uint256 snap = vm.snapshotState();
        uint256 b0 = ex.balanceOf(alice);
        _close(alice, id);
        uint256 viaClose = ex.balanceOf(alice) - b0;
        vm.revertToState(snap);
        vm.prank(keeper);
        ex.closeByTrigger(id);
        uint256 viaTrigger = ex.balanceOf(alice) - b0;
        // neutral bands in Base (30k ticks): the live price counts in full, so the trigger exit is no better
        assertLe(viaTrigger, viaClose);
        _assertSolvent();
    }

    function test_R3_1_ownerGetsNoKeeperShare() public {
        uint256 id = _open(alice, 0, true, 2, 0.1 ether);
        vm.prank(alice);
        exa.setTriggers(id, true, 953, false, 0);
        _wait(60);
        o0.setAll(1000);
        uint256 treasury0 = ex.treasuryBalance();
        vm.prank(alice);
        ex.closeByTrigger(id);
        assertGt(ex.treasuryBalance(), treasury0, "the whole fee share stays with the treasury");
        _assertSolvent();
    }

    /// R3-2 (Medium): opens counted toward the hourly growth limit even after closing, so one trader could open and
    /// close a coin's allowance and block it for an hour. A position opened this hour gives its share back on close.
    function test_R3_2_closingFreesTheGrowthAllowance() public {
        vm.prank(owner);
        exa.setRiskConfig(_defaultRisk());
        uint256 id = _open(bob, 0, true, 5, 0.2 ether); // 1 ETH: the coin's whole hourly allowance
        _wait(10);
        _close(bob, id);
        _open(alice, 0, true, 2, 0.01 ether);
    }

    /// R3-3 (Low): margin on one position raised the side's "all stakes lost" floor for every position on it, so a
    /// loss past another position's own stake counted in the value LPs withdraw at. Withdrawals ignore margin now.
    function test_R3_3_marginDoesntLiftWithdrawalValue() public {
        _open(alice, 0, true, 10, 0.1 ether);
        uint256 b = _open(bob, 0, true, 1, 0.1 ether);
        o0.setAll(-3000); // alice is past her stake; bob is down ~2.6%
        (, int256 hiBefore,) = lens.liabilityRange();
        vm.prank(bob);
        exa.addMargin(b, 1 ether);
        (, int256 hiAfter,) = lens.liabilityRange();
        assertEq(hiAfter, hiBefore);
        _assertSolvent();
    }

    /// R3-4 (Low): orders that could never fill were accepted and listed as fillable for up to 30 days.
    function test_R3_4_unfillableOrdersRefusedOrNotListed() public {
        vm.prank(alice);
        vm.expectRevert(LevExchangeBase.LeverageNotAllowed.selector);
        exa.placeOrder(0, false, 10, 0.01 ether, 0, true, 100, uint64(block.timestamp + 30 days)); // shorts max 5x
        vm.prank(alice);
        exa.placeOrder(0, true, 2, 0.01 ether, 0, true, 100, uint64(block.timestamp + 1 days));
        o0.set(5000, 0, 0); // trigger reached on fast, but spot is pushed: the fill would pass the order's limit
        (uint256[] memory ids,) = lens.actionableOrders(0, 10);
        assertEq(ids.length, 0);
        o0.setAll(50);
        (ids,) = lens.actionableOrders(0, 10);
        assertEq(ids.length, 1);
    }
}
