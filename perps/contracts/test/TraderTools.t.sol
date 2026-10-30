// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {LevExchangeBase} from "../src/LevExchangeBase.sol";
import {Order} from "../src/LevTypes.sol";

/// @notice Take-profit and stop-loss, orders that open at a price, and margin added to a position.
contract TraderToolsTest is Base {
    // ---------------------------------------------------------------- triggers

    function _withTriggers(int24 tp, int24 sl) internal returns (uint256 id) {
        id = _open(alice, 0, true, 2, 0.1 ether);
        vm.prank(alice);
        exa.setTriggers(id, true, tp, true, sl);
        _wait(60);
    }

    function test_onlyOwnerSetsTriggers() public {
        uint256 id = _open(alice, 0, true, 2, 0.1 ether);
        vm.prank(bob);
        vm.expectRevert(LevExchangeBase.NotPositionOwner.selector);
        exa.setTriggers(id, true, 953, false, 0);
    }

    function test_takeProfitFiresOnFastPrice() public {
        uint256 id = _withTriggers(953, -953);
        o0.set(5000, 500, 0); // spot pushed past the take-profit, the fast price isn't
        vm.expectRevert(LevExchangeBase.NotTriggered.selector);
        ex.closeByTrigger(id);
        o0.setAll(1000);
        assertEq(lens.getPosition(id).action, lens.ACTION_TAKE_PROFIT());
        uint256 before = ex.balanceOf(alice);
        vm.prank(keeper);
        ex.closeByTrigger(id);
        assertGt(ex.balanceOf(alice), before + 0.1 ether, "closed in profit");
        assertGt(ex.balanceOf(keeper), 0, "the closer is paid");
        assertEq(lens.getPosition(id).position.owner, address(0));
        _assertSolvent();
    }

    function test_stopLossFires() public {
        uint256 id = _withTriggers(953, -953);
        o0.setAll(-1000);
        assertEq(lens.getPosition(id).action, lens.ACTION_STOP_LOSS());
        vm.prank(keeper);
        ex.closeByTrigger(id);
        _assertSolvent();
    }

    function test_triggersWaitForMinHold() public {
        uint256 id = _open(alice, 0, true, 2, 0.1 ether);
        vm.prank(alice);
        exa.setTriggers(id, true, 953, false, 0);
        o0.setAll(1000);
        vm.expectRevert(LevExchangeBase.NotTriggered.selector);
        ex.closeByTrigger(id);
        _wait(10);
        ex.closeByTrigger(id);
    }

    // ------------------------------------------------------------------ orders

    function _place(int24 trigger, bool above) internal returns (uint256) {
        vm.prank(alice);
        return exa.placeOrder(0, true, 2, 0.1 ether, trigger, above, 100, uint64(block.timestamp + 1 days));
    }

    function test_orderEscrowsAndFillsAtTrigger() public {
        uint256 bal = ex.balanceOf(alice);
        uint256 oid = _place(953, true); // a breakout long at +10%
        assertEq(ex.orderEscrow(), 0.101 ether, "stake plus the 1% open fee");
        assertEq(ex.balanceOf(alice), bal - 0.101 ether);
        _assertSolvent();
        vm.expectRevert(LevExchangeBase.NotTriggered.selector);
        ex.fillOrder(oid);
        o0.setAll(1000);
        (uint256[] memory ids, uint8[] memory kinds) = lens.actionableOrders(0, 10);
        assertEq(ids.length, 1);
        assertEq(kinds[0], lens.ORDER_FILL());
        vm.prank(keeper);
        uint256 id = ex.fillOrder(oid);
        assertEq(lens.getPosition(id).position.owner, alice);
        assertEq(lens.getPosition(id).position.entryTick, 1000);
        assertEq(ex.orderEscrow(), 0);
        assertEq(ex.balanceOf(alice), bal - 0.101 ether, "the escrow paid stake and fee");
        _assertSolvent();
    }

    function test_orderRefusesAFillFarPastItsTrigger() public {
        uint256 oid = _place(953, true);
        o0.setAll(1100); // 147 ticks past: more than the 100 allowed
        vm.expectRevert(LevExchangeBase.PriceMoved.selector);
        ex.fillOrder(oid);
        assertEq(exa.orderData(oid).owner, alice, "the order stays");
    }

    function test_cancelRefunds() public {
        uint256 bal = ex.balanceOf(alice);
        uint256 oid = _place(-953, false);
        vm.prank(bob);
        vm.expectRevert(LevExchangeBase.Unauthorized.selector);
        exa.cancelOrder(oid);
        vm.prank(alice);
        exa.cancelOrder(oid);
        assertEq(ex.balanceOf(alice), bal);
        assertEq(ex.orderEscrow(), 0);
    }

    function test_expiredOrderAnyoneCancels() public {
        uint256 bal = ex.balanceOf(alice);
        uint256 oid = _place(-953, false);
        _wait(1 days + 1);
        (, uint8[] memory kinds) = lens.actionableOrders(0, 10);
        assertEq(kinds[0], lens.ORDER_EXPIRED());
        vm.expectRevert(LevExchangeBase.OrderExpired.selector);
        ex.fillOrder(oid);
        vm.prank(bob);
        exa.cancelOrder(oid);
        assertEq(ex.balanceOf(alice), bal, "refunded to the owner");
        _assertSolvent();
    }

    // ------------------------------------------------------------------ margin

    /// 10x is liquidated near -8.5%; 0.05 ETH more margin on a 0.1 ETH stake moves that to about -13.5%.
    function test_marginMovesLiquidation() public {
        uint256 id = _open(alice, 0, true, 10, 0.1 ether);
        vm.prank(bob);
        vm.expectRevert(LevExchangeBase.NotPositionOwner.selector);
        exa.addMargin(id, 0.05 ether);
        vm.prank(alice);
        exa.addMargin(id, 0.05 ether);
        _assertSolvent();
        _wait(60);
        o0.setAll(-943); // -9%
        assertEq(lens.getPosition(id).action, lens.ACTION_NONE());
        vm.expectRevert(LevExchangeBase.NotLiquidatable.selector);
        ex.liquidate(id);
        uint256 before = ex.balanceOf(alice);
        _close(alice, id);
        // 0.15 ETH in, about 0.09 ETH lost, minus the close fee
        assertGt(ex.balanceOf(alice) - before, 0.055 ether);
        _assertSolvent();
    }

    function test_marginPaidWithEth() public {
        uint256 id = _open(alice, 0, true, 10, 0.1 ether);
        uint256 bal = ex.balanceOf(alice);
        vm.prank(alice);
        exa.addMargin{value: 0.05 ether}(id, 0.05 ether);
        assertEq(ex.balanceOf(alice), bal, "the sent ETH paid it");
        assertEq(ex.marginOf(id), 0.05 ether);
        assertEq(lens.getPosition(id).equity, int256(0.15 ether));
        _assertSolvent();
    }
}
