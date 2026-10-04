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

import {PepesEarnIMD} from "../src/earn/PepesEarnIMD.sol";
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

/// @dev Stands in for the PepesFamily v1 router and pad: buys "Pepes" with IMD at 1,000 Pepes per IMD for
///      msg.sender, and reports a real (plain) $Pepes/IMD pool so the buyback cap can read its depth.
contract MockPepesRouter {
    MockIMD immutable imd;
    MockPepes immutable pepes;
    PoolKey key;

    constructor(MockIMD imd_, MockPepes pepes_) {
        imd = imd_;
        pepes = pepes_;
    }

    function setKey(PoolKey memory k) external {
        key = k;
    }

    function pad() external view returns (address) {
        return address(this);
    }

    function poolKey(address) external view returns (PoolKey memory) {
        return key;
    }

    function buy(address token, uint256 amountIn, uint256 minOut, uint256 deadline) external payable returns (uint256 out) {
        require(token == address(pepes) && block.timestamp <= deadline, "bad");
        imd.transferFrom(msg.sender, address(this), amountIn);
        out = amountIn * 1000;
        require(out >= minOut, "slippage");
        pepes.mint(msg.sender, out);
    }
}

/// @dev Minimal WETH: deposit / withdraw / transfer.
contract MockWETH is MockIMD {
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amt) external {
        balanceOf[msg.sender] -= amt;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "eth");
    }
}

/// @dev A token that copies the real one's wiring but points its buyback at another router (audit finding 6).
contract FakeEarn {
    PepesEarnIMD immutable h;
    address immutable badRouter;

    constructor(PepesEarnIMD h_, address badRouter_) {
        h = h_;
        badRouter = badRouter_;
    }

    function hook() external view returns (address) { return address(h); }
    function router() external view returns (address) { return h.router(); }
    function ethRouter() external view returns (address) { return h.ethRouter(); }
    function poolManager() external view returns (address) { return address(h.poolManager()); }
    function quote() external view returns (address) { return h.IMD(); }
    function pepes() external view returns (address) { return h.pepes(); }
    function pepesRouter() external view returns (address) { return badRouter; }
    function balanceOf(address) external pure returns (uint256) { return 2_000e18; }
    function totalSupply() external pure returns (uint256) { return 2_000e18; }
}

