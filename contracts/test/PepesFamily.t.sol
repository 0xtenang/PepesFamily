// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

import {PepesFamily} from "../src/PepesFamily.sol";
import {PepesFamilyRouter, FeeSplit as RouterSplit} from "../src/PepesFamilyRouter.sol";
import {PepesFamilyEthRouter} from "../src/PepesFamilyEthRouter.sol";
import {PadToken} from "../src/PadToken.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {FlashHolder} from "./FlashHolder.sol";
import {MockIMD} from "./Mocks.sol";


/// @notice PepesFamily v4: IMD-only launches, 4% hook fee, and expiry of rewards a wallet leaves unclaimed for
///         more than 7 days, which go to the protocol address for a manual $Pepes buyback-and-burn.
contract PepesFamilyTest is Test {
    address constant FEE_RECIPIENT = 0x3c8A4d94B3219F6633F2cC94094f4765b30c691C;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant START_MCAP = 100e18; // 100 IMD

    PoolManager pm;
    PepesFamily pad;
    PepesFamilyRouter router;
    MockIMD imd;
    PoolSwapTest extRouter; // stands in for Universal Router / aggregators
    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new PoolManager(address(this));
        imd = new MockIMD();
        extRouter = new PoolSwapTest(pm);

        bytes memory initCode = abi.encodePacked(
            type(PepesFamily).creationCode,
            abi.encode(
                pm,
                address(imd),
                owner,
                FEE_RECIPIENT,
                DeployLib.startTickForMarketCap(START_MCAP),
                PepesFamily.ImdEthPool(10_000, 100, address(0))
            )
        );
        (bytes32 salt, address expected) = DeployLib.mineSalt(address(this), pad_flags(), initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed == expected, "hook address");
        pad = PepesFamily(deployed);
        router = PepesFamilyRouter(payable(pad.router()));

        address[4] memory users = [alice, bob, carol, address(this)];
        for (uint256 i; i < users.length; i++) {
            vm.deal(users[i], 1000 ether);
            imd.mint(users[i], 1_000_000e18);
            vm.startPrank(users[i]);
            imd.approve(address(router), type(uint256).max);
            imd.approve(address(extRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    receive() external payable {}

    function pad_flags() internal pure returns (uint160) {
        return uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    }

    // ------------------------------------------------------------ helpers

    function _diamond() internal pure returns (PepesFamily.FeeSplit memory) {
        return PepesFamily.FeeSplit(0, 300, 0);
    }

    function _launch() internal returns (PadToken t) {
        vm.prank(alice);
        t = PadToken(payable(pad.launchWithSplit("Test", "TST", '{"image":""}', address(imd), _diamond())));
    }

    function _buy(address who, PadToken t, uint256 amt) internal returns (uint256) {
        vm.prank(who);
        return router.buy(address(t), amt, 0, block.timestamp);
    }

    function _sell(address who, PadToken t, uint256 amt) internal returns (uint256) {
        vm.prank(who);
        t.approve(address(router), amt);
        vm.prank(who);
        return router.sell(address(t), amt, 0, block.timestamp);
    }

    /// @dev Launches tokens until one has the wanted currency ordering.
    function _launchWithOrder(bool quoteIsCurrency0) internal returns (PadToken t) {
        for (uint256 i; i < 40; i++) {
            t = _launch();
            (,,,, bool q0) = pad.launches(address(t));
            if (q0 == quoteIsCurrency0) return t;
        }
        revert("ordering not found");
    }

    // -------------------------------------------------------------- setup

    function test_hookAddressAndRouter() public view {
        assertEq(uint160(address(pad)) & 0x3FFF, pad.HOOK_FLAGS());
        assertEq(address(router.pad()), address(pad));
        assertEq(pad.feeRecipient(), FEE_RECIPIENT);
        assertEq(pad.owner(), owner);
    }

    function test_onlyImd() public {
        vm.expectRevert(PepesFamily.UnsupportedQuote.selector);
        pad.launchWithSplit("X", "X", "", address(0), _diamond());
        vm.expectRevert(PepesFamily.UnsupportedQuote.selector);
        pad.launchWithSplit("X", "X", "", address(0xBEEF), _diamond());
        vm.prank(bob);
        vm.expectRevert(PepesFamily.UnsupportedQuote.selector);
        router.launch{value: 0.5 ether}("E", "E", "", address(0), 0.5 ether, 1);
    }

    function test_launchLocksWholeSupplyInPool() public {
        PadToken t = _launch();
        assertEq(t.balanceOf(address(pm)) + t.balanceOf(DEAD), SUPPLY);
        assertLt(t.balanceOf(DEAD), 1e10); // rounding buffer, burned
        assertEq(t.balanceOf(address(pad)), 0);
        assertEq(t.creator(), alice);
        assertEq(t.quote(), address(imd));
        uint256 mc = pad.marketCap(address(t));
        assertApproxEqRel(mc, START_MCAP, 0.025e18);
        assertGe(mc, START_MCAP);
    }

    function test_launchBothOrderings() public {
        PadToken a = _launchWithOrder(true);
        PadToken b = _launchWithOrder(false);
        assertApproxEqRel(pad.marketCap(address(a)), START_MCAP, 0.025e18);
        assertApproxEqRel(pad.marketCap(address(b)), START_MCAP, 0.025e18);
        uint256 mcA = pad.marketCap(address(a));
        uint256 mcB = pad.marketCap(address(b));
        _buy(bob, a, 10e18);
        _buy(bob, b, 10e18);
        assertGt(pad.marketCap(address(a)), mcA);
        assertGt(pad.marketCap(address(b)), mcB);
        _sell(bob, a, a.balanceOf(bob));
        _sell(bob, b, b.balanceOf(bob));
    }

    // ------------------------------------------------------------ fees

    function test_routerBuyFeeSplit() public {
        PadToken t = _launch();
        uint256 out = _buy(bob, t, 10e18);
        assertGt(out, 0);
        assertEq(t.balanceOf(bob), out);
        assertEq(pad.pendingProtocolFees(address(imd)), 0.1e18);
        assertEq(pad.pendingHolderFees(address(t)), 0); // router flushed it
        assertEq(imd.balanceOf(address(t)), 0.3e18); // waiting: bob only got tokens after the flush

        _buy(carol, t, 10e18);
        assertEq(pad.pendingProtocolFees(address(imd)), 0.2e18);
        assertApproxEqAbs(t.withdrawableDividendOf(bob), 0.6e18, 10); // both fees, bob was the only holder
        assertEq(t.withdrawableDividendOf(carol), 0);

        pad.collectProtocolFees(address(imd));
        assertEq(imd.balanceOf(FEE_RECIPIENT), 0.2e18);
        assertEq(pad.pendingProtocolFees(address(imd)), 0);
    }

    function test_holdersPaidProRata() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 30e18);
        uint256 bBal = t.balanceOf(bob);
        uint256 cBal = t.balanceOf(carol);
        uint256 bBefore = t.withdrawableDividendOf(bob);
        uint256 cBefore = t.withdrawableDividendOf(carol);

        _buy(alice, t, 20e18); // 0.6 IMD to bob + carol by balance
        uint256 bGain = t.withdrawableDividendOf(bob) - bBefore;
        uint256 cGain = t.withdrawableDividendOf(carol) - cBefore;
        assertApproxEqAbs(bGain + cGain, 0.6e18, 10);
        assertApproxEqRel(bGain * cBal, cGain * bBal, 1e9);

        uint256 imdBefore = imd.balanceOf(bob);
        vm.prank(bob);
        uint256 claimed = t.claim();
        assertEq(imd.balanceOf(bob) - imdBefore, claimed);
        assertEq(t.withdrawableDividendOf(bob), 0);
    }

    function test_routerSellFee() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 10e18);
        uint256 protoBefore = pad.pendingProtocolFees(address(imd));
        uint256 carolDivBefore = t.withdrawableDividendOf(carol);
        uint256 bobDivBefore = t.withdrawableDividendOf(bob);

        uint256 imdBefore = imd.balanceOf(carol);
        uint256 out = _sell(carol, t, t.balanceOf(carol));
        assertEq(imd.balanceOf(carol) - imdBefore, out);
        // gross = out / 0.96; protocol 1% of gross, holders 3% of gross
        uint256 gross = (out * 10_000) / 9_600;
        assertApproxEqAbs(pad.pendingProtocolFees(address(imd)) - protoBefore, gross / 100, 1e6);
        assertApproxEqAbs(t.withdrawableDividendOf(bob) - bobDivBefore, (gross * 3) / 100, 1e6);
        assertEq(t.withdrawableDividendOf(carol), carolDivBefore); // no gain from own sell
    }

    function test_externalRouter_allSwapKinds_bothOrders() public {
        for (uint256 o; o < 2; o++) {
            PadToken t = _launchWithOrder(o == 0);
            _buy(alice, t, 10e18);
            PoolKey memory key = pad.poolKey(address(t));
            vm.prank(bob);
            t.approve(address(extRouter), type(uint256).max);
            _checkExternal(key, t, true, -5e18);
            _checkExternal(key, t, true, 1_000_000e18);
            _checkExternal(key, t, false, -500_000e18);
            _checkExternal(key, t, false, 0.5e18);
        }
    }

    /// @dev Swaps through a third-party router and checks the trader paid/received exactly 4% on the IMD side.
    function _checkExternal(PoolKey memory key, PadToken t, bool isBuy, int256 amountSpecified) internal {
        (,,,, bool quoteIs0) = pad.launches(address(t));
        bool zeroForOne = isBuy == quoteIs0;
        uint256 qBefore = imd.balanceOf(bob);
        uint256 tBefore = t.balanceOf(bob);
        uint256 protoBefore = pad.pendingProtocolFees(address(imd));
        uint256 holderBefore = pad.pendingHolderFees(address(t));

        vm.prank(bob);
        extRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ""
        );

        uint256 quoteMoved = isBuy ? qBefore - imd.balanceOf(bob) : imd.balanceOf(bob) - qBefore;
        uint256 tokenMoved = isBuy ? t.balanceOf(bob) - tBefore : tBefore - t.balanceOf(bob);
        assertGt(tokenMoved, 0);
        uint256 proto = pad.pendingProtocolFees(address(imd)) - protoBefore;
        uint256 holders = pad.pendingHolderFees(address(t)) - holderBefore;
        uint256 fee = proto + holders;
        uint256 gross = isBuy ? quoteMoved : quoteMoved + fee;
        assertApproxEqAbs(fee, (gross * 4) / 100, 2, "fee is 4%");
        assertApproxEqAbs(proto * 3, holders, 3, "1% / 3% split");
        if (amountSpecified < 0 && isBuy) assertEq(quoteMoved, uint256(-amountSpecified));
        if (amountSpecified > 0 && !isBuy) assertEq(quoteMoved, uint256(amountSpecified));

        uint256 aliceBefore = t.withdrawableDividendOf(alice);
        pad.flush(address(t));
        assertEq(pad.pendingHolderFees(address(t)), 0);
        assertGt(t.withdrawableDividendOf(alice), aliceBefore);
    }

    function test_claimFlushesPendingFees() public {
        PadToken t = _launchWithOrder(true);
        _buy(alice, t, 10e18);
        PoolKey memory key = pad.poolKey(address(t));
        vm.prank(bob);
        extRouter.swap(key, SwapParams(true, -10e18, TickMath.MIN_SQRT_PRICE + 1), settings, "");
        assertGt(pad.pendingHolderFees(address(t)), 0);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        uint256 got = t.claim();
        assertApproxEqAbs(got + t.withdrawableDividendOf(bob), 0.6e18, 10);
        assertApproxEqRel(got * t.balanceOf(bob), t.withdrawableDividendOf(bob) * t.balanceOf(alice), 1e9);
        assertEq(imd.balanceOf(alice) - before, got);
        assertEq(pad.pendingHolderFees(address(t)), 0);
    }

    function test_transferMovesFutureDividendsOnly() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(alice, t, 10e18);
        uint256 earned = t.withdrawableDividendOf(bob);
        uint256 bal = t.balanceOf(bob);
        vm.prank(bob);
        t.transfer(carol, bal);
        assertEq(t.withdrawableDividendOf(bob), earned);
        assertEq(t.withdrawableDividendOf(carol), 0);
    }

    function test_everyoneCanExit() public {
        PadToken t = _launch();
        _buy(bob, t, 30e18);
        _buy(carol, t, 50e18);
        _buy(alice, t, 20e18);
        _sell(carol, t, t.balanceOf(carol));
        _sell(alice, t, t.balanceOf(alice));
        _sell(bob, t, t.balanceOf(bob));
        assertGe(t.balanceOf(address(pm)), SUPPLY - 1e10 - 10); // pool got (almost) every token back
    }

    function test_routerLaunchWithInitialBuy() public {
        vm.prank(bob);
        (address token, uint256 out) = router.launch("Imd Cat", "ICAT", "", address(imd), 50e18, 1);
        PadToken t = PadToken(payable(token));
        assertEq(t.creator(), bob);
        assertEq(t.balanceOf(bob), out);
        assertEq(pad.pendingProtocolFees(address(imd)), 0.5e18);
        assertEq(imd.balanceOf(token), 1.5e18);
        assertEq(t.lastActive(bob), block.timestamp, "the creator's first buy starts their timer");
    }

    function test_cannotCreatePoolsOrAddLiquidityWithHook() public {
        PadToken t = _launch();
        PoolKey memory key = pad.poolKey(address(t));

        PoolKey memory other = key;
        other.tickSpacing = 60;
        vm.expectRevert();
        pm.initialize(other, TickMath.getSqrtPriceAtTick(0));

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        imd.approve(address(lp), type(uint256).max);
        vm.expectRevert();
        lp.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 1e18, 0), "");
    }

    function test_slippageAndDeadline() public {
        PadToken t = _launch();
        vm.prank(bob);
        vm.expectRevert(PepesFamilyRouter.Slippage.selector);
        router.buy(address(t), 10e18, type(uint256).max, block.timestamp);

        vm.prank(bob);
        vm.expectRevert(PepesFamilyRouter.Expired.selector);
        router.buy(address(t), 10e18, 0, block.timestamp - 1);

        vm.prank(bob);
        vm.expectRevert(PepesFamilyRouter.BadAmount.selector);
        router.buy{value: 1 ether}(address(t), 10e18, 0, block.timestamp); // ETH sent to an IMD buy
    }

    function test_onlyOwnerAdmin() public {
        vm.prank(bob);
        vm.expectRevert(PepesFamily.NotOwner.selector);
        pad.setFeeRecipient(bob);

        vm.prank(owner);
        pad.setStartTick(address(imd), DeployLib.startTickForMarketCap(300e18));
        PadToken t = _launch();
        assertApproxEqRel(pad.marketCap(address(t)), 300e18, 0.025e18);

        vm.startPrank(owner);
        vm.expectRevert(PepesFamily.BadTick.selector);
        pad.setStartTick(address(imd), 201);
        vm.expectRevert(PepesFamily.UnsupportedQuote.selector);
        pad.setStartTick(address(0), 0);
        vm.stopPrank();
    }

    function testFuzz_buySellFeesAndSolvency(uint96 a, uint96 b) public {
        uint256 buyA = bound(a, 1e12, 2_000e18);
        uint256 buyB = bound(b, 1e12, 2_000e18);
        PadToken t1 = _launch();
        PadToken t2 = _launch();
        _buy(bob, t1, buyA);
        _buy(carol, t2, buyB);
        uint256 bal = t1.balanceOf(bob);
        uint256 got = _sell(bob, t1, bal);
        assertLt(got, buyA); // round trip always loses the fees

        pad.collectProtocolFees(address(imd));
        vm.prank(carol);
        t2.claim();
        assertApproxEqAbs(
            imd.balanceOf(FEE_RECIPIENT), (buyA + buyB + ((got * 10_000) / 9_600)) / 100, 1e6, "protocol got 1% of volume"
        );
        assertGe(imd.balanceOf(address(t1)), t1.accountedBalance());
        assertGe(imd.balanceOf(address(t2)), t2.accountedBalance());
    }

    // ------------------------------------------------------ attack surface

    function test_attack_cannotCallHookOrCallbacksDirectly() public {
        PadToken t = _launch();
        PoolKey memory key = pad.poolKey(address(t));
        SwapParams memory sp = SwapParams(true, -1e18, TickMath.MIN_SQRT_PRICE + 1);
        vm.startPrank(bob);
        vm.expectRevert(PepesFamily.NotPoolManager.selector);
        pad.beforeSwap(bob, key, sp, "");
        vm.expectRevert(PepesFamily.NotPoolManager.selector);
        pad.unlockCallback(abi.encode(uint8(1), abi.encode(address(t))));
        vm.expectRevert(PepesFamilyRouter.NotPoolManager.selector);
        router.unlockCallback("");
        vm.expectRevert(PepesFamily.NotRouter.selector);
        pad.launchForWithSplit(alice, "X", "X", "", address(imd), _diamond());
        vm.stopPrank();
    }

    function test_attack_cannotSellSomeoneElsesTokens() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        uint256 bobBal = t.balanceOf(bob);
        vm.prank(carol);
        vm.expectRevert();
        router.sell(address(t), bobBal, 0, block.timestamp);
        assertEq(t.balanceOf(bob), bobBal);
        vm.prank(address(router));
        vm.expectRevert(PadToken.InsufficientAllowance.selector);
        t.transferFrom(bob, carol, 1);
        vm.prank(carol);
        vm.expectRevert(PadToken.InsufficientAllowance.selector);
        t.transferFrom(bob, carol, 1);
    }

    function test_attack_liquidityCannotBeRemoved() public {
        PadToken t = _launch();
        PoolKey memory key = pad.poolKey(address(t));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        vm.expectRevert(); // the position belongs to PepesFamily, which has no remove function
        lp.modifyLiquidity(key, ModifyLiquidityParams(TickMath.minUsableTick(200), 0, -1e18, 0), "");
    }

    function test_attack_hugeExactOutSellReverts() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        PoolKey memory key = pad.poolKey(address(t));
        (,,,, bool quoteIs0) = pad.launches(address(t));
        vm.prank(bob);
        t.approve(address(extRouter), type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(); // fee can't be cast to int128: reverts instead of truncating
        extRouter.swap(
            key,
            SwapParams(!quoteIs0, int256(1 << 200), quoteIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1),
            settings,
            ""
        );
    }

    function test_attack_distributeNeverBlocksTradesOrClaims() public {
        vm.prank(alice);
        (address token,) = router.launch("I", "I", "", address(imd), 10e18, 1);
        PadToken t = PadToken(payable(token));
        _buy(bob, t, 10e18);
        imd.slash(address(t), imd.balanceOf(address(t)) / 2);
        assertEq(t.distribute(), 0);
        _buy(carol, t, 10e18); // trading still works
        _sell(bob, t, t.balanceOf(bob));
    }

    function test_attack_feesCannotBeStolen() public {
        PadToken t = _launch();
        _buy(bob, t, 100e18);
        uint256 before = imd.balanceOf(FEE_RECIPIENT);
        uint256 carolBefore = imd.balanceOf(carol);
        vm.prank(carol);
        pad.collectProtocolFees(address(imd));
        assertEq(imd.balanceOf(FEE_RECIPIENT) - before, 1e18);
        assertEq(imd.balanceOf(carol), carolBefore);
        uint256 id = uint256(uint160(address(imd)));
        vm.prank(carol);
        vm.expectRevert();
        pm.transferFrom(address(pad), carol, id, 1);
    }

    function test_ownershipIsTwoStep() public {
        vm.prank(owner);
        pad.transferOwnership(bob);
        assertEq(pad.owner(), owner);
        vm.prank(carol);
        vm.expectRevert(PepesFamily.NotOwner.selector);
        pad.acceptOwnership();
        vm.prank(bob);
        pad.acceptOwnership();
        assertEq(pad.owner(), bob);
    }

    // ------------------------------------------------------------ token basics (v2+)

    function _permitSig(uint256 pk, PadToken t, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address holder = vm.addr(pk);
        bytes32 structHash =
            keccak256(abi.encode(t.PERMIT_TYPEHASH(), holder, spender, value, t.nonces(holder), deadline));
        return vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", t.DOMAIN_SEPARATOR(), structHash)));
    }

    function _fund(address who) internal {
        imd.mint(who, 1_000e18);
        vm.prank(who);
        imd.approve(address(router), type(uint256).max);
    }

    function test_token_ownerIsZeroAddress() public {
        PadToken t = _launch();
        assertEq(t.owner(), address(0)); // scanners show "renounced"
    }

    function test_padDeploysEthRouter() public view {
        address eth = pad.ethRouter();
        assertGt(eth.code.length, 0);
        assertEq(address(PepesFamilyEthRouter(payable(eth)).pad()), address(pad));
        assertEq(PepesFamilyEthRouter(payable(eth)).IMD(), address(imd));
    }

    function test_routerNeedsApproval() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        uint256 bal = t.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert(); // no allowance -> the router can't pull bob's tokens
        router.sell(address(t), bal, 0, block.timestamp);
    }

    function test_sellWithPermit() public {
        (address dan, uint256 pk) = makeAddrAndKey("dan");
        _fund(dan);
        PadToken t = _launch();
        _buy(dan, t, 10e18);
        uint256 bal = t.balanceOf(dan);
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(pk, t, address(router), bal, block.timestamp);
        uint256 imdBefore = imd.balanceOf(dan);
        vm.prank(dan);
        uint256 out = router.sellWithPermit(address(t), bal, 1, block.timestamp, v, r, s);
        assertEq(t.balanceOf(dan), 0);
        assertEq(imd.balanceOf(dan) - imdBefore, out);
        assertEq(t.nonces(dan), 1);
    }

    function test_permitFrontRunDoesNotBlockSale() public {
        (address dan, uint256 pk) = makeAddrAndKey("dan");
        _fund(dan);
        PadToken t = _launch();
        _buy(dan, t, 10e18);
        uint256 bal = t.balanceOf(dan);
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(pk, t, address(router), bal, block.timestamp);
        vm.prank(carol);
        t.permit(dan, address(router), bal, block.timestamp, v, r, s);
        vm.prank(dan);
        router.sellWithPermit(address(t), bal, 1, block.timestamp, v, r, s);
        assertEq(t.balanceOf(dan), 0);
    }

    function test_permitRejectsWrongSignerAndReplay() public {
        (address dan, uint256 pk) = makeAddrAndKey("dan");
        (, uint256 evePk) = makeAddrAndKey("eve");
        _fund(dan);
        PadToken t = _launch();
        _buy(dan, t, 10e18);
        uint256 bal = t.balanceOf(dan);

        (uint8 v, bytes32 r, bytes32 s) = _permitSig(evePk, t, address(router), bal, block.timestamp);
        vm.expectRevert(PadToken.InvalidSignature.selector);
        t.permit(dan, address(router), bal, block.timestamp, v, r, s);

        (v, r, s) = _permitSig(pk, t, address(router), bal, block.timestamp);
        t.permit(dan, address(router), bal, block.timestamp, v, r, s);
        vm.expectRevert(PadToken.InvalidSignature.selector);
        t.permit(dan, address(router), bal, block.timestamp, v, r, s);

        (v, r, s) = _permitSig(pk, t, address(router), bal, block.timestamp - 1);
        vm.expectRevert(PadToken.PermitExpired.selector);
        t.permit(dan, address(router), bal, block.timestamp - 1, v, r, s);
    }

    // ------------------------------------------- audit (v3): flash-held rewards

    function test_audit_flashHolderCannotClaimPendingFees() public {
        PadToken t = _launchWithOrder(true);
        _buy(bob, t, 10e18);
        _buy(bob, t, 10e18);
        PoolKey memory key = pad.poolKey(address(t));
        vm.prank(carol);
        extRouter.swap(key, SwapParams(true, -100e18, TickMath.MIN_SQRT_PRICE + 1), settings, "");
        assertEq(pad.pendingHolderFees(address(t)), 3e18);

        FlashHolder attacker = new FlashHolder(pm, t);
        attacker.run(0);
        assertEq(imd.balanceOf(address(attacker)), 0, "flash holder captured holder rewards");

        pad.flush(address(t));
        assertApproxEqAbs(t.withdrawableDividendOf(bob) + t.withdrawableDividendOf(carol), 3e18 + 0.6e18, 10);
    }

    function test_audit_flashHolderCannotTriggerDistribution() public {
        PadToken t = _launchWithOrder(true);
        _buy(bob, t, 10e18); // 0.3 IMD waits in the token (nobody held tokens at distribution time)
        FlashHolder attacker = new FlashHolder(pm, t);
        attacker.run(1);
        vm.prank(address(attacker));
        t.claim();
        assertEq(imd.balanceOf(address(attacker)), 0, "flash holder captured waiting rewards");
    }

    function test_audit_traderCannotRecoverOwnFee() public {
        PadToken t = _launchWithOrder(true);
        _buy(bob, t, 10e18);
        _buy(bob, t, 10e18);
        uint256 bobBefore = t.withdrawableDividendOf(bob);
        FlashHolder attacker = new FlashHolder(pm, t);
        imd.mint(address(attacker), 100e18);
        attacker.runBuy(pad.poolKey(address(t)), true, 100e18);
        assertEq(imd.balanceOf(address(attacker)), 0, "trader recovered its own holder fee");
        pad.flush(address(t));
        uint256 bobGain = t.withdrawableDividendOf(bob) - bobBefore;
        uint256 traderGain = t.withdrawableDividendOf(address(attacker));
        assertApproxEqAbs(bobGain + traderGain, 3e18, 10);
        assertApproxEqRel(bobGain * t.balanceOf(address(attacker)), traderGain * t.balanceOf(bob), 1e9);
    }

    // ------------------------------------------------------------ v4: expiry

    /// bob buys and carol's buy pays him; after more than 7 days without activity, all of it has expired, goes to
    /// the protocol address, and bob can claim nothing more.
    function test_expiry_inactiveWalletsRewardsGoToProtocol() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 10e18);
        uint256 owed = t.withdrawableDividendOf(bob);
        assertGt(owed, 0);
        assertEq(t.expiredRewardsOf(bob), 0, "still active");

        vm.warp(block.timestamp + 7 days + 1);
        assertEq(t.expiredRewardsOf(bob), owed);
        vm.prank(alice); // anyone can trigger it
        uint256 expired = t.recycle(bob);
        assertEq(expired, owed);
        assertEq(imd.balanceOf(FEE_RECIPIENT), owed);
        assertEq(t.totalRecycled(), owed);
        assertEq(t.withdrawableDividendOf(bob), 0);
        assertEq(t.recycle(bob), 0, "nothing twice");
        vm.prank(bob);
        assertEq(t.claim(), 0);
        assertGe(imd.balanceOf(address(t)), t.accountedBalance());
    }

    /// Only rewards older than 7 days expire: what bob earned during his last 7 days stays his.
    function test_expiry_recentRewardsNeverExpire() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 10e18); // day 0: bob earns R1
        uint256 r1 = t.withdrawableDividendOf(bob);
        vm.warp(block.timestamp + 6 days);
        _buy(alice, t, 10e18); // day 6: bob earns R2
        uint256 r2 = t.withdrawableDividendOf(bob) - r1;
        vm.warp(block.timestamp + 2 days); // bob inactive for 8 days

        uint256 expired = t.recycle(bob);
        assertApproxEqAbs(expired, r1, 1e6, "only the old rewards expire");
        assertApproxEqAbs(t.withdrawableDividendOf(bob), r2, 1e6, "recent rewards stay");
        uint256 before = imd.balanceOf(bob);
        vm.prank(bob);
        t.claim();
        assertApproxEqAbs(imd.balanceOf(bob) - before, r2, 1e6);
    }

    function test_expiry_exactly7DaysIsStillSafe() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 10e18);
        uint256 last = t.lastActive(bob);
        vm.warp(last + 7 days);
        assertEq(t.expiredRewardsOf(bob), 0, "exactly 7 days: still active");
        assertEq(t.recycle(bob), 0);
        vm.warp(last + 7 days + 1);
        assertGt(t.expiredRewardsOf(bob), 0);
    }

    function test_expiry_claimResetsTheTimer() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 10e18);
        vm.warp(block.timestamp + 5 days);
        vm.prank(bob);
        t.claim();
        _buy(alice, t, 10e18);
        vm.warp(block.timestamp + 5 days); // 10 days since the buy, 5 since the claim
        assertEq(t.expiredRewardsOf(bob), 0);
    }

    function test_expiry_sendingResetsTheTimer() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 10e18);
        vm.warp(block.timestamp + 6 days);
        vm.prank(bob);
        t.transfer(alice, 1); // any send is bob's own act
        vm.warp(block.timestamp + 6 days);
        assertEq(t.expiredRewardsOf(bob), 0);
    }

    function test_expiry_buyingAgainResetsTheTimer() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 10e18);
        vm.warp(block.timestamp + 6 days);
        _buy(bob, t, 1e18);
        vm.warp(block.timestamp + 6 days);
        assertEq(t.expiredRewardsOf(bob), 0);
    }

    /// Audit finding 3: a small buy at a high market cap is still the buyer's activity (the hook records it).
    function test_expiry_tinyBuyAtHighMarketCapCounts() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 5_000e18); // market cap now far above the start
        uint256 bought = 0;
        vm.warp(block.timestamp + 6 days);
        bought = _buy(bob, t, 1e15); // 0.001 IMD: a few hundred tokens
        assertLt(bought * 10, t.balanceOf(bob), "small next to bob's bag");
        assertEq(t.lastActive(bob), block.timestamp);
        vm.warp(block.timestamp + 1 days + 1);
        assertEq(t.expiredRewardsOf(bob), 0, "bob bought a day ago");
    }

    /// A buy through a third-party router marks the transaction's signer, who can only be the buyer themselves.
    function test_expiry_externalRouterBuyCountsForTheSigner() public {
        PadToken t = _launchWithOrder(true);
        _buy(bob, t, 10e18);
        PoolKey memory key = pad.poolKey(address(t));
        vm.warp(block.timestamp + 6 days);
        vm.prank(bob, bob);
        extRouter.swap(key, SwapParams(true, -1e15, TickMath.MIN_SQRT_PRICE + 1), settings, "");
        assertEq(t.lastActive(bob), block.timestamp);
    }

    function test_markActive_onlyPad() public {
        PadToken t = _launch();
        vm.prank(carol);
        vm.expectRevert(PadToken.NotPad.selector);
        t.markActive(bob);
    }

    /// Audit b803125e finding 3: tokens someone else sends never count as the recipient's activity, so a gift
    /// (even 1 wei to a wallet that sold everything) can't keep its rewards from expiring.
    function test_expiry_giftsNeverResetTheTimer() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 50e18);
        uint256 last = t.lastActive(bob);
        vm.warp(block.timestamp + 6 days);
        uint256 big = t.balanceOf(carol) / 2;
        vm.prank(carol);
        t.transfer(bob, big);
        assertEq(t.lastActive(bob), last, "a gift isn't bob's act");
        vm.warp(block.timestamp + 1 days + 1);
        assertGt(t.expiredRewardsOf(bob), 0);
    }

    function test_expiry_oneWeiGiftToExitedHolder() public {
        PadToken t = _launch();
        _buy(bob, t, 100e18);
        _buy(carol, t, 500e18);
        uint256 owed = t.withdrawableDividendOf(bob);
        _sell(bob, t, t.balanceOf(bob));
        vm.warp(block.timestamp + 6 days);
        vm.prank(carol);
        t.transfer(bob, 1);
        vm.warp(block.timestamp + 1 days + 1);
        assertEq(t.recycle(bob), owed);
    }

    /// Audit b803125e finding 4: a contract wallet buying through the launchpad's ETH router is credited, not the
    /// key that signed for it.
    function test_expiry_ethRouterCreditsTheBuyerNotTheSigner() public {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        PoolKey memory imdEth =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 100, IHooks(address(0)));
        pm.initialize(imdEth, TickMath.getSqrtPriceAtTick(0));
        imd.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 500 ether}(imdEth, ModifyLiquidityParams(-887200, 887200, 100e18, 0), "");

        PadToken t = _launch();
        PepesFamilyEthRouter eth = PepesFamilyEthRouter(payable(pad.ethRouter()));
        address wallet = makeAddr("contractWallet");
        address signer = makeAddr("ownerKey");
        vm.deal(wallet, 10 ether);
        vm.prank(wallet, signer);
        eth.buyWithEth{value: 1 ether}(address(t), 1, block.timestamp);
        _buy(carol, t, 10e18);
        vm.warp(block.timestamp + 6 days);
        vm.prank(wallet, signer);
        eth.buyWithEth{value: 0.001 ether}(address(t), 1, block.timestamp);
        assertEq(t.lastActive(wallet), block.timestamp, "the wallet that bought is active");
        assertEq(t.lastActive(signer), 0, "the signer holds nothing and isn't marked");
        vm.warp(block.timestamp + 1 days + 1);
        assertEq(t.expiredRewardsOf(wallet), 0);
    }

    function test_expiry_firstReceiptStartsTheTimer() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        vm.prank(bob);
        t.transfer(carol, 1);
        assertEq(t.lastActive(carol), block.timestamp);
    }

    function test_expiry_zeroTransferDoesNotCountAsActivity() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 10e18);
        uint256 last = t.lastActive(bob);
        vm.warp(block.timestamp + 6 days);
        vm.prank(carol); // a zero-amount transferFrom needs no allowance
        t.transferFrom(bob, carol, 0);
        assertEq(t.lastActive(bob), last);
    }

    function test_expiry_cannotRecycleSystemAccounts() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        vm.expectRevert(PadToken.NotEligible.selector);
        t.recycle(address(pm));
        vm.expectRevert(PadToken.NotEligible.selector);
        t.recycle(address(pad));
        vm.expectRevert(PadToken.NotEligible.selector);
        t.recycle(DEAD);
    }

    function test_expiry_recycleMany() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 10e18);
        _buy(alice, t, 10e18);
        uint256 owed = t.withdrawableDividendOf(bob) + t.withdrawableDividendOf(carol);
        vm.warp(block.timestamp + 8 days);
        address[] memory list = new address[](4);
        (list[0], list[1], list[2], list[3]) = (bob, carol, address(pm), makeAddr("nobody"));
        uint256 total = t.recycleMany(list);
        assertEq(total, t.totalRecycled()); // alice bought last, so she earned nothing
        assertEq(imd.balanceOf(FEE_RECIPIENT), t.totalRecycled());
        assertApproxEqAbs(total, owed, 2);
    }

    /// Whatever the trades and timing, recycling never takes more than is owed and the token stays solvent.
    function testFuzz_expirySolvent(uint96 a, uint96 b, uint32 gap1, uint32 gap2) public {
        PadToken t = _launch();
        _buy(bob, t, bound(a, 1e15, 500e18));
        vm.warp(block.timestamp + bound(gap1, 0, 20 days));
        _buy(carol, t, bound(b, 1e15, 500e18));
        vm.warp(block.timestamp + bound(gap2, 0, 20 days));
        _buy(alice, t, 5e18);
        uint256 owed = t.withdrawableDividendOf(bob);
        uint256 expired = t.recycle(bob);
        assertLe(expired, owed);
        assertEq(t.withdrawableDividendOf(bob), owed - expired);
        assertGe(imd.balanceOf(address(t)), t.accountedBalance());
        vm.prank(bob);
        t.claim();
        vm.prank(carol);
        t.claim();
        assertGe(imd.balanceOf(address(t)), t.accountedBalance());
    }

    // ------------------------------------------------------------ v4: where expired rewards go

    /// Expired rewards of every v4 token go to the protocol address, and follow it when the owner changes it.
    function test_expiry_goesToCurrentFeeRecipient() public {
        PadToken t1 = _launch();
        PadToken t2 = _launch();
        _buy(bob, t1, 10e18);
        _buy(carol, t1, 10e18);
        _buy(bob, t2, 10e18);
        _buy(carol, t2, 10e18);
        vm.warp(block.timestamp + 8 days);
        uint256 e1 = t1.recycle(bob);
        assertEq(imd.balanceOf(FEE_RECIPIENT), e1);
        address treasury = makeAddr("treasury");
        vm.prank(owner);
        pad.setFeeRecipient(treasury);
        uint256 e2 = t2.recycle(bob);
        assertGt(e2, 0);
        assertEq(imd.balanceOf(treasury), e2, "follows setFeeRecipient");
        assertEq(imd.balanceOf(FEE_RECIPIENT), e1);
    }

    // ------------------------------------------------------------ v4 audits (ec4e3ea7, b803125e)

    /// Finding 7: recycling twice only ever takes rewards that have aged past 7 days.
    function test_expiry_secondRecycleOnlyTakesAgedRewards() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 10e18); // day 0: R1
        uint256 r1 = t.withdrawableDividendOf(bob);
        vm.warp(block.timestamp + 5 days);
        _buy(alice, t, 10e18); // day 5: R2
        uint256 r2 = t.withdrawableDividendOf(bob) - r1;
        vm.warp(block.timestamp + 3 days); // day 8
        assertApproxEqAbs(t.recycle(bob), r1, 1e6);
        vm.warp(block.timestamp + 2 days); // day 10: R2 is 5 days old
        assertEq(t.recycle(bob), 0);
        _buy(carol, t, 10e18); // day 10: R3
        uint256 r3 = t.withdrawableDividendOf(bob) - r2;
        vm.warp(block.timestamp + 3 days); // day 13
        assertApproxEqAbs(t.recycle(bob), r2, 1e6);
        assertApproxEqAbs(t.withdrawableDividendOf(bob), r3, 1e6);
        assertGe(imd.balanceOf(address(t)), t.accountedBalance());
    }

    /// Finding 7: a holder who sold everything keeps nothing older than 7 days and earns nothing new.
    function test_expiry_zeroBalanceHolderLosesEverythingOld() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 10e18);
        uint256 owed = t.withdrawableDividendOf(bob);
        vm.warp(block.timestamp + 1 days);
        _sell(bob, t, t.balanceOf(bob)); // activity on day 1
        vm.warp(block.timestamp + 2 days);
        _buy(alice, t, 10e18);
        vm.warp(block.timestamp + 5 days + 1); // 7 days + 1 s after the sale
        assertEq(t.recycle(bob), owed);
        assertEq(t.withdrawableDividendOf(bob), 0);
    }

    /// Finding 7: fees left pending by a third-party router, recycled around, still reach the right holders.
    function test_expiry_pendingFeesAndRecycleStaySolvent() public {
        PadToken t = _launchWithOrder(true);
        _buy(bob, t, 10e18);
        _buy(carol, t, 10e18);
        vm.warp(block.timestamp + 8 days);
        PoolKey memory key = pad.poolKey(address(t));
        vm.prank(alice, alice);
        extRouter.swap(key, SwapParams(true, -10e18, TickMath.MIN_SQRT_PRICE + 1), settings, "");
        assertGt(pad.pendingHolderFees(address(t)), 0);
        uint256 expired = t.recycle(bob); // pending fees are not bob's yet
        pad.flush(address(t)); // now they are spread, partly to bob as a current holder
        uint256 recent = t.withdrawableDividendOf(bob);
        assertGt(expired, 0);
        assertGt(recent, 0, "fresh fees are recent, they never expire");
        assertEq(t.expiredRewardsOf(bob), 0);
        assertGe(imd.balanceOf(address(t)), t.accountedBalance());
    }

    // ------------------------------------------------------------ v4 final check (cbe092d6)

    /// Finding 2: expiry is strict; an inactive wallet that claims receives only what hasn't expired.
    function test_expiry_claimSendsExpiredPartToProtocol() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 10e18);
        uint256 owed = t.withdrawableDividendOf(bob);
        vm.warp(vm.getBlockTimestamp() + 60 days);
        uint256 before = imd.balanceOf(bob);
        vm.prank(bob);
        uint256 paid = t.claim();
        assertEq(paid, 0, "everything had expired");
        assertEq(imd.balanceOf(bob), before);
        assertEq(imd.balanceOf(FEE_RECIPIENT), owed);
        assertEq(t.totalRecycled(), owed);
        assertEq(t.lastActive(bob), vm.getBlockTimestamp(), "the claim still counts as activity");
    }

    function test_expiry_claimKeepsRecentPart() public {
        PadToken t = _launch();
        _buy(bob, t, 10e18);
        _buy(carol, t, 10e18); // day 0: R1
        uint256 r1 = t.withdrawableDividendOf(bob);
        vm.warp(vm.getBlockTimestamp() + 6 days);
        _buy(alice, t, 10e18); // day 6: R2
        uint256 r2 = t.withdrawableDividendOf(bob) - r1;
        vm.warp(vm.getBlockTimestamp() + 2 days); // day 8
        vm.prank(bob);
        uint256 paid = t.claim();
        assertApproxEqAbs(paid, r2, 1e6, "the recent rewards are paid");
        assertApproxEqAbs(imd.balanceOf(FEE_RECIPIENT), r1, 1e6, "the old ones went to the protocol");
        assertGe(imd.balanceOf(address(t)), t.accountedBalance());
    }

    /// Finding 1 (documented limit): a gift right after a distribution can delay the expiry of older rewards, but
    /// only until the gift is older than 7 days; nothing is lost and the token stays solvent.
    function test_expiry_giftInWindowOnlyDelays() public {
        PadToken t = _launch();
        uint256 t0 = vm.getBlockTimestamp();
        _buy(bob, t, 10e18);
        _buy(carol, t, 50e18); // day 0: bob's old rewards
        uint256 oldRewards = t.withdrawableDividendOf(bob);
        vm.warp(t0 + 6 days);
        _buy(alice, t, 200e18); // day 6: a distribution inside bob's window
        uint256 owed = t.withdrawableDividendOf(bob);
        uint256 carolBal = t.balanceOf(carol);
        vm.prank(carol);
        t.transfer(bob, carolBal); // a gift: not bob's activity
        assertEq(t.lastActive(bob), t0);

        vm.warp(t0 + 7 days + 1);
        uint256 early = t.expiredRewardsOf(bob);
        assertLe(early, oldRewards, "never more than the old rewards");
        vm.warp(t0 + 13 days + 1); // the day-6 distribution has left the window too
        assertEq(t.expiredRewardsOf(bob), owed, "everything older than 7 days expires");
        assertEq(t.recycle(bob), owed);
        assertGe(imd.balanceOf(address(t)), t.accountedBalance());
    }

    /// Finding 5: a 1-wei buy through a third-party router pays no fee but still counts as the buyer's activity.
    function test_expiry_oneWeiExternalBuyCounts() public {
        PadToken t = _launchWithOrder(true);
        _buy(bob, t, 10e18);
        PoolKey memory key = pad.poolKey(address(t));
        uint256 proto = pad.pendingProtocolFees(address(imd));
        vm.warp(vm.getBlockTimestamp() + 6 days);
        vm.prank(bob, bob);
        extRouter.swap(key, SwapParams(true, -1, TickMath.MIN_SQRT_PRICE + 1), settings, "");
        assertEq(pad.pendingProtocolFees(address(imd)), proto, "no fee on 1 wei");
        assertEq(t.lastActive(bob), vm.getBlockTimestamp());
    }

    /// Finding 5: ground truth. Random sequences of buys, partial sells, gifts to bob, external buys, warps, flushes,
    /// claims and recycles. bob's accumulated rewards are recorded after every step, so the rewards he earned at or
    /// before any cutoff are known exactly. Every recycle, and every claim's expired part, must stay within the
    /// rewards bob earned more than 7 days ago (net of what he already withdrew), and the token stays solvent.
    uint256[] internal _gtTime;
    uint256[] internal _gtAcc;

    function _record(PadToken t) internal {
        _gtTime.push(vm.getBlockTimestamp());
        _gtAcc.push(t.accumulativeDividendOf(bob));
    }

    function _earnedBy(uint256 cutoff) internal view returns (uint256 acc) {
        for (uint256 i; i < _gtTime.length; i++) {
            if (_gtTime[i] <= cutoff) acc = _gtAcc[i];
        }
    }

    function _checkTakenFromBob(PadToken t, uint256 taken, uint256 withdrawnBefore) internal view {
        uint256 now_ = vm.getBlockTimestamp();
        if (now_ <= 7 days + 1) return;
        uint256 old = _earnedBy(now_ - 7 days - 1);
        uint256 bound = old > withdrawnBefore ? old - withdrawnBefore : 0;
        assertLe(taken, bound + 2, "only rewards older than 7 days expire");
        assertGe(imd.balanceOf(address(t)), t.accountedBalance(), "solvent");
    }

    function testFuzz_expiryGroundTruth(uint256 seed) public {
        PadToken t = _launchWithOrder(true);
        PoolKey memory key = pad.poolKey(address(t));
        vm.prank(carol);
        t.approve(address(router), type(uint256).max);
        vm.prank(bob);
        t.approve(address(router), type(uint256).max);
        _buy(bob, t, 5e18);
        _record(t);
        for (uint256 i; i < 30; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = r % 9;
            uint256 amt = 1e16 + ((r >> 8) % 50e18);
            if (action == 0) {
                _buy(carol, t, amt);
            } else if (action == 1) {
                _buy(alice, t, amt);
            } else if (action == 2) {
                uint256 half = t.balanceOf(carol) / 2;
                if (half > 0) {
                    vm.prank(carol);
                    router.sell(address(t), half, 0, vm.getBlockTimestamp());
                }
            } else if (action == 3) {
                uint256 gift = t.balanceOf(carol) / (2 + (r >> 16) % 5);
                if (gift > 0) {
                    vm.prank(carol);
                    t.transfer(bob, gift);
                }
            } else if (action == 4) {
                vm.prank(alice, alice); // fees left pending until a later flush
                extRouter.swap(key, SwapParams(true, -int256(amt), TickMath.MIN_SQRT_PRICE + 1), settings, "");
            } else if (action == 5) {
                pad.flush(address(t));
            } else if (action == 6) {
                vm.warp(vm.getBlockTimestamp() + 1 hours + ((r >> 24) % 10 days));
            } else if (action == 7) {
                uint256 w = t.withdrawnDividends(bob);
                uint256 fr = imd.balanceOf(FEE_RECIPIENT);
                vm.prank(bob);
                t.claim();
                _checkTakenFromBob(t, imd.balanceOf(FEE_RECIPIENT) - fr, w);
            } else {
                uint256 w = t.withdrawnDividends(bob);
                uint256 owed = t.withdrawableDividendOf(bob);
                uint256 expired = t.recycle(bob);
                assertLe(expired, owed);
                assertEq(t.withdrawableDividendOf(bob), owed - expired);
                _checkTakenFromBob(t, expired, w);
            }
            _record(t);
        }
    }

    // ------------------------------------------------------------ v5: the creator's split of the 3%

    function _launchSplit(uint16 c, uint16 h, uint16 b, bool quoteIsCurrency0) internal returns (PadToken t) {
        for (uint256 i; i < 40; i++) {
            vm.prank(alice);
            t = PadToken(payable(pad.launchWithSplit("Split", "SPL", "", address(imd), PepesFamily.FeeSplit(c, h, b))));
            (,,,, bool q0) = pad.launches(address(t));
            if (q0 == quoteIsCurrency0) return t;
        }
        revert("ordering not found");
    }

    function test_split_rejectsBadSplits() public {
        uint16[3][6] memory bad = [
            [uint16(0), 300, 50], // sum 350
            [uint16(0), 250, 0], // sum 250
            [uint16(250), 50, 0], // creator above 2%
            [uint16(300), 0, 0], // creator above 2%
            [uint16(25), 275, 0], // not a 0.5% step
            [uint16(100), 100, 75] // not a 0.5% step, sum 275
        ];
        for (uint256 i; i < bad.length; i++) {
            vm.expectRevert(PepesFamily.BadSplit.selector);
            pad.launchWithSplit("X", "X", "", address(imd), PepesFamily.FeeSplit(bad[i][0], bad[i][1], bad[i][2]));
        }
        // every preset and a custom split are accepted and recorded
        uint16[3][5] memory ok = [[uint16(0), 300, 0], [uint16(200), 100, 0], [uint16(0), 0, 300], [uint16(100), 100, 100], [uint16(50), 150, 100]];
        for (uint256 i; i < ok.length; i++) {
            address tok = pad.launchWithSplit("X", "X", "", address(imd), PepesFamily.FeeSplit(ok[i][0], ok[i][1], ok[i][2]));
            (uint16 c, uint16 h, uint16 b) = pad.feeSplit(tok);
            assertEq(c, ok[i][0]);
            assertEq(h, ok[i][1]);
            assertEq(b, ok[i][2]);
            assertEq(pad.creatorPayout(tok), address(this));
        }
    }

    function test_split_routerLaunchDefaultsToHolders() public {
        vm.prank(bob);
        (address token,) = router.launch("D", "D", "", address(imd), 10e18, 1);
        (uint16 c, uint16 h, uint16 b) = pad.feeSplit(token);
        assertEq(c, 0);
        assertEq(h, 300);
        assertEq(b, 0);
        vm.prank(bob);
        (address t2, uint256 out) = router.launchWithSplit("F", "F", "", address(imd), RouterSplit(0, 0, 300), 10e18, 1);
        (,, b) = pad.feeSplit(t2);
        assertEq(b, 300);
        assertEq(PadToken(payable(t2)).balanceOf(bob), out);
        assertEq(pad.creatorPayout(t2), bob);
    }

    struct Moved {
        uint256 quote; // IMD the trader paid / received
        uint256 tokens; // tokens the trader received / paid
        uint256 proto;
        uint256 creator;
        uint256 holders;
        uint256 burned;
    }

    /// Third-party router swap; returns what moved, from the trader's side and from the pad's books.
    function _swapExt(PadToken t, bool isBuy, int256 amountSpecified) internal returns (Moved memory m) {
        (,,,, bool quoteIs0) = pad.launches(address(t));
        bool zeroForOne = isBuy == quoteIs0;
        PoolKey memory key = pad.poolKey(address(t));
        uint256 q0 = imd.balanceOf(bob);
        uint256 t0 = t.balanceOf(bob);
        uint256 p0 = pad.pendingProtocolFees(address(imd));
        uint256 c0 = pad.pendingCreatorFees(address(t));
        uint256 h0 = pad.pendingHolderFees(address(t));
        uint256 d0 = t.balanceOf(DEAD);
        vm.prank(bob);
        extRouter.swap(
            key,
            SwapParams(zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            settings,
            ""
        );
        m.quote = isBuy ? q0 - imd.balanceOf(bob) : imd.balanceOf(bob) - q0;
        m.tokens = isBuy ? t.balanceOf(bob) - t0 : t0 - t.balanceOf(bob);
        m.proto = pad.pendingProtocolFees(address(imd)) - p0;
        m.creator = pad.pendingCreatorFees(address(t)) - c0;
        m.holders = pad.pendingHolderFees(address(t)) - h0;
        m.burned = t.balanceOf(DEAD) - d0;
        assertEq(pad.totalBurned(address(t)) >= m.burned, true);
    }

    /// For every split and all four swap kinds, both currency orders: 1% protocol, the creator and holder shares of
    /// the trader's gross IMD, and the burn share of the trader's gross tokens burned.
    function test_split_feesForEverySwapKind() public {
        uint16[3][5] memory splits = [[uint16(0), 300, 0], [uint16(200), 100, 0], [uint16(0), 0, 300], [uint16(100), 100, 100], [uint16(50), 150, 100]];
        for (uint256 i; i < splits.length; i++) {
            for (uint256 o; o < 2; o++) {
                PadToken t = _launchSplit(splits[i][0], splits[i][1], splits[i][2], o == 0);
                _buy(alice, t, 20e18);
                vm.prank(bob);
                t.approve(address(extRouter), type(uint256).max);
                _checkSplit(t, splits[i], _swapExt(t, true, -5e18), true); // exact-in buy
                _checkSplit(t, splits[i], _swapExt(t, true, 1_000_000e18), true); // exact-out buy
                _checkSplit(t, splits[i], _swapExt(t, false, -500_000e18), false); // exact-in sell
                _checkSplit(t, splits[i], _swapExt(t, false, 0.5e18), false); // exact-out sell
                _assertClaimsBacked();
            }
        }
    }

    function _checkSplit(PadToken, uint16[3] memory sp, Moved memory m, bool isBuy) internal pure {
        uint256 fee = m.proto + m.creator + m.holders;
        // gross IMD: a buyer pays pool + fee; a seller gets pool - fee
        uint256 grossQ = isBuy ? m.quote : m.quote + fee;
        // gross tokens: a buyer gets pool - burn; a seller pays pool + burn
        uint256 grossT = isBuy ? m.tokens + m.burned : m.tokens;
        assertApproxEqAbs(m.proto, grossQ / 100, 3, "protocol 1%");
        assertApproxEqAbs(m.creator, (grossQ * sp[0]) / 10_000, 3, "creator share");
        assertApproxEqAbs(m.holders, (grossQ * sp[1]) / 10_000, 3, "holder share");
        assertApproxEqAbs(m.burned, (grossT * sp[2]) / 10_000, 3, "burn share");
    }

    /// The pad's ERC-6909 IMD claims always equal what it owes: protocol + every token's holder and creator fees.
    function _assertClaimsBacked() internal view {
        uint256 owed = pad.pendingProtocolFees(address(imd));
        for (uint256 i; i < pad.tokenCount(); i++) {
            address tok = pad.allTokens(i);
            owed += pad.pendingHolderFees(tok) + pad.pendingCreatorFees(tok);
        }
        assertEq(pm.balanceOf(address(pad), uint256(uint160(address(imd)))), owed, "claims backed");
    }

    function test_split_creatorFeesCollectAndPayout() public {
        vm.prank(alice);
        address tok = pad.launchWithSplit("C", "C", "", address(imd), PepesFamily.FeeSplit(200, 100, 0));
        PadToken t = PadToken(payable(tok));
        _buy(bob, t, 100e18);
        assertEq(pad.pendingCreatorFees(tok), 2e18, "2% of 100 IMD");
        vm.prank(carol); // anyone can trigger, it always pays the payout address
        pad.collectCreatorFees(tok);
        assertEq(imd.balanceOf(alice), 1_000_000e18 + 2e18);
        assertEq(pad.pendingCreatorFees(tok), 0);

        vm.prank(carol);
        vm.expectRevert(PepesFamily.NotCreator.selector);
        pad.setCreatorPayout(tok, carol);
        address treasury = makeAddr("creatorTreasury");
        vm.prank(alice);
        pad.setCreatorPayout(tok, treasury);
        _buy(bob, t, 50e18);
        pad.collectCreatorFees(tok);
        assertEq(imd.balanceOf(treasury), 1e18);
        vm.prank(alice);
        vm.expectRevert(PepesFamily.NotCreator.selector);
        pad.setCreatorPayout(tok, alice); // the old payout address lost the role
        _assertClaimsBacked();
    }

    function test_split_deflationaryBurnsAndEveryoneCanExit() public {
        PadToken t = _launchSplit(0, 0, 300, true);
        uint256 dead0 = t.balanceOf(DEAD);
        _buy(bob, t, 30e18);
        _buy(carol, t, 50e18);
        assertEq(pad.pendingHolderFees(address(t)), 0, "no holder share");
        _sell(carol, t, t.balanceOf(carol));
        _sell(bob, t, t.balanceOf(bob));
        uint256 burned = t.balanceOf(DEAD) - dead0;
        assertGt(burned, 0);
        assertEq(burned, pad.totalBurned(address(t)));
        assertEq(t.balanceOf(address(pm)) + t.balanceOf(DEAD), SUPPLY, "every token is in the pool or burned");
        assertEq(pad.pendingProtocolFees(address(imd)) > 0, true);
        _assertClaimsBacked();
    }

    /// Random splits and trades: the pad's claims stay backed and fees + burn match the split.
    function testFuzz_split(uint8 cSteps, uint8 bSteps, uint96 a, uint96 b) public {
        uint16 c = uint16(bound(cSteps, 0, 4)) * 50;
        uint16 bu = uint16(bound(bSteps, 0, (300 - c) / 50)) * 50;
        uint16 h = 300 - c - bu;
        PadToken t = _launchSplit(c, h, bu, uint256(a) % 2 == 0);
        _buy(alice, t, bound(a, 1e15, 500e18));
        vm.prank(bob);
        t.approve(address(extRouter), type(uint256).max);
        uint16[3] memory sp = [c, h, bu];
        _checkSplit(t, sp, _swapExt(t, true, -int256(bound(b, 1e15, 300e18))), true);
        uint256 bal = t.balanceOf(bob);
        if (bal > 1e18) _checkSplit(t, sp, _swapExt(t, false, -int256(bal / 2)), false);
        _sell(alice, t, t.balanceOf(alice));
        pad.collectProtocolFees(address(imd));
        pad.collectCreatorFees(address(t));
        pad.flush(address(t));
        _assertClaimsBacked();
        assertGe(imd.balanceOf(address(t)), t.accountedBalance());
    }
}
