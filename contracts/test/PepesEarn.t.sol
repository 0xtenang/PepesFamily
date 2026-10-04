// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

import {PepesEarnPad} from "../src/earn/PepesEarnPad.sol";
import {PepesEarnToken} from "../src/earn/PepesEarnToken.sol";
import {PepesEarnMirror} from "../src/earn/PepesEarnMirror.sol";
import {PepesEarnRenderer} from "../src/earn/PepesEarnRenderer.sol";
import {PepesFamilyRouter} from "../src/PepesFamilyRouter.sol";
import {PepesFamilyEthRouter} from "../src/PepesFamilyEthRouter.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {LibEarnString} from "../src/earn/LibEarnString.sol";
import {MockIMD} from "./PepesFamily.t.sol";

/// @dev Stands in for $Pepes: any ERC20 the buyback router can mint.
contract MockPepes is MockIMD {}

/// @dev Stands in for the PepesFamily v1 router: buys "Pepes" with IMD at 1,000 Pepes per IMD for msg.sender.
contract MockPepesRouter {
    MockIMD immutable imd;
    MockPepes immutable pepes;

    constructor(MockIMD imd_, MockPepes pepes_) {
        imd = imd_;
        pepes = pepes_;
    }

    function buy(address token, uint256 amountIn, uint256 minOut, uint256 deadline) external payable returns (uint256 out) {
        require(token == address(pepes) && block.timestamp <= deadline, "bad");
        imd.transferFrom(msg.sender, address(this), amountIn);
        out = amountIn * 1000;
        require(out >= minOut, "slippage");
        pepes.mint(msg.sender, out);
    }
}

/// @notice The v3 audit attack against $EARN: borrow the pool's $EARN inside an unlock, then claim/distribute.
contract EarnFlashHolder is IUnlockCallback {
    IPoolManager immutable pm;
    PepesEarnToken immutable t;
    uint8 mode;

    constructor(IPoolManager pm_, PepesEarnToken t_) {
        pm = pm_;
        t = t_;
    }

    function run(uint8 mode_) external {
        mode = mode_;
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        uint256 borrowed = t.balanceOf(address(pm));
        pm.take(Currency.wrap(address(t)), address(this), borrowed);
        if (mode == 1) t.distribute();
        else t.claim();
        pm.sync(Currency.wrap(address(t)));
        t.transfer(address(pm), borrowed);
        pm.settle();
        return "";
    }
}