/// @dev Calls convertRoyalties from inside its own PoolManager unlock (where pool tokens could be borrowed).
contract UnlockedCaller is IUnlockCallback {
    IPoolManager immutable pm;
    PepesEarnIMD immutable hook;

    constructor(IPoolManager pm_, PepesEarnIMD hook_) {
        pm = pm_;
        hook = hook_;
    }

    function run() external {
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        hook.convertRoyalties(0);
        return "";
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
    MockWETH weth;
    MockPepesRouter pepesRouter;
    PoolKey imdEthKey;
    PepesEarnIMD hook;
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
        weth = new MockWETH();
        pepesRouter = new MockPepesRouter(imd, pepes);
        extRouter = new PoolSwapTest(pm);
        renderer = new PepesEarnRenderer();

        // IMD/ETH pool for the ETH router and royalty conversion: 1 ETH = 1 IMD, deep full-range liquidity
        // (10,000 ETH of virtual depth, so a royalty swap is capped at 50 ETH).
        PoolKey memory imdEth = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 100, IHooks(address(0)));
        imdEthKey = imdEth;
        pm.initialize(imdEth, TickMath.getSqrtPriceAtTick(0));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        vm.deal(address(this), 100_000 ether);
        imd.mint(address(this), 100_000e18);
        imd.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 20_000 ether}(imdEth, ModifyLiquidityParams(-887200, 887200, 10_000e18, 0), "");

        // A plain $Pepes/IMD pool at 1:1 with 1,000 of virtual depth: the buyback cap reads it (2% = 20 IMD).
        pepes.mint(address(this), 100_000e18);
        pepes.approve(address(lp), type(uint256).max);
        (address c0, address c1) = address(pepes) < address(imd) ? (address(pepes), address(imd)) : (address(imd), address(pepes));
        PoolKey memory pepesKey = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        pm.initialize(pepesKey, TickMath.getSqrtPriceAtTick(0));
        lp.modifyLiquidity(pepesKey, ModifyLiquidityParams(-887220, 887220, 1_000e18, 0), "");
        pepesRouter.setKey(pepesKey);

        bytes memory initCode = abi.encodePacked(
            type(PepesEarnIMD).creationCode,
            abi.encode(
                pm,
                address(imd),
                owner,
                FEE_RECIPIENT,
                DeployLib.startTickForMarketCap(START_MCAP, SUPPLY),
                PepesEarnIMD.ImdEthPool(10_000, 100, address(0)),
                address(weth),
                address(pepes),
                address(pepesRouter)
            )
        );
        (bytes32 salt, address expected) = DeployLib.mineSalt(address(this), _flags(), initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed == expected, "hook address");
        hook = PepesEarnIMD(payable(deployed));
        router = PepesFamilyRouter(payable(hook.router()));
        ethRouter = PepesFamilyEthRouter(payable(hook.ethRouter()));

        earn = new PepesEarnToken(address(hook), address(renderer));
        mirror = PepesEarnMirror(payable(earn.mirrorERC721()));
        vm.prank(owner);
        hook.openPool(address(earn));

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

    // ------------------------------------------------------------ opening the pool

    function test_openPool_locksWholeSupplyInPool() public view {
        assertEq(earn.totalSupply(), SUPPLY);
        assertApproxEqAbs(earn.balanceOf(address(pm)), SUPPLY, 1e9);
        assertEq(earn.balanceOf(address(hook)), 0);
        assertEq(mirror.totalSupply(), 0, "no NFTs before anyone buys");
        assertEq(earn.eligibleSupply(), 0);
        assertEq(hook.token(), address(earn));
        // starting market cap ~2,000 IMD (start tick is rounded down to the tick spacing)
        assertApproxEqRel(hook.marketCap(address(earn)), START_MCAP, 0.03e18);
    }

    function test_openPool_onlyOnceAndOnlyOwner() public {
        vm.prank(owner);
        vm.expectRevert(PepesEarnIMD.AlreadyLaunched.selector);
        hook.openPool(address(earn));
        vm.prank(bob);
        vm.expectRevert(PepesEarnIMD.NotOwner.selector);
        hook.openPool(address(earn));
        vm.expectRevert(PepesEarnIMD.NotSupported.selector);
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
        assertEq(hook.pendingProtocolFees(address(imd)), 0.1e18);
        assertEq(imd.balanceOf(address(earn)), 0.3e18);
    }

    function test_ownedIds_listsExactlyTheHoldersNfts() public {
        _buy(alice, 10e18);
        _buy(bob, 5e18);
        uint256 n = mirror.balanceOf(alice);
        uint256[] memory ids = earn.ownedIds(alice, 0, type(uint256).max);
        assertEq(ids.length, n);
        for (uint256 i; i < ids.length; i++) assertEq(mirror.ownerOf(ids[i]), alice);
        uint256[] memory page = earn.ownedIds(alice, 2, 4);
        assertEq(page.length, 2);
        assertEq(page[0], ids[2]);
        assertEq(earn.ownedIds(alice, n, n + 5).length, 0);
        assertEq(earn.ownedIds(carol, 0, 10).length, 0);
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
        earn.recycle(address(hook));
    }

    // audit finding 4: a wallet is inactive only after MORE than 30 days, and a reward distributed exactly 30 days
    // ago still counts as recent
    function test_expiry_exactly30DaysIsStillSafe() public {
        uint256 t0 = vm.getBlockTimestamp();
        _buy(alice, 100e18);
        _buy(bob, 100e18); // alice earns in the same second as her own activity
        vm.warp(t0 + 30 days);
        assertEq(earn.expiredRewardsOf(alice), 0, "exactly 30 days: still active");
        vm.warp(t0 + 30 days + 1);
        assertEq(earn.expiredRewardsOf(alice), earn.withdrawableDividendOf(alice));

        // a reward that is exactly 30 days old stays claimable
        _buy(carol, 100e18); // t1: carol active
        uint256 t1 = vm.getBlockTimestamp();
        vm.warp(t1 + 1 days);
        _buy(dan, 100e18); // carol earns at t1 + 1 day
        uint256 earned = earn.withdrawableDividendOf(carol);
        assertGt(earned, 0);
        vm.warp(t1 + 31 days); // that reward is exactly 30 days old
        assertEq(earn.expiredRewardsOf(carol), 0);
        vm.warp(t1 + 31 days + 1);
        assertApproxEqAbs(earn.expiredRewardsOf(carol), earned, 2);
    }

    // audit finding 8: a zero-amount transferFrom (no allowance needed) must not reset anyone's timer
    function test_expiry_zeroTransferDoesNotCountAsActivity() public {
        _buy(alice, 100e18);
        _buy(bob, 100e18);
        vm.warp(vm.getBlockTimestamp() + 31 days);
        uint256 expired = earn.expiredRewardsOf(alice);
        assertGt(expired, 0);
        vm.prank(dan);
        earn.transferFrom(alice, dan, 0);
        assertEq(earn.expiredRewardsOf(alice), expired);
    }

    // ------------------------------------------------------------ $Pepes buyback and burn

    function _makeReserve(uint256 bobBuy) internal returns (uint256 reserve) {
        _buy(alice, 100e18);
        _buy(bob, bobBuy);
        vm.warp(vm.getBlockTimestamp() + 31 days);
        reserve = earn.recycle(alice);
        assertGt(reserve, 0);
    }

    function test_buyback_anyoneBurnsPepesWithTheReserveOnly() public {
        uint256 reserve = _makeReserve(100e18); // ~3 IMD, under the 20 IMD cap
        assertGt(earn.maxBuyback(), reserve);
        uint256 owedToHolders = earn.accountedBalance();
        vm.prank(carol); // anyone
        uint256 burned = earn.buybackAndBurnPepes(reserve * 1000, vm.getBlockTimestamp());
        assertEq(burned, reserve * 1000);
        assertEq(pepes.balanceOf(DEAD), burned);
        assertEq(pepes.balanceOf(address(earn)), 0);
        assertEq(earn.buybackReserve(), 0);
        assertEq(earn.totalPepesBurned(), burned);
        assertEq(earn.accountedBalance(), owedToHolders, "holders' rewards untouched");
        assertEq(imd.balanceOf(address(earn)), owedToHolders);
        assertEq(imd.allowance(address(earn), address(pepesRouter)), 0);
    }

    // audit finding 2: at most 2% of the $Pepes pool's IMD depth per call, at most once an hour
    function test_buyback_cappedPerCallAndHourly() public {
        uint256 reserve = _makeReserve(1_000e18); // ~30 IMD expired
        uint256 cap = earn.maxBuyback();
        assertApproxEqRel(cap, 20e18, 0.001e18, "2% of the 1,000 IMD depth");
        assertGt(reserve, cap);
        uint256 burned = earn.buybackAndBurnPepes(0, vm.getBlockTimestamp());
        assertEq(burned, cap * 1000);
        assertEq(earn.buybackReserve(), reserve - cap);

        vm.expectRevert(PepesEarnToken.TooSoon.selector);
        earn.buybackAndBurnPepes(0, vm.getBlockTimestamp());

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        earn.buybackAndBurnPepes(0, vm.getBlockTimestamp());
        assertEq(earn.buybackReserve(), 0);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.expectRevert(PepesEarnToken.BadAmount.selector); // nothing left
        earn.buybackAndBurnPepes(0, vm.getBlockTimestamp());
    }

    function test_buyback_respectsMinOut() public {
        uint256 reserve = _makeReserve(100e18);
        vm.expectRevert();
        earn.buybackAndBurnPepes(reserve * 1000 + 1, vm.getBlockTimestamp());
    }

    // ------------------------------------------------------------ royalties

    function test_royalties_anyoneConvertsAndSplits() public {
        assertEq(mirror.royaltyReceiver(), address(hook));
        (address recv, uint256 amt) = mirror.royaltyInfo(1, 1 ether);
        assertEq(recv, address(hook));
        assertEq(amt, 0.04 ether);
        assertTrue(mirror.supportsInterface(0x2a55205a));

        _buy(alice, 100e18); // a holder to receive the 3%
        _buy(bob, 10e18); // releases the first buy's waiting fee, so only the royalty is measured below
        (bool ok,) = address(hook).call{value: 1 ether}(""); // a marketplace pays a royalty
        assertTrue(ok);

        uint256 feeBefore = imd.balanceOf(FEE_RECIPIENT);
        uint256 holdersBefore = earn.withdrawableDividendOf(alice) + earn.withdrawableDividendOf(bob);
        vm.prank(carol); // anyone
        uint256 out = hook.convertRoyalties(0.9e18);
        assertGt(out, 0.9e18);
        assertEq(address(hook).balance, 0);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - feeBefore, out / 4);
        uint256 holdersAfter = earn.withdrawableDividendOf(alice) + earn.withdrawableDividendOf(bob);
        assertApproxEqAbs(holdersAfter - holdersBefore, out - out / 4, 10, "3% of the sale to holders");

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        (ok,) = address(hook).call{value: 1 ether}("");
        vm.expectRevert(PepesEarnIMD.Slippage.selector);
        hook.convertRoyalties(100e18);
    }

    // audit finding 1: at most 0.5% of the IMD/ETH pool's ETH depth per call, at most once an hour
    function test_royalties_cappedPerCallAndHourly() public {
        _buy(alice, 100e18);
        vm.deal(address(hook), 500 ether);
        uint256 cap = hook.maxRoyaltySwap();
        assertApproxEqRel(cap, 50 ether, 0.001e18, "0.5% of the 10,000 ETH depth");
        hook.convertRoyalties(0);
        assertEq(address(hook).balance, 500 ether - cap);
        vm.expectRevert(PepesEarnIMD.TooSoon.selector);
        hook.convertRoyalties(0);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        hook.convertRoyalties(0);
        assertLt(address(hook).balance, 500 ether - cap);
    }

    // audit finding 1, reproduced: buy IMD with ETH, convert, sell back. With the cap the attacker loses.
    function test_royalties_sandwichDoesNotPay() public {
        _buy(alice, 100e18);
        _buy(bob, 10e18);
        vm.deal(address(hook), 500 ether);
        vm.deal(dan, 8_000 ether);
        uint256 eth0 = dan.balance;
        uint256 imd0 = imd.balanceOf(dan);
        vm.startPrank(dan);
        extRouter.swap{value: 7_000 ether}(imdEthKey, SwapParams(true, -7_000 ether, TickMath.MIN_SQRT_PRICE + 1), settings, "");
        uint256 got = imd.balanceOf(dan) - imd0;
        hook.convertRoyalties(0);
        extRouter.swap(imdEthKey, SwapParams(false, -int256(got), TickMath.MAX_SQRT_PRICE - 1), settings, "");
        vm.stopPrank();
        assertEq(imd.balanceOf(dan), imd0);
        assertLt(dan.balance, eth0, "sandwiching the royalty conversion must lose money");
        emit log_named_decimal_uint("attacker ETH lost", eth0 - dan.balance, 18);
    }

    // audit finding 3: royalties paid in WETH (offers, bids) or IMD are no longer stuck
    function test_royalties_wethUnwrappedAndImdSplit() public {
        _buy(alice, 100e18);
        _buy(bob, 10e18);
        weth.deposit{value: 2 ether}();
        weth.transfer(address(hook), 2 ether); // royalty on an accepted WETH offer
        imd.transfer(address(hook), 4e18); // royalty on an IMD sale
        uint256 feeBefore = imd.balanceOf(FEE_RECIPIENT);
        uint256 holdersBefore = earn.withdrawableDividendOf(alice) + earn.withdrawableDividendOf(bob);
        uint256 out = hook.convertRoyalties(0);
        assertGt(out, 1.9e18); // the 2 unwrapped ETH were swapped
        assertEq(weth.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(imd.balanceOf(FEE_RECIPIENT) - feeBefore, 1e18 + out / 4);
        uint256 holdersAfter = earn.withdrawableDividendOf(alice) + earn.withdrawableDividendOf(bob);
        assertApproxEqAbs(holdersAfter - holdersBefore, 3e18 + out - out / 4, 20);
    }

    function test_royalties_refusedInsideSomeoneElsesUnlock() public {
        _buy(alice, 100e18);
        vm.deal(address(hook), 1 ether);
        UnlockedCaller c = new UnlockedCaller(pm, hook);
        vm.expectRevert();
        c.run();
        assertEq(address(hook).balance, 1 ether);
    }

    // ------------------------------------------------------------ deployment guards

    // audit finding 5: the token deploys and links its mirror itself; nobody can link it to anything else
    function test_mirror_linkedAtDeployAndCannotBeRelinked() public {
        assertEq(mirror.baseERC20(), address(earn));
        (bool ok,) = address(mirror).call(abi.encodeWithSelector(bytes4(0x0f4599e5), address(this)));
        assertFalse(ok, "relink must fail");
        assertEq(mirror.baseERC20(), address(earn));
    }

    // audit finding 6: the token's buyback targets come from the hook, and openPool checks them
    function test_openPool_buybackTargetsMatchTheHook() public view {
        assertEq(earn.pepes(), hook.pepes());
        assertEq(earn.pepesRouter(), hook.pepesRouter());
        assertEq(hook.pepes(), address(pepes));
        assertEq(hook.pepesRouter(), address(pepesRouter));
    }

    function test_openPool_rejectsTokenWithAnotherBuybackRouter() public {
        // a second, unopened hook (different owner, so a different CREATE2 address)
        bytes memory initCode = abi.encodePacked(
            type(PepesEarnIMD).creationCode,
            abi.encode(
                pm, address(imd), carol, FEE_RECIPIENT, DeployLib.startTickForMarketCap(START_MCAP, SUPPLY),
                PepesEarnIMD.ImdEthPool(10_000, 100, address(0)), address(weth), address(pepes), address(pepesRouter)
            )
        );
        (bytes32 salt,) = DeployLib.mineSalt(address(this), _flags(), initCode, 0);
        address h2;
        assembly {
            h2 := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        FakeEarn fake = new FakeEarn(PepesEarnIMD(payable(h2)), address(0xBAD));
        vm.prank(carol);
        vm.expectRevert(PepesEarnIMD.BadToken.selector);
        PepesEarnIMD(payable(h2)).openPool(address(fake));
    }

    // ------------------------------------------------------------ audit regressions (v3 guards)

    function test_audit_flashHolderCannotClaimPendingFees() public {
        _buy(bob, 10e18);
        _buy(bob, 10e18);
        PoolKey memory key = hook.poolKey(address(earn));
        (,,,, bool quoteIs0) = hook.launches(address(earn));
        vm.prank(carol); // third-party router trade: fees stay pending in the hook
        extRouter.swap(key, SwapParams(quoteIs0, -100e18, quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), settings, "");
        assertEq(hook.pendingHolderFees(address(earn)), 3e18);

        EarnFlashHolder attacker = new EarnFlashHolder(pm, earn);
        attacker.run(0);
        assertEq(imd.balanceOf(address(attacker)), 0, "flash holder captured holder rewards");
        attacker.run(1);
        vm.prank(address(attacker));
        earn.claim();
        assertEq(imd.balanceOf(address(attacker)), 0, "flash holder captured via distribute");

        hook.flush(address(earn));
        assertApproxEqAbs(earn.withdrawableDividendOf(bob) + earn.withdrawableDividendOf(carol), 3e18 + 0.6e18, 10);
    }

    function test_hookRejectsOtherPoolsAndLiquidity() public {
        PoolKey memory key = hook.poolKey(address(earn));
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
