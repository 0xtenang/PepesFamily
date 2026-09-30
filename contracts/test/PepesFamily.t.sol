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
import {PepesFamilyRouter} from "../src/PepesFamilyRouter.sol";
import {PadToken} from "../src/PadToken.sol";
import {DeployLib} from "../script/DeployLib.sol";

contract MockIMD {
    string public name = "Identity.md";
    string public symbol = "IMD";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address s, uint256 amt) external returns (bool) {
        allowance[msg.sender][s] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract PepesFamilyTest is Test {
    address constant FEE_RECIPIENT = 0x3c8A4d94B3219F6633F2cC94094f4765b30c691C;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant ETH_START_MCAP = 1.5 ether;
    uint256 constant IMD_START_MCAP = 100e18;

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
                DeployLib.startTickForMarketCap(ETH_START_MCAP),
                DeployLib.startTickForMarketCap(IMD_START_MCAP)
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

    function pad_flags() internal pure returns (uint160) {
        return uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    }

    // ------------------------------------------------------------ helpers

    function _launch(address quote) internal returns (PadToken t) {
        vm.prank(alice);
        t = PadToken(payable(pad.launch("Test", "TST", '{"image":""}', quote)));
    }

    function _buy(address who, PadToken t, uint256 amt) internal returns (uint256) {
        uint256 value = t.quote() == address(0) ? amt : 0;
        vm.prank(who);
        return router.buy{value: value}(address(t), amt, 0, block.timestamp);
    }

    function _sell(address who, PadToken t, uint256 amt) internal returns (uint256) {
        vm.prank(who);
        return router.sell(address(t), amt, 0, block.timestamp);
    }

    function _quoteBal(address quote, address who) internal view returns (uint256) {
        return quote == address(0) ? who.balance : imd.balanceOf(who);
    }

    /// @dev Launches IMD tokens until one has the wanted currency ordering.
    function _launchImdWithOrder(bool quoteIsCurrency0) internal returns (PadToken t) {
        for (uint256 i; i < 40; i++) {
            t = _launch(address(imd));
            (,,,, bool q0) = pad.launches(address(t));
            if (q0 == quoteIsCurrency0) return t;
        }
        revert("ordering not found");
    }

    // -------------------------------------------------------------- tests

    function test_hookAddressAndRouter() public view {
        assertEq(uint160(address(pad)) & 0x3FFF, pad.HOOK_FLAGS());
        assertEq(address(router.pad()), address(pad));
        assertEq(pad.feeRecipient(), FEE_RECIPIENT);
        assertEq(pad.owner(), owner);
    }

    function test_onlyEthOrImd() public {
        vm.expectRevert(PepesFamily.UnsupportedQuote.selector);
        pad.launch("X", "X", "", address(0xBEEF));
    }

    function test_launchLocksWholeSupplyInPool() public {
        PadToken t = _launch(address(0));
        assertEq(t.balanceOf(address(pm)) + t.balanceOf(DEAD), SUPPLY);
        assertLt(t.balanceOf(DEAD), 1e10); // rounding buffer, burned
        assertEq(t.balanceOf(address(pad)), 0);
        assertEq(t.creator(), alice);
        uint256 mc = pad.marketCap(address(t));
        assertApproxEqRel(mc, ETH_START_MCAP, 0.025e18);
        assertGe(mc, ETH_START_MCAP);
    }

    function test_launchBothOrderings_imd() public {
        PadToken a = _launchImdWithOrder(true);
        PadToken b = _launchImdWithOrder(false);
        assertApproxEqRel(pad.marketCap(address(a)), IMD_START_MCAP, 0.025e18);
        assertApproxEqRel(pad.marketCap(address(b)), IMD_START_MCAP, 0.025e18);
        // Trading works on both orientations, and price moves up on buys.
        uint256 mcA = pad.marketCap(address(a));
        uint256 mcB = pad.marketCap(address(b));
        _buy(bob, a, 10e18);
        _buy(bob, b, 10e18);
        assertGt(pad.marketCap(address(a)), mcA);
        assertGt(pad.marketCap(address(b)), mcB);
        _sell(bob, a, a.balanceOf(bob));
        _sell(bob, b, b.balanceOf(bob));
    }

    function test_routerBuyFeeSplit() public {
        PadToken t = _launch(address(0));
        uint256 out = _buy(bob, t, 1 ether);
        assertGt(out, 0);
        assertEq(t.balanceOf(bob), out);
        assertEq(pad.pendingProtocolFees(address(0)), 0.01 ether);
        assertEq(pad.pendingHolderFees(address(t)), 0); // router flushed it
        assertEq(address(t).balance, 0.03 ether); // waiting: bob only got tokens after the flush

        _buy(carol, t, 1 ether);
        assertEq(pad.pendingProtocolFees(address(0)), 0.02 ether);
        assertApproxEqAbs(t.withdrawableDividendOf(bob), 0.06 ether, 10); // both fees, bob was the only holder
        assertEq(t.withdrawableDividendOf(carol), 0);

        pad.collectProtocolFees(address(0));
        assertEq(FEE_RECIPIENT.balance, 0.02 ether);
        assertEq(pad.pendingProtocolFees(address(0)), 0);
    }

    function test_holdersPaidProRata() public {
        PadToken t = _launch(address(0));
        _buy(bob, t, 1 ether);
        _buy(carol, t, 3 ether);
        uint256 bBal = t.balanceOf(bob);
        uint256 cBal = t.balanceOf(carol);
        uint256 bBefore = t.withdrawableDividendOf(bob);
        uint256 cBefore = t.withdrawableDividendOf(carol);

        _buy(alice, t, 2 ether); // 0.06 ETH to bob + carol by balance
        uint256 bGain = t.withdrawableDividendOf(bob) - bBefore;
        uint256 cGain = t.withdrawableDividendOf(carol) - cBefore;
        assertApproxEqAbs(bGain + cGain, 0.06 ether, 10);
        assertApproxEqRel(bGain * cBal, cGain * bBal, 1e9);

        uint256 ethBefore = bob.balance;
        vm.prank(bob);
        uint256 claimed = t.claim();
        assertEq(bob.balance - ethBefore, claimed);
        assertEq(t.withdrawableDividendOf(bob), 0);
    }

    function test_routerSellFee() public {
        PadToken t = _launch(address(0));
        _buy(bob, t, 1 ether);
        _buy(carol, t, 1 ether);
        uint256 protoBefore = pad.pendingProtocolFees(address(0));
        uint256 carolDivBefore = t.withdrawableDividendOf(carol);
        uint256 bobDivBefore = t.withdrawableDividendOf(bob);

        uint256 ethBefore = carol.balance;
        uint256 out = _sell(carol, t, t.balanceOf(carol));
        assertEq(carol.balance - ethBefore, out);
        // gross = out / 0.96; protocol 1% of gross, holders 3% of gross
        uint256 gross = (out * 10_000) / 9_600;
        assertApproxEqAbs(pad.pendingProtocolFees(address(0)) - protoBefore, gross / 100, 1e6);
        assertApproxEqAbs(t.withdrawableDividendOf(bob) - bobDivBefore, (gross * 3) / 100, 1e6);
        assertEq(t.withdrawableDividendOf(carol), carolDivBefore); // no gain from own sell
    }

    function test_externalRouter_allSwapKinds_eth() public {
        PadToken t = _launch(address(0));
        _buy(alice, t, 1 ether); // alice is a holder so holder fees get distributed
        PoolKey memory key = pad.poolKey(address(t));
        vm.prank(bob);
        t.approve(address(extRouter), type(uint256).max);

        // exact-in buy: 1 ETH in -> fee 0.04
        _checkExternal(key, t, true, -1 ether, 1 ether);
        // exact-out buy: 1M tokens out
        _checkExternal(key, t, true, 1_000_000e18, 1 ether);
        // exact-in sell: 500k tokens in
        _checkExternal(key, t, false, -500_000e18, 0);
        // exact-out sell: 0.01 ETH out
        _checkExternal(key, t, false, 0.01 ether, 0);
    }

    function test_externalRouter_allSwapKinds_imdBothOrders() public {
        for (uint256 o; o < 2; o++) {
            PadToken t = _launchImdWithOrder(o == 0);
            _buy(alice, t, 10e18);
            PoolKey memory key = pad.poolKey(address(t));
            vm.prank(bob);
            t.approve(address(extRouter), type(uint256).max);
            _checkExternal(key, t, true, -5e18, 0);
            _checkExternal(key, t, true, 1_000_000e18, 0);
            _checkExternal(key, t, false, -500_000e18, 0);
            _checkExternal(key, t, false, 0.5e18, 0);
        }
    }

    /// @dev Swaps through a third-party router and checks the trader paid/received exactly 4% on the quote side.
    function _checkExternal(PoolKey memory key, PadToken t, bool isBuy, int256 amountSpecified, uint256 value)
        internal
    {
        address quote = t.quote();
        (,,,, bool quoteIs0) = pad.launches(address(t));
        bool zeroForOne = isBuy == quoteIs0;
        uint256 qBefore = _quoteBal(quote, bob);
        uint256 tBefore = t.balanceOf(bob);
        uint256 protoBefore = pad.pendingProtocolFees(quote);
        uint256 holderBefore = pad.pendingHolderFees(address(t));

        vm.prank(bob);
        extRouter.swap{value: value}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ""
        );

        uint256 quoteMoved = isBuy ? qBefore - _quoteBal(quote, bob) : _quoteBal(quote, bob) - qBefore;
        uint256 tokenMoved = isBuy ? t.balanceOf(bob) - tBefore : tBefore - t.balanceOf(bob);
        assertGt(tokenMoved, 0);
        uint256 proto = pad.pendingProtocolFees(quote) - protoBefore;
        uint256 holders = pad.pendingHolderFees(address(t)) - holderBefore;
        uint256 fee = proto + holders;
        // buyer paid gross = pool + fee; seller received pool - fee. Either way fee is 4% of the gross quote side.
        uint256 gross = isBuy ? quoteMoved : quoteMoved + fee;
        assertApproxEqAbs(fee, (gross * 4) / 100, 2, "fee is 4%");
        assertApproxEqAbs(proto * 3, holders, 3, "1% / 3% split");
        if (amountSpecified < 0 && isBuy) assertEq(quoteMoved, uint256(-amountSpecified));
        if (amountSpecified > 0 && !isBuy) assertEq(quoteMoved, uint256(amountSpecified));

        // Pending holder fees reach holders on flush (claim does it automatically).
        uint256 aliceBefore = t.withdrawableDividendOf(alice);
        pad.flush(address(t));
        assertEq(pad.pendingHolderFees(address(t)), 0);
        assertGt(t.withdrawableDividendOf(alice), aliceBefore);
    }

    function test_claimFlushesPendingFees() public {
        PadToken t = _launch(address(0));
        _buy(alice, t, 1 ether);
        PoolKey memory key = pad.poolKey(address(t));
        vm.prank(bob);
        extRouter.swap{value: 1 ether}(
            key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), settings, ""
        );
        assertGt(pad.pendingHolderFees(address(t)), 0);
        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 got = t.claim();
        // alice's own buy fee waited for a holder; both fees are spread at flush time over alice and bob
        // (external-router trades are flushed later, so bob shares in his own fee)
        assertApproxEqAbs(got + t.withdrawableDividendOf(bob), 0.06 ether, 10);
        assertApproxEqRel(got * t.balanceOf(bob), t.withdrawableDividendOf(bob) * t.balanceOf(alice), 1e9);
        assertEq(alice.balance - before, got);
        assertEq(pad.pendingHolderFees(address(t)), 0);
    }

    function test_transferMovesFutureDividendsOnly() public {
        PadToken t = _launch(address(0));
        _buy(bob, t, 1 ether);
        _buy(alice, t, 1 ether);
        uint256 earned = t.withdrawableDividendOf(bob);
        uint256 bal = t.balanceOf(bob);
        vm.prank(bob);
        t.transfer(carol, bal);
        assertEq(t.withdrawableDividendOf(bob), earned);
        assertEq(t.withdrawableDividendOf(carol), 0);
    }

    function test_everyoneCanExit() public {
        PadToken t = _launch(address(0));
        _buy(bob, t, 3 ether);
        _buy(carol, t, 5 ether);
        _buy(alice, t, 2 ether);
        _sell(carol, t, t.balanceOf(carol));
        _sell(alice, t, t.balanceOf(alice));
        _sell(bob, t, t.balanceOf(bob));
        assertApproxEqRel(pad.marketCap(address(t)), pad.marketCap(address(t)), 0);
        assertGe(t.balanceOf(address(pm)), SUPPLY - 1e10 - 10); // pool got (almost) every token back
    }

    function test_routerLaunchWithInitialBuy_imd() public {
        vm.prank(bob);
        (address token, uint256 out) = router.launch("Imd Cat", "ICAT", "", address(imd), 50e18, 1);
        PadToken t = PadToken(payable(token));
        assertEq(t.creator(), bob);
        assertEq(t.balanceOf(bob), out);
        assertEq(pad.pendingProtocolFees(address(imd)), 0.5e18);
        assertEq(imd.balanceOf(token), 1.5e18);
    }

    function test_routerLaunchWithInitialBuy_eth() public {
        vm.prank(bob);
        (address token, uint256 out) = router.launch{value: 0.5 ether}("E", "E", "", address(0), 0.5 ether, 1);
        assertEq(PadToken(payable(token)).balanceOf(bob), out);
        assertEq(address(router).balance, 0);
    }

    function test_cannotCreatePoolsOrAddLiquidityWithHook() public {
        PadToken t = _launch(address(0));
        PoolKey memory key = pad.poolKey(address(t));

        PoolKey memory other = key;
        other.tickSpacing = 60;
        vm.expectRevert();
        pm.initialize(other, TickMath.getSqrtPriceAtTick(0));

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        vm.expectRevert();
        lp.modifyLiquidity{value: 1 ether}(key, ModifyLiquidityParams(-600, 600, 1e18, 0), "");
    }

    function test_slippageAndDeadline() public {
        PadToken t = _launch(address(0));
        vm.prank(bob);
        vm.expectRevert(PepesFamilyRouter.Slippage.selector);
        router.buy{value: 1 ether}(address(t), 1 ether, type(uint256).max, block.timestamp);

        vm.prank(bob);
        vm.expectRevert(PepesFamilyRouter.Expired.selector);
        router.buy{value: 1 ether}(address(t), 1 ether, 0, block.timestamp - 1);

        vm.prank(bob);
        vm.expectRevert(PepesFamilyRouter.BadAmount.selector);
        router.buy{value: 1 ether}(address(t), 2 ether, 0, block.timestamp);
    }

    function test_onlyOwnerAdmin() public {
        vm.prank(bob);
        vm.expectRevert(PepesFamily.NotOwner.selector);
        pad.setFeeRecipient(bob);

        vm.prank(owner);
        pad.setStartTick(address(0), DeployLib.startTickForMarketCap(3 ether));
        PadToken t = _launch(address(0));
        assertApproxEqRel(pad.marketCap(address(t)), 3 ether, 0.025e18);

        vm.prank(owner);
        vm.expectRevert(PepesFamily.BadTick.selector);
        pad.setStartTick(address(0), 201);
    }

    function testFuzz_buySellFeesAndSolvency(uint96 a, uint96 b) public {
        uint256 buyA = bound(a, 1e12, 200 ether);
        uint256 buyB = bound(b, 1e12, 200 ether);
        PadToken t1 = _launch(address(0));
        PadToken t2 = _launch(address(0));
        _buy(bob, t1, buyA);
        _buy(carol, t2, buyB);
        uint256 bal = t1.balanceOf(bob);
        uint256 got = _sell(bob, t1, bal);
        assertLt(got, buyA); // round trip always loses the fees

        // everything owed is backed: fee claims + token contract dividend balances
        pad.collectProtocolFees(address(0));
        vm.prank(carol);
        t2.claim();
        assertApproxEqAbs(
            FEE_RECIPIENT.balance, (buyA + buyB + ((got * 10_000) / 9_600)) / 100, 1e6, "protocol got 1% of volume"
        );
    }
}
