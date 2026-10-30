// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {LevLens} from "../src/LevLens.sol";
import {Config} from "../src/LevTypes.sol";
import {LevPool} from "../src/LevPool.sol";
import {LevExchange} from "../src/LevExchange.sol";
import {LevExchangeAdmin} from "../src/LevExchangeAdmin.sol";
import {CreatorFeeRouterV2} from "../src/fees/CreatorFeeRouterV2.sol";
import {IPonsLaunchFactory, IPonsFeeEscrow} from "../src/interfaces/IPons.sol";
import {ILevPool, ILevExchange, ILevNav, IFeeSource} from "../src/interfaces/ILevPool.sol";

contract LevPoolTest is Base {
    function test_donationRaisesSharePrice() public {
        uint256 price0 = pool.sharePrice();
        pool.donate{value: 2 ether}();
        assertApproxEqRel(pool.sharePrice(), (price0 * 10.001 ether) / 8.001 ether, 1e12);
        assertEq(pool.totalDonated(), 2 ether);
    }

    function test_plainEthIsADonation() public {
        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(pool.cash(), 9.001 ether);
        assertEq(pool.totalDonated(), 1 ether);
    }

    function test_withdrawAfterCooldown() public {
        uint256 shares = pool.balanceOf(lp);
        vm.startPrank(lp);
        pool.requestWithdraw(shares);
        vm.expectRevert(LevPool.StillLocked.selector);
        pool.withdraw();
        _wait(1 days);
        uint256 before = lp.balance;
        pool.withdraw();
        vm.stopPrank();
        assertApproxEqAbs(lp.balance - before, 8 ether, 1e6);
        assertEq(pool.totalSupply(), pool.balanceOf(pool.DEAD()), "only the seed shares are left");
    }

    function test_cancelWithdrawReturnsShares() public {
        uint256 shares = pool.balanceOf(lp);
        vm.startPrank(lp);
        pool.requestWithdraw(shares);
        assertEq(pool.balanceOf(lp), 0);
        pool.cancelWithdraw();
        vm.stopPrank();
        assertEq(pool.balanceOf(lp), shares);
    }

    function test_withdrawLimitedToFreeCash() public {
        o0.setLiquidity(4000 ether);
        vm.prank(owner);
        exa.setMarket(0, true, 10, 100 ether);
        _open(alice, 0, true, 2, 0.9 ether); // reserves 3.6 ETH of max win, so 7.2 ETH must stay
        uint256 shares = pool.balanceOf(lp);
        vm.startPrank(lp);
        pool.requestWithdraw(shares);
        _wait(1 days);
        vm.expectRevert(LevPool.NotEnoughFreeCash.selector);
        pool.withdraw();
        pool.cancelWithdraw();
        pool.requestWithdraw(shares / 10);
        _wait(1 days);
        pool.withdraw();
        vm.stopPrank();
    }

    function test_navCountsOpenPositions() public {
        o0.setLiquidity(4000 ether);
        vm.prank(owner);
        exa.setMarket(0, true, 10, 100 ether);
        _open(alice, 0, true, 2, 0.5 ether);
        uint256 nav0 = pool.nav();
        o0.setAll(UP_10); // traders up about 0.1 ETH
        assertApproxEqAbs(nav0 - pool.nav(), 0.1 ether, 0.001 ether);
        o0.setAll(-953);
        assertGt(pool.nav(), nav0, "traders losing raises NAV");
    }

    function test_navClampsToMaxWin() public {
        _open(alice, 0, true, 10, 0.1 ether);
        uint256 nav0 = pool.nav();
        o0.setAll(UP_60 * 2);
        assertApproxEqAbs(nav0 - pool.nav(), 0.4 ether, 1e9, "liability never exceeds max win");
    }

    function test_depositorCantBuyCheapWhileTradersLose() public {
        _open(alice, 0, true, 10, 0.2 ether);
        o0.setAll(-3000); // longs nearly wiped: the pool is about to collect
        address eve = makeAddr("eve");
        vm.deal(eve, 10 ether);
        vm.prank(eve);
        uint256 shares = pool.deposit{value: 1 ether}();
        // The price includes the coming gain and the fees already owed to the pool, so an instant round trip
        // can only lose a little, never gain.
        assertLe(pool.previewRedeem(shares), 1 ether);
        assertApproxEqRel(pool.previewRedeem(shares), 1 ether, 0.001e18);
    }

    function test_donationBeforeAnyLpStaysInPool() public {
        LevPool fresh = new LevPool{value: 0.001 ether}(owner);
        LevExchange ex2 = new LevExchange(ILevPool(address(fresh)), owner, treasury, address(new LevExchangeAdmin()));
        vm.prank(owner);
        fresh.setExchange(ILevExchange(address(ex2)));
        fresh.donate{value: 5 ether}();
        assertApproxEqRel(fresh.sharePrice(), 1 ether, 1e12, "share price stays readable before any LP");
        address first = makeAddr("first");
        vm.deal(first, 1 ether);
        vm.prank(first);
        uint256 shares = fresh.deposit{value: 1 ether}();
        assertApproxEqRel(fresh.previewRedeem(shares), 1 ether, 1e12, "first LP doesn't take earlier creator fees");
        assertApproxEqRel(fresh.previewRedeem(fresh.balanceOf(fresh.DEAD())), 5.001 ether, 1e12, "they stay as house money");
    }

    function test_onlyExchangeMovesPoolCash() public {
        vm.expectRevert(LevPool.OnlyExchange.selector);
        pool.payToExchange(1 ether);
        vm.expectRevert(LevPool.OnlyExchange.selector);
        pool.receiveFromExchange{value: 1 ether}();
    }

    function test_exchangeSetOnce() public {
        vm.prank(owner);
        vm.expectRevert(LevPool.AlreadySet.selector);
        pool.setExchange(ILevExchange(address(0xdead)));
    }

    // ------------------------------------------------------- creator fees

    function test_depositHarvestsPendingCreatorFeesFirst() public {
        CreatorFeeRouterV2 fees = new CreatorFeeRouterV2(
            pool, IPonsLaunchFactory(address(0)), IPonsFeeEscrow(address(0)), address(0), 0, treasury, address(0), 0, owner
        );
        vm.prank(owner);
        pool.setFeeSource(IFeeSource(address(fees)));
        // 2 ETH of creator fees are waiting in the router when a new LP joins.
        (bool ok,) = address(fees).call{value: 2 ether}("");
        assertTrue(ok);
        address eve = makeAddr("eve");
        vm.deal(eve, 10 ether);
        vm.prank(eve);
        uint256 shares = pool.deposit{value: 8 ether}();
        // The fees landed before the deposit was priced, so the new LP gets no share of them.
        assertApproxEqRel(pool.previewRedeem(shares), 8 ether, 1e12);
        assertEq(pool.totalDonated(), 1.6 ether, "80% of the fees reached the pool");
    }
}