contract PepesEarnTest is Test {
    address constant FEE_RECIPIENT = 0x3c8A4d94B3219F6633F2cC94094f4765b30c691C;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 constant SUPPLY = 2_000e18;
    uint256 constant START_MCAP = 2_000e18; // 1 IMD per NFT

    PoolManager pm;
    MockIMD imd;
    MockPepes pepes;
    MockPepesRouter pepesRouter;
    PepesEarnPad pad;
    PepesEarnToken earn;
    PepesEarnMirror mirror;
    PepesEarnRenderer renderer;
    PepesFamilyRouter router;
    PepesFamilyEthRouter ethRouter;
    PoolSwapTest extRouter;
    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dan = makeAddr("dan");
    address owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new PoolManager(address(this));
        imd = new MockIMD();
        pepes = new MockPepes();
        pepesRouter = new MockPepesRouter(imd, pepes);
        extRouter = new PoolSwapTest(pm);
        renderer = new PepesEarnRenderer();

        // IMD/ETH pool for the ETH router and royalty conversion: 1 ETH = 1 IMD, deep full-range liquidity.
        PoolKey memory imdEth = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 100, IHooks(address(0)));
        pm.initialize(imdEth, TickMath.getSqrtPriceAtTick(0));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        vm.deal(address(this), 100_000 ether);
        imd.mint(address(this), 100_000e18);
        imd.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 20_000 ether}(imdEth, ModifyLiquidityParams(-887200, 887200, 10_000e18, 0), "");

        bytes memory initCode = abi.encodePacked(
            type(PepesEarnPad).creationCode,
            abi.encode(
                pm,
                address(imd),
                owner,
                FEE_RECIPIENT,
                DeployLib.startTickForMarketCap(START_MCAP, SUPPLY),
                PepesEarnPad.ImdEthPool(10_000, 100, address(0))
            )
        );
        (bytes32 salt, address expected) = DeployLib.mineSalt(address(this), _flags(), initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed == expected, "hook address");
        pad = PepesEarnPad(payable(deployed));
        router = PepesFamilyRouter(payable(pad.router()));
        ethRouter = PepesFamilyEthRouter(payable(pad.ethRouter()));

        mirror = new PepesEarnMirror(address(pad));
        earn = new PepesEarnToken(address(pad), address(mirror), address(renderer), address(pepes), address(pepesRouter));
        vm.prank(owner);
        pad.launch(address(earn));

        address[5] memory users = [alice, bob, carol, dan, address(this)];
        for (uint256 i; i < users.length; i++) {
            vm.deal(users[i], 1_000 ether);
            imd.mint(users[i], 1_000_000e18);
            vm.startPrank(users[i]);
            imd.approve(address(router), type(uint256).max);
            imd.approve(address(extRouter), type(uint256).max);
            earn.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    receive() external payable {}

    function _flags() internal pure returns (uint160) {
        return uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    }

    function _buy(address who, uint256 imdIn) internal returns (uint256) {
        vm.prank(who);
        return router.buy(address(earn), imdIn, 0, block.timestamp);
    }

    function _sell(address who, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return router.sell(address(earn), amount, 0, block.timestamp);
    }

    /// @dev Any NFT id currently owned by `who` (ids are 1..2000).
    function _anyIdOf(address who) internal view returns (uint256) {
        for (uint256 id = 1; id <= 2000; id++) {
            if (mirror.ownerAt(id) == who) return id;
        }
        revert("no nft");
    }

    // ------------------------------------------------------------ launch

    function test_launch_locksWholeSupplyInPool() public view {
        assertEq(earn.totalSupply(), SUPPLY);
        assertApproxEqAbs(earn.balanceOf(address(pm)), SUPPLY, 1e9);
        assertEq(earn.balanceOf(address(pad)), 0);
        assertEq(mirror.totalSupply(), 0, "no NFTs before anyone buys");
        assertEq(earn.eligibleSupply(), 0);
        assertEq(pad.token(), address(earn));
        // starting market cap ~2,000 IMD (start tick is rounded down to the tick spacing)
        assertApproxEqRel(pad.marketCap(address(earn)), START_MCAP, 0.03e18);
    }

    function test_launch_onlyOnceAndOnlyOwner() public {
        vm.prank(owner);
        vm.expectRevert(PepesEarnPad.AlreadyLaunched.selector);
        pad.launch(address(earn));
        vm.prank(bob);
        vm.expectRevert(PepesEarnPad.NotOwner.selector);
        pad.launch(address(earn));
        vm.expectRevert(PepesEarnPad.NotSupported.selector);
        router.launch("x", "x", "", address(imd), 0, 0);
    }

    // ------------------------------------------------------------ trading and NFTs

    function test_buy_mintsOneNftPerWholeToken() public {
        uint256 got = _buy(alice, 10e18);
        assertGt(got, 9e18);
        assertEq(earn.balanceOf(alice), got);
        assertEq(mirror.balanceOf(alice), got / 1e18);
        assertEq(mirror.ownerOf(1), alice, "first buyer gets #1");
        // 1% protocol, 3% holders (nobody held before, so it waits in the token)
        assertEq(pad.pendingProtocolFees(address(imd)), 0.1e18);
        assertEq(imd.balanceOf(address(earn)), 0.3e18);
    }

    function test_sell_burnsNfts() public {
        uint256 got = _buy(alice, 10e18);
        uint256 nfts = mirror.balanceOf(alice);
        _sell(alice, 1e18);
        assertEq(mirror.balanceOf(alice), nfts - 1);
        uint256 imdBefore = imd.balanceOf(alice);
        _sell(alice, got - 1e18);
        assertEq(earn.balanceOf(alice), 0);
        assertEq(mirror.balanceOf(alice), 0);
        assertGt(imd.balanceOf(alice), imdBefore);
    }

    function test_buyWithEth_throughEthRouter() public {
        vm.prank(alice);
        uint256 got = ethRouter.buyWithEth{value: 5 ether}(address(earn), 0, block.timestamp);
        assertGt(got, 4e18);
        assertEq(earn.balanceOf(alice), got);
        assertEq(mirror.balanceOf(alice), got / 1e18);
    }

    function test_contractsGetNoNfts_but7702WalletsDo() public {
        // EIP-7702 smart account: code is 0xef0100 || delegate
        vm.etch(dan, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        _buy(dan, 10e18);
        assertGt(mirror.balanceOf(dan), 0, "7702 wallet should receive NFTs");

        address vault = address(new MockIMD()); // any ordinary contract
        imd.mint(vault, 100e18);
        vm.prank(vault);
        imd.approve(address(router), type(uint256).max);
        _buy(vault, 10e18);
        assertGt(earn.balanceOf(vault), 0);
        assertEq(mirror.balanceOf(vault), 0, "contracts hold tokens only");
    }

    // ------------------------------------------------------------ rewards

    function test_rewards_paidToHoldersInImd_notToOwnTrade() public {
        _buy(bob, 10e18);
        _buy(alice, 100e18);
        // bob held all eligible supply when alice's 3 IMD were distributed (plus the 0.3 IMD from bob's own first
        // buy that waited for a holder)
        assertApproxEqAbs(earn.withdrawableDividendOf(bob), 3.3e18, 10);
        assertEq(earn.withdrawableDividendOf(alice), 0, "buyer earns nothing from its own trade");
        uint256 before = imd.balanceOf(bob);
        vm.prank(bob);
        uint256 paid = earn.claim();
        assertEq(imd.balanceOf(bob) - before, paid);
        assertEq(earn.withdrawableDividendOf(bob), 0);
    }

    function test_rewards_stayWithSellerAfterNftTransfer() public {
        _buy(alice, 50e18);
        _buy(bob, 50e18);
        uint256 aliceEarned = earn.withdrawableDividendOf(alice);
        assertGt(aliceEarned, 1e18);
        uint256 eligible = earn.eligibleSupply();

        uint256 id = _anyIdOf(alice);
        vm.prank(alice);
        mirror.transferFrom(alice, carol, id); // e.g. a marketplace sale
        assertEq(earn.balanceOf(carol), 1e18);
        assertEq(mirror.ownerOf(id), carol);
        assertEq(earn.withdrawableDividendOf(alice), aliceEarned, "seller keeps what it earned");
        assertEq(earn.withdrawableDividendOf(carol), 0, "buyer earns only from now on");
        assertEq(earn.eligibleSupply(), eligible);

        _buy(dan, 100e18); // 3 IMD to holders
        uint256 carolShare = earn.withdrawableDividendOf(carol);
        assertApproxEqRel(carolShare, (3e18 * 1e18) / eligible, 1e12);
    }

    function test_noPermit2DefaultAllowance() public {
        _buy(alice, 10e18);
        assertEq(earn.allowance(alice, PERMIT2), 0);
    }

    // ------------------------------------------------------------ 30-day expiry

    function test_expiry_onlyRewardsOlderThan30DaysOfAnInactiveWallet() public {
        _buy(alice, 100e18); // t0: alice active
        _buy(bob, 100e18); // alice earns A1 at t0
        uint256 a1 = earn.withdrawableDividendOf(alice);
        assertGt(a1, 0);

        vm.warp(block.timestamp + 20 days);
        _buy(carol, 100e18); // alice earns A2 at t0+20d
        uint256 a2 = earn.withdrawableDividendOf(alice) - a1;
        assertGt(a2, 0);

        vm.warp(block.timestamp + 9 days); // t0+29d: alice still active (last activity t0)
        assertEq(earn.expiredRewardsOf(alice), 0);
        vm.expectRevert(); // nothing happens, but recycle returns 0 rather than reverting
        this.recycleMustTakeSomething(alice);

        vm.warp(block.timestamp + 6 days); // t0+35d: cutoff t0+5d -> A1 expired, A2 (t0+20d) is recent
        assertApproxEqAbs(earn.expiredRewardsOf(alice), a1, 2);
        uint256 taken = earn.recycle(alice);
        assertApproxEqAbs(taken, a1, 2);
        assertEq(earn.buybackReserve(), taken);
        assertApproxEqAbs(earn.withdrawableDividendOf(alice), a2, 2, "recent rewards stay claimable");
        assertEq(earn.expiredRewardsOf(alice), 0);

        // bob only earned at t0+20d: nothing of his has expired
        assertEq(earn.expiredRewardsOf(bob), 0);

        // the reserve is not redistributed by later trades
        uint256 distributedBefore = earn.totalDividendsDistributed();
        _buy(dan, 100e18);
        assertEq(earn.totalDividendsDistributed() - distributedBefore, 3e18);
        assertEq(imd.balanceOf(address(earn)), earn.accountedBalance() + earn.buybackReserve());
    }

    function recycleMustTakeSomething(address who) external {
        require(earn.recycle(who) > 0, "nothing");
    }

    function test_expiry_claimOrTransferResetsTheTimer() public {
        _buy(alice, 100e18);
        _buy(bob, 100e18);
        vm.warp(block.timestamp + 31 days);
        assertGt(earn.expiredRewardsOf(alice), 0);
        vm.prank(alice);
        earn.claim(); // claiming (any amount) resets the 30 days
        assertEq(earn.expiredRewardsOf(alice), 0);

        _buy(carol, 100e18); // alice earns again
        vm.warp(block.timestamp + 31 days);
        assertGt(earn.expiredRewardsOf(alice), 0);
        vm.prank(alice);
        earn.transfer(dan, 1); // moving any $EARN resets it too
        assertEq(earn.expiredRewardsOf(alice), 0);
    }

    function test_expiry_cannotRecycleSystemAccounts() public {
        vm.expectRevert(PepesEarnToken.NotEligible.selector);
        earn.recycle(address(pm));
        vm.expectRevert(PepesEarnToken.NotEligible.selector);
        earn.recycle(address(pad));
    }

    // ------------------------------------------------------------ $Pepes buyback and burn

    function _makeReserve() internal returns (uint256 reserve) {
        _buy(alice, 100e18);
        _buy(bob, 100e18);
        vm.warp(block.timestamp + 31 days);
        reserve = earn.recycle(alice);
        assertGt(reserve, 0);
    }

    function test_buyback_burnsPepesWithReserveOnly() public {
        uint256 reserve = _makeReserve();
        vm.prank(bob);
        vm.expectRevert(PepesEarnToken.NotOwner.selector);
        earn.buybackAndBurnPepes(reserve, 0, block.timestamp);

        vm.prank(owner);
        vm.expectRevert(PepesEarnToken.BadAmount.selector);
        earn.buybackAndBurnPepes(reserve + 1, 0, block.timestamp);

        uint256 owedToHolders = earn.accountedBalance();
        vm.prank(owner);
        uint256 burned = earn.buybackAndBurnPepes(reserve, reserve * 1000, block.timestamp);
        assertEq(burned, reserve * 1000);
        assertEq(pepes.balanceOf(DEAD), burned);
        assertEq(pepes.balanceOf(address(earn)), 0);
        assertEq(earn.buybackReserve(), 0);
        assertEq(earn.totalPepesBurned(), burned);
        assertEq(earn.accountedBalance(), owedToHolders, "holders' rewards untouched");
        assertEq(imd.balanceOf(address(earn)), owedToHolders);
        assertEq(imd.allowance(address(earn), address(pepesRouter)), 0);
    }

    function test_buyback_respectsMinOut() public {
        uint256 reserve = _makeReserve();
        vm.prank(owner);
        vm.expectRevert();
        earn.buybackAndBurnPepes(reserve, reserve * 1000 + 1, block.timestamp);
    }

    // ------------------------------------------------------------ royalties

    function test_royalties_convertedToImdAndSplit() public {
        assertEq(mirror.royaltyReceiver(), address(pad));
        (address recv, uint256 amt) = mirror.royaltyInfo(1, 1 ether);
        assertEq(recv, address(pad));
        assertEq(amt, 0.04 ether);
        assertTrue(mirror.supportsInterface(0x2a55205a));

        _buy(alice, 100e18); // a holder to receive the 3%
        _buy(bob, 10e18); // releases the first buy's waiting fee, so only the royalty is measured below
        (bool ok,) = address(pad).call{value: 1 ether}(""); // a marketplace pays a royalty
        assertTrue(ok);

        vm.prank(bob);
        vm.expectRevert(PepesEarnPad.NotOwner.selector);
        pad.convertRoyalties(0);

        uint256 feeBefore = imd.balanceOf(FEE_RECIPIENT);
        uint256 holdersBefore = earn.withdrawableDividendOf(alice) + earn.withdrawableDividendOf(bob);
        vm.prank(owner);
        uint256 out = pad.convertRoyalties(0.9e18);
        assertGt(out, 0.9e18);
        assertEq(address(pad).balance, 0);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - feeBefore, out / 4);
        uint256 holdersAfter = earn.withdrawableDividendOf(alice) + earn.withdrawableDividendOf(bob);
        assertApproxEqAbs(holdersAfter - holdersBefore, out - out / 4, 10, "3% of the sale to holders");

        (ok,) = address(pad).call{value: 1 ether}("");
        vm.prank(owner);
        vm.expectRevert(PepesEarnPad.Slippage.selector);
        pad.convertRoyalties(100e18);
    }

    // ------------------------------------------------------------ audit regressions (v3 guards)

    function test_audit_flashHolderCannotClaimPendingFees() public {
        _buy(bob, 10e18);
        _buy(bob, 10e18);
        PoolKey memory key = pad.poolKey(address(earn));
        (,,,, bool quoteIs0) = pad.launches(address(earn));
        vm.prank(carol); // third-party router trade: fees stay pending in the pad
        extRouter.swap(key, SwapParams(quoteIs0, -100e18, quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), settings, "");
        assertEq(pad.pendingHolderFees(address(earn)), 3e18);

        EarnFlashHolder attacker = new EarnFlashHolder(pm, earn);
        attacker.run(0);
        assertEq(imd.balanceOf(address(attacker)), 0, "flash holder captured holder rewards");
        attacker.run(1);
        vm.prank(address(attacker));
        earn.claim();
        assertEq(imd.balanceOf(address(attacker)), 0, "flash holder captured via distribute");

        pad.flush(address(earn));
        assertApproxEqAbs(earn.withdrawableDividendOf(bob) + earn.withdrawableDividendOf(carol), 3e18 + 0.6e18, 10);
    }

    function test_hookRejectsOtherPoolsAndLiquidity() public {
        PoolKey memory key = pad.poolKey(address(earn));
        PoolKey memory other = key;
        other.tickSpacing = 60;
        vm.expectRevert();
        pm.initialize(other, TickMath.getSqrtPriceAtTick(0));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        vm.expectRevert();
        lp.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 1e18, 0), "");
    }

    // ------------------------------------------------------------ metadata

    function test_ownerIsZero_andNames() public view {
        assertEq(earn.owner(), address(0));
        assertEq(earn.name(), "Pepes Earn IMD");
        assertEq(earn.symbol(), "EARN");
        assertEq(mirror.name(), "Pepes Earn IMD");
        assertEq(mirror.symbol(), "EARN");
    }

    function test_art_onChainAndSpecials() public {
        _buy(alice, 10e18);
        uint256 g = gasleft();
        string memory uri = mirror.tokenURI(1);
        uint256 used = g - gasleft();
        assertLt(used, 10_000_000, "tokenURI too expensive for an eth_call");
        assertEq(_prefix(uri, 29), "data:application/json;base64,");
        assertEq(renderer.traits(1).special, "The King");
        assertEq(renderer.traits(777).special, "Gold Pepe");
        assertEq(_prefix(renderer.image(42), 4), "<svg");
        emit log_named_uint("tokenURI gas", used);
    }

    function _prefix(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; i++) out[i] = b[i];
        return string(out);
    }
}

contract LibEarnStringTest is Test {
    function test_base64Vectors() public pure {
        assertEq(LibEarnString.base64(""), "");
        assertEq(LibEarnString.base64("f"), "Zg==");
        assertEq(LibEarnString.base64("fo"), "Zm8=");
        assertEq(LibEarnString.base64("foo"), "Zm9v");
        assertEq(LibEarnString.base64("foobar"), "Zm9vYmFy");
    }

    function testFuzz_base64MatchesReference(bytes memory d) public pure {
        assertEq(LibEarnString.base64(d), vm.toBase64(d));
    }

    function test_maxTokenUriGasAcrossCollection() public {
        PepesEarnRenderer r = new PepesEarnRenderer();
        uint256 maxGas;
        for (uint256 id = 1; id <= 2000; id += 13) {
            uint256 g = gasleft();
            r.tokenURI(id);
            uint256 used = g - gasleft();
            if (used > maxGas) maxGas = used;
        }
        emit log_named_uint("max tokenURI gas (154 ids)", maxGas);
        assertLt(maxGas, 15_000_000);
    }
}
