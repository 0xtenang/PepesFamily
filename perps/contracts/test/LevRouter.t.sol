// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base} from "./Base.t.sol";
import {LevExchange} from "../src/LevExchange.sol";
import {LevExchangeBase} from "../src/LevExchangeBase.sol";
import {LevRouter} from "../src/LevRouter.sol";

contract LevRouterTest is Base {
    uint256 internal constant P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;
    uint256 internal constant SESSION_PK = 0xA11CE5E55;
    uint256 internal constant OTHER_PK = 0xB0B5E55;

    address internal relayer = makeAddr("relayer");
    bytes32 internal qx;
    bytes32 internal qy;
    bytes32 internal key;
    uint32 internal gen;
    uint256 internal nextNonce = 1;

    function setUp() public override {
        super.setUp();
        (uint256 x, uint256 y) = vm.publicKeyP256(SESSION_PK);
        qx = bytes32(x);
        qy = bytes32(y);
        key = _authorize(alice, qx, qy, _limits());
        gen = router.generationOf(alice);
    }

    // ---------------------------------------------------------------- helpers

    function _limits() internal view returns (LevRouter.Limits memory) {
        return LevRouter.Limits({
            expiry: uint64(vm.getBlockTimestamp() + 1 days),
            actions: router.ACT_OPEN() | router.ACT_CLOSE_OWN() | router.ACT_WITHDRAW(),
            maxLeverage: 10,
            openSlipTicks: 200,
            closeSlipTicks: 500,
            maxStakePerTrade: 0.5 ether,
            maxOpenStake: 1 ether,
            dailyBudget: 2 ether
        });
    }

    function _authorize(address who, bytes32 x, bytes32 y, LevRouter.Limits memory l) internal returns (bytes32 k) {
        vm.prank(who);
        k = router.authorize(x, y, l);
    }

    /// @dev What the browser does: WebCrypto ECDSA P-256 signs SHA-256 of the EIP-712 digest. Low-s required.
    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes32 r, bytes32 s) {
        (r, s) = vmSafe().signP256(pk, sha256(abi.encodePacked(digest)));
        if (uint256(s) > P256_N / 2) s = bytes32(P256_N - uint256(s));
    }

    function vmSafe() internal pure returns (VmP256 v) {
        v = VmP256(address(uint160(uint256(keccak256("hevm cheat code")))));
    }

    function _openIntent(uint32 marketId, bool isLong, uint8 lev, uint96 stake, int24 limitTick)
        internal
        returns (LevRouter.OpenIntent memory)
    {
        return LevRouter.OpenIntent({
            owner: alice,
            key: key,
            generation: gen,
            marketId: marketId,
            isLong: isLong,
            leverage: lev,
            stake: stake,
            limitTick: limitTick,
            nonce: nextNonce++,
            deadline: uint64(vm.getBlockTimestamp() + 30)
        });
    }

    function _relayOpen(LevRouter.OpenIntent memory o) internal returns (uint256 id) {
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashOpen(o));
        vm.prank(relayer);
        id = router.open(o, r, s);
    }

    function _closeIntent(uint256 id) internal returns (LevRouter.CloseIntent memory) {
        return LevRouter.CloseIntent({
            owner: alice,
            key: key,
            generation: gen,
            positionId: id,
            limitTick: lens.getPosition(id).position.isLong ? MIN_TICK : MAX_TICK,
            nonce: nextNonce++,
            deadline: uint64(vm.getBlockTimestamp() + 30)
        });
    }

    function _relayClose(LevRouter.CloseIntent memory c) internal {
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashClose(c));
        vm.prank(relayer);
        router.close(c, r, s);
    }

    // ------------------------------------------------------------------ flows

    function test_relayedOpenAndCloseWithoutOwnerTransactions() public {
        uint256 bal = ex.balanceOf(alice);
        uint256 id = _relayOpen(_openIntent(0, true, 5, 0.1 ether, MAX_TICK));
        assertEq(lens.getPosition(id).position.owner, alice);
        assertEq(ex.balanceOf(alice), bal - 0.1 ether - _openFee(0.1 ether, 5));
        assertEq(router.openedBy(id), key);
        assertEq(relayer.balance, 0, "relayer only pays gas, receives nothing");
        _wait(30);
        o0.setAll(UP_10);
        _relayClose(_closeIntent(id));
        assertEq(exa.openPositionCount(), 0);
        assertGt(ex.balanceOf(alice), bal, "the win is credited to the owner");
        _assertSolvent();
    }

    function test_authorizeCanDepositInTheSameTransaction() public {
        address carol = makeAddr("carol");
        vm.deal(carol, 2 ether);
        (uint256 x, uint256 y) = vm.publicKeyP256(OTHER_PK);
        LevRouter.Limits memory l = _limits();
        vm.prank(carol);
        router.authorize{value: 1.5 ether}(bytes32(x), bytes32(y), l);
        assertEq(ex.balanceOf(carol), 1.5 ether);
    }

    function test_withdrawGoesOnlyToOwner() public {
        LevRouter.WithdrawIntent memory w = LevRouter.WithdrawIntent({
            owner: alice, key: key, generation: gen, amount: 1 ether, nonce: 77, deadline: uint64(vm.getBlockTimestamp() + 30)
        });
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashWithdraw(w));
        uint256 before = alice.balance;
        vm.prank(relayer);
        router.withdraw(w, r, s);
        assertEq(alice.balance, before + 1 ether);
        assertEq(relayer.balance, 0);
    }

    // ----------------------------------------------------------- protections

    function test_replayRejected() public {
        LevRouter.OpenIntent memory o = _openIntent(0, true, 2, 0.05 ether, MAX_TICK);
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashOpen(o));
        router.open(o, r, s);
        vm.expectRevert(LevRouter.NonceUsed.selector);
        router.open(o, r, s);
    }

    function test_deadlines() public {
        LevRouter.OpenIntent memory o = _openIntent(0, true, 2, 0.05 ether, MAX_TICK);
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashOpen(o));
        _wait(31);
        vm.expectRevert(LevRouter.BadDeadline.selector);
        router.open(o, r, s);

        o = _openIntent(0, true, 2, 0.05 ether, MAX_TICK);
        o.deadline = uint64(vm.getBlockTimestamp() + 1 hours); // too far ahead
        (r, s) = _sign(SESSION_PK, router.hashOpen(o));
        vm.expectRevert(LevRouter.BadDeadline.selector);
        router.open(o, r, s);
    }

    function test_wrongKeyOrTamperedIntentRejected() public {
        LevRouter.OpenIntent memory o = _openIntent(0, true, 2, 0.05 ether, MAX_TICK);
        (bytes32 r, bytes32 s) = _sign(OTHER_PK, router.hashOpen(o));
        vm.expectRevert(LevRouter.BadSignature.selector);
        router.open(o, r, s);

        (r, s) = _sign(SESSION_PK, router.hashOpen(o));
        o.stake = 0.4 ether; // relayer changes the size after signing
        vm.expectRevert(LevRouter.BadSignature.selector);
        router.open(o, r, s);
    }

    function test_revokeAndRevokeAll() public {
        LevRouter.OpenIntent memory o = _openIntent(0, true, 2, 0.05 ether, MAX_TICK);
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashOpen(o));
        vm.prank(alice);
        router.revoke(key);
        vm.expectRevert(LevRouter.SessionInvalid.selector);
        router.open(o, r, s);

        // Re-approving the same key gets a new generation: the old signed intent stays dead.
        _authorize(alice, qx, qy, _limits());
        vm.expectRevert(LevRouter.SessionInvalid.selector);
        router.open(o, r, s);

        gen = router.generationOf(alice);
        LevRouter.OpenIntent memory o2 = _openIntent(0, true, 2, 0.05 ether, MAX_TICK);
        (r, s) = _sign(SESSION_PK, router.hashOpen(o2));
        vm.prank(alice);
        router.revokeAll();
        vm.expectRevert(LevRouter.SessionInvalid.selector);
        router.open(o2, r, s);
    }

    function test_sessionRevokesItselfGasFree() public {
        LevRouter.RevokeIntent memory v = LevRouter.RevokeIntent({
            owner: alice, key: key, generation: gen, nonce: 5, deadline: uint64(vm.getBlockTimestamp() + 30)
        });
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashRevoke(v));
        vm.prank(relayer);
        router.revokeBySig(v, r, s);
        (, bool live) = router.sessionOf(alice, key);
        assertFalse(live);
    }

    function test_sessionExpires() public {
        _wait(1 days + 1);
        LevRouter.OpenIntent memory o = _openIntent(0, true, 2, 0.05 ether, MAX_TICK);
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashOpen(o));
        vm.expectRevert(LevRouter.SessionInvalid.selector);
        router.open(o, r, s);
    }

    function test_limits() public {
        LevRouter.OpenIntent memory o = _openIntent(0, true, 2, 0.6 ether, MAX_TICK); // over per-trade
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashOpen(o));
        vm.expectRevert(LevRouter.OverLimit.selector);
        router.open(o, r, s);

        o0.setLiquidity(4000 ether);
        vm.prank(owner);
        exa.setMarket(0, true, 10, 100 ether);
        vm.prank(lp);
        pool.deposit{value: 30 ether}();
        _relayOpen(_openIntent(0, true, 2, 0.5 ether, MAX_TICK));
        _relayOpen(_openIntent(0, true, 2, 0.5 ether, MAX_TICK));
        o = _openIntent(0, true, 2, 0.01 ether, MAX_TICK); // open stake would pass 1 ETH
        (r, s) = _sign(SESSION_PK, router.hashOpen(o));
        vm.expectRevert(LevRouter.OverLimit.selector);
        router.open(o, r, s);
    }

    function test_dailyBudgetBoundsAStolenKey() public {
        LevRouter.Limits memory l = _limits();
        l.expiry = uint64(vm.getBlockTimestamp() + 3 days);
        _authorize(alice, qx, qy, l);
        gen = router.generationOf(alice);
        o0.setLiquidity(4000 ether);
        vm.prank(owner);
        exa.setMarket(0, true, 10, 100 ether);
        vm.prank(lp);
        pool.deposit{value: 30 ether}();
        // Churn: each open of 0.5 ETH counts 0.505 ETH (stake + open fee) against the 2 ETH daily budget.
        for (uint256 i; i < 3; ++i) {
            uint256 id = _relayOpen(_openIntent(0, true, 2, 0.5 ether, MAX_TICK));
            _wait(11);
            _relayClose(_closeIntent(id));
        }
        LevRouter.OpenIntent memory o = _openIntent(0, true, 2, 0.5 ether, MAX_TICK);
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashOpen(o));
        vm.expectRevert(LevRouter.OverLimit.selector);
        router.open(o, r, s);
        // The budget frees up gradually (1/24 per hour): after an hour there is room for one more open, not two.
        _wait(1 hours);
        _relayOpen(_openIntent(0, true, 2, 0.5 ether, MAX_TICK));
        o = _openIntent(0, true, 2, 0.5 ether, MAX_TICK);
        (r, s) = _sign(SESSION_PK, router.hashOpen(o));
        vm.expectRevert(LevRouter.OverLimit.selector);
        router.open(o, r, s);
        _wait(23 hours);
        _relayOpen(_openIntent(0, true, 2, 0.5 ether, MAX_TICK));
    }

    function test_cantForceAFillAtAPushedPrice() public {
        // Someone pushes the live price 5% above the fast average and submits the victim's intent.
        o0.set(500, 0, 0);
        LevRouter.OpenIntent memory o = _openIntent(0, true, 2, 0.05 ether, MAX_TICK); // a stolen key signs any limit
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashOpen(o));
        vm.expectRevert(LevExchangeBase.PriceMoved.selector);
        router.open(o, r, s);
        o0.set(150, 0, 0); // within the 200-tick bound
        _relayOpen(_openIntent(0, true, 2, 0.05 ether, MAX_TICK));
    }

    function test_closeOwnOnlyByDefault() public {
        uint256 walletId = _open(alice, 0, true, 2, 0.05 ether); // opened from the wallet
        _wait(30);
        LevRouter.CloseIntent memory c = _closeIntent(walletId);
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashClose(c));
        vm.expectRevert(LevRouter.NotAllowed.selector);
        router.close(c, r, s);
    }

    function test_closeOnlyOwnersPosition() public {
        LevRouter.Limits memory l = _limits();
        l.actions = router.ACT_CLOSE_ANY();
        _authorize(alice, qx, qy, l);
        gen = router.generationOf(alice);
        uint256 bobsId = _open(bob, 0, true, 2, 0.05 ether);
        _wait(30);
        LevRouter.CloseIntent memory c = _closeIntent(bobsId); // owner = alice, position is bob's
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashClose(c));
        vm.expectRevert(LevExchangeBase.NotPositionOwner.selector);
        router.close(c, r, s);
    }

    function test_guardianKillSwitch() public {
        address g = makeAddr("guardian");
        vm.prank(owner);
        router.setGuardian(g);
        vm.prank(g);
        router.setPaused(true);
        LevRouter.OpenIntent memory o = _openIntent(0, true, 2, 0.05 ether, MAX_TICK);
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashOpen(o));
        vm.expectRevert(LevRouter.Paused.selector);
        router.open(o, r, s);
        // Direct trading from the wallet still works.
        _open(alice, 0, true, 2, 0.05 ether);
    }

    function test_onlyRouterCallsForFunctions() public {
        vm.expectRevert(LevExchangeBase.Unauthorized.selector);
        ex.openFor(alice, 0, true, 2, 0.05 ether, MAX_TICK, 100);
        vm.expectRevert(LevExchangeBase.Unauthorized.selector);
        ex.withdrawFor(alice, 1 ether);
        vm.prank(owner);
        vm.expectRevert(LevExchangeBase.AlreadySet.selector);
        exa.setRouter(address(0xBEEF));
    }

    function test_badLimitsRejected() public {
        LevRouter.Limits memory l = _limits();
        l.expiry = uint64(vm.getBlockTimestamp() + 8 days);
        vm.prank(alice);
        vm.expectRevert(LevRouter.BadLimits.selector);
        router.authorize(qx, qy, l);
        l = _limits();
        vm.prank(alice);
        vm.expectRevert(LevRouter.BadKey.selector);
        router.authorize(bytes32(uint256(1)), bytes32(uint256(2)), l);
    }

    // ------------------------------------------------------- second review

    /// F16: a signed close carries its own price limit.
    function test_F16_closeLimitEnforced() public {
        uint256 id = _relayOpen(_openIntent(0, true, 5, 0.1 ether, MAX_TICK));
        _wait(30);
        LevRouter.CloseIntent memory c = _closeIntent(id);
        c.limitTick = 50; // exit at no less than +0.5%
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashClose(c));
        vm.expectRevert(LevExchangeBase.PriceMoved.selector);
        router.close(c, r, s);
    }

    /// F19: the guardian can void every session at once.
    function test_F19_revokeEverySession() public {
        address g = makeAddr("guardian");
        vm.prank(owner);
        router.setGuardian(g);
        LevRouter.OpenIntent memory o = _openIntent(0, true, 2, 0.05 ether, MAX_TICK);
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashOpen(o));
        vm.prank(g);
        router.revokeEverySession();
        vm.expectRevert(LevRouter.SessionInvalid.selector);
        router.open(o, r, s);
        (, bool live) = router.sessionOf(alice, key);
        assertFalse(live);
    }

    /// F35 (router): the guardian can pause but not unpause.
    function test_F35_routerGuardianCantUnpause() public {
        address g = makeAddr("guardian");
        vm.prank(owner);
        router.setGuardian(g);
        vm.prank(g);
        router.setPaused(true);
        vm.prank(g);
        vm.expectRevert(LevRouter.Unauthorized.selector);
        router.setPaused(false);
    }

    /// F40: a session can still log itself out while signed trading is paused.
    function test_F40_revokeBySigWhilePaused() public {
        vm.prank(owner);
        router.setPaused(true);
        LevRouter.RevokeIntent memory v = LevRouter.RevokeIntent({
            owner: alice, key: key, generation: gen, nonce: 99, deadline: uint64(vm.getBlockTimestamp() + 30)
        });
        (bytes32 r, bytes32 s) = _sign(SESSION_PK, router.hashRevoke(v));
        router.revokeBySig(v, r, s);
        (LevRouter.Session memory ss,) = router.sessionOf(alice, key);
        assertFalse(ss.active);
    }
}

interface VmP256 {
    function signP256(uint256 privateKey, bytes32 digest) external pure returns (bytes32 r, bytes32 s);
}