/// Regressions for LP exit timing found in review.
contract LpTimingTest is Base {
    address internal lp2 = makeAddr("lp2");

    function test_maturedRequestExpires() public {
        vm.startPrank(lp);
        pool.requestWithdraw(pool.balanceOf(lp));
        _wait(30 days);
        vm.expectRevert(LevPool.RequestExpired.selector);
        pool.withdraw();
        pool.cancelWithdraw();
        vm.stopPrank();
    }

    function test_requestGivesUpLaterGains() public {
        uint256 shares = pool.balanceOf(lp);
        vm.prank(lp);
        pool.requestWithdraw(shares);
        pool.donate{value: 4 ether}(); // share price rises after the request
        _wait(1 days);
        uint256 before = lp.balance;
        vm.prank(lp);
        pool.withdraw();
        assertApproxEqAbs(lp.balance - before, 8 ether, 1e6, "paid the value at request time");
    }

    function test_cantExitAheadOfAKnownWinner() public {
        vm.deal(lp2, 100 ether);
        vm.prank(lp2);
        pool.deposit{value: 8 ether}();
        uint256 id = _open(alice, 0, true, 10, 0.2 ether);
        _wait(60);
        o0.set(5000, 5000, 0); // pump: fast and spot up 65%, slow unchanged
        uint256 shares = pool.balanceOf(lp2);
        vm.prank(lp2);
        pool.requestWithdraw(shares);
        _wait(1 days);
        uint256 before = lp2.balance;
        vm.prank(lp2);
        pool.withdraw();
        ex.closeAtMaxWin(id);
        uint256 lp2Got = lp2.balance - before;
        uint256 lp1Left = pool.previewRedeem(pool.balanceOf(lp));
        // The leaver carries the winner's payout too. Holding fees owed are left out of NAV, and leaving while
        // traders are winning pays the stress fee (kept for lp1), so leaving early is worse than staying, never better.
        assertLe(lp2Got, lp1Left);
        assertApproxEqRel(lp2Got, lp1Left, 0.06e18);
    }

    function test_depositPricedAtTheHigherValue() public {
        _open(alice, 0, true, 10, 0.2 ether);
        o0.set(-3000, -3000, 0); // the long is nearly wiped at the fast price; slow hasn't moved
        address eve = makeAddr("eve");
        vm.deal(eve, 10 ether);
        vm.prank(eve);
        uint256 shares = pool.deposit{value: 1 ether}();
        (uint256 low, uint256 high) = pool.navRange();
        assertGt(high, low);
        assertLe(pool.previewRedeem(shares), 1 ether, "no instant gain from the slow price lagging");
    }
}
