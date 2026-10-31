// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {PepesFamilyV6} from "../src/PepesFamilyV6.sol";
import {PepesFamilyRouter, FeeSplit as RouterSplit} from "../src/PepesFamilyRouter.sol";
import {PepesFamilyLens} from "../src/PepesFamilyLens.sol";
import {PepesFamilyRemote, IRemotePad} from "../src/PepesFamilyRemote.sol";
import {PadToken} from "../src/PadToken.sol";
import {PepesFamilyNFT} from "../src/nft/PepesFamilyNFT.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {MockIMD} from "./Mocks.sol";
import {PadTokenFactory} from "../src/PadTokenFactory.sol";

/// @dev WETH9 with a test-only `fund` (backed by ETH dealt to it), standing in for WETH, WBNB or WHYPE.
contract TestWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 wad) external {
        balanceOf[msg.sender] -= wad;
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "withdraw");
    }

    function fund(address to, uint256 wad) external {
        balanceOf[to] += wad;
    }

    function approve(address sp, uint256 a) external returns (bool) {
        allowance[msg.sender][sp] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        return transferFrom(msg.sender, to, a);
    }

    function transferFrom(address f, address to, uint256 a) public returns (bool) {
        if (f != msg.sender && allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @dev A contract wallet that can't receive plain ETH.
contract NoEthWallet {
    function call(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "call failed");
        return ret;
    }
}

/// @notice PepesFamily v6: launches paired with the wrapped native coin, the same 4% for every token in four equal
///         shares (protocol, creator, holders, PEPES FAMILY NFT holders), no burn, payouts in plain ETH, and the
///         PEPES FAMILY NFT that receives the NFT share.
contract PepesFamilyV6Test is Test {
    using StateLibrary for IPoolManager;

    address constant FEE_RECIPIENT = 0x3c8A4d94B3219F6633F2cC94094f4765b30c691C;
    uint256 constant START_MCAP = 100e18;
    uint256 constant PRICE = 0.005 ether;

    PoolManager pm;
    PepesFamilyV6 pad;
    PepesFamilyRouter router;
    PepesFamilyLens lens;
    PepesFamilyNFT nft;
    TestWETH imd; // the pair asset (WETH)
    PoolSwapTest extRouter;
    PoolSwapTest.TestSettings settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
    address owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new PoolManager(address(this));
        imd = new TestWETH();
        extRouter = new PoolSwapTest(pm);
        nft = new PepesFamilyNFT(address(imd), owner, FEE_RECIPIENT, 500, PRICE, address(0));
        PadTokenFactory factory = new PadTokenFactory();
        vm.startPrank(owner);
        nft.addRewardAsset(address(imd));
        nft.setMintConfig(PRICE, true, 10);
        vm.stopPrank();

        bytes memory initCode = abi.encodePacked(
            type(PepesFamilyV6).creationCode,
            abi.encode(
                pm,
                address(imd),
                owner,
                FEE_RECIPIENT,
                address(nft),
                DeployLib.startTickForMarketCap(START_MCAP),
                PepesFamilyV6.ImdEthPool(0, 0, address(0)),
                address(factory)
            )
        );
        (bytes32 salt, address expected) = DeployLib.mineSalt(address(this), _flags(), initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed == expected, "hook address");
        pad = PepesFamilyV6(payable(deployed));
        router = PepesFamilyRouter(payable(pad.router()));
        lens = PepesFamilyLens(pad.lens());

        address[4] memory users = [alice, bob, carol, dave];
        for (uint256 i; i < users.length; i++) {
            vm.deal(users[i], 1000 ether);
            _fund(users[i], 1_000_000e18);
            vm.startPrank(users[i]);
            imd.approve(address(router), type(uint256).max);
            imd.approve(address(extRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    receive() external payable {}

    function _flags() internal pure returns (uint160) {
        return uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    }

    // ------------------------------------------------------------ helpers

    function _launch() internal returns (PadToken t) {
        vm.prank(alice);
        t = PadToken(
            payable(pad.launchWithSplit("Test", "TST", '{"image":""}', address(imd), PepesFamilyV6.FeeSplit(0, 0, 300)))
        );
    }

    function _launchWithOrder(bool quoteIsCurrency0) internal returns (PadToken t) {
        for (uint256 i; i < 40; i++) {
            t = _launch();
            (,,,, bool q0) = pad.launches(address(t));
            if (q0 == quoteIsCurrency0) return t;
        }
        revert("ordering not found");
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

    struct Fees {
        uint256 proto;
        uint256 creator;
        uint256 holders;
        uint256 nft;
    }

    function _fees(PadToken t) internal view returns (Fees memory f) {
        f.proto = pad.pendingProtocolFees(address(imd));
        f.creator = pad.pendingCreatorFees(address(t));
        f.holders = pad.pendingHolderFees(address(t));
        f.nft = pad.pendingNftFees(address(imd));
    }

    /// The pad's ERC-6909 IMD claims always equal what it owes, and it never holds token claims (no burn in v6).
    function _assertClaimsBacked() internal view {
        uint256 owed = pad.pendingProtocolFees(address(imd)) + pad.pendingNftFees(address(imd));
        for (uint256 i; i < pad.tokenCount(); i++) {
            address tok = pad.allTokens(i);
            owed += pad.pendingHolderFees(tok) + pad.pendingCreatorFees(tok);
            assertEq(pm.balanceOf(address(pad), uint256(uint160(tok))), 0, "no token claims");
        }
        assertEq(pm.balanceOf(address(pad), uint256(uint160(address(imd)))), owed, "claims backed");
    }

    function _fund(address to, uint256 amt) internal {
        vm.deal(address(imd), address(imd).balance + amt);
        imd.fund(to, amt);
    }

    function _mint(address who, uint256 n) internal {
        vm.prank(who);
        nft.mint{value: n * PRICE}(n);
    }

    // ------------------------------------------------------------ launchpad

    function test_setup() public view {
        assertEq(uint160(address(pad)) & 0x3FFF, pad.HOOK_FLAGS());
        assertEq(address(router.pad()), address(pad));
        assertEq(pad.feeRecipient(), FEE_RECIPIENT);
        assertEq(pad.nftFeeRecipient(), address(nft));
        assertEq(pad.owner(), owner);
        assertEq(
            pad.PROTOCOL_FEE_BPS() + pad.CREATOR_FEE_BPS() + pad.HOLDER_FEE_BPS() + pad.NFT_FEE_BPS(), pad.FEE_BPS()
        );
    }

    /// Whatever split a caller passes (the v5 signature is kept), every token gets the same one.
    function test_splitArgumentIgnored() public {
        PadToken t = _launch();
        (uint16 c, uint16 h, uint16 b) = pad.feeSplit(address(t));
        assertEq(c, 100);
        assertEq(h, 100);
        assertEq(b, 0);
        assertEq(pad.creatorPayout(address(t)), alice);
        Fees memory before = _fees(t);
        _buy(bob, t, 100e18);
        Fees memory f = _fees(t);
        assertEq(f.creator - before.creator, 1e18, "creator 1%");
        assertEq(pad.totalBurned(address(t)), 0);
        assertEq(pad.pendingBurn(address(t)), 0);
    }

    function test_routerLaunchWithBuy() public {
        vm.prank(alice);
        (address t,) = router.launch("A", "A", "", address(imd), 10e18, 0);
        assertGt(PadToken(payable(t)).balanceOf(alice), 0);
        vm.prank(alice);
        router.launchWithSplit("B", "B", "", address(imd), RouterSplit(200, 0, 100), 10e18, 0);
        (uint16 c,,) = pad.feeSplit(pad.allTokens(1));
        assertEq(c, 100);
    }

    function test_routerBuyAndSell_fourEqualShares() public {
        PadToken t = _launch();
        _buy(bob, t, 100e18);
        Fees memory f = _fees(t);
        // the router flushes holder fees on every trade
        assertEq(f.holders, 0);
        assertEq(imd.balanceOf(address(t)), 1e18, "holders 1% of 100");
        assertEq(f.proto, 1e18);
        assertEq(f.creator, 1e18);
        assertEq(f.nft, 1e18);

        uint256 got = _sell(bob, t, t.balanceOf(bob) / 2);
        Fees memory g = _fees(t);
        uint256 fee = (got * 400) / 9_600; // seller receives 96% of the gross
        assertApproxEqAbs(g.proto - f.proto, fee / 4, 2);
        assertApproxEqAbs(g.creator - f.creator, fee / 4, 2);
        assertApproxEqAbs(g.nft - f.nft, fee / 4, 2);
        _assertClaimsBacked();
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
            _assertClaimsBacked();
        }
    }

    function _checkExternal(PoolKey memory key, PadToken t, bool isBuy, int256 amountSpecified) internal {
        (,,,, bool quoteIs0) = pad.launches(address(t));
        bool zeroForOne = isBuy == quoteIs0;
        uint256 qBefore = imd.balanceOf(bob);
        uint256 tBefore = t.balanceOf(bob);
        Fees memory b = _fees(t);

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
        Fees memory a = _fees(t);
        uint256 proto = a.proto - b.proto;
        uint256 creator = a.creator - b.creator;
        uint256 holders = a.holders - b.holders;
        uint256 nftFee = a.nft - b.nft;
        uint256 fee = proto + creator + holders + nftFee;
        uint256 gross = isBuy ? quoteMoved : quoteMoved + fee;
        assertApproxEqAbs(fee, (gross * 4) / 100, 2, "fee is 4%");
        assertEq(creator, holders);
        assertEq(creator, nftFee);
        assertLe(proto - creator, 3, "protocol keeps only rounding");
        // no burn: the trader gets / pays exactly the pool's token amount
        if (amountSpecified > 0 && isBuy) assertEq(tokenMoved, uint256(amountSpecified));
        if (amountSpecified < 0 && !isBuy) assertEq(tokenMoved, uint256(-amountSpecified));
        if (amountSpecified < 0 && isBuy) assertEq(quoteMoved, uint256(-amountSpecified));
        if (amountSpecified > 0 && !isBuy) assertEq(quoteMoved, uint256(amountSpecified));
    }

    function test_partialFillsRevert() public {
        for (uint256 o; o < 2; o++) {
            bool quoteIs0 = o == 0;
            PadToken t = _launchWithOrder(quoteIs0);
            _buy(alice, t, 20e18);
            _buy(bob, t, 20e18);
            vm.prank(bob);
            t.approve(address(extRouter), type(uint256).max);
            PoolKey memory key = pad.poolKey(address(t));
            bool buyZfo = quoteIs0;
            bool[2] memory zfo = [buyZfo, !buyZfo];
            int256[2][2] memory amounts =
                [[int256(-100e18), int256(1_000_000_000e18)], [-int256(t.balanceOf(bob)), int256(100e18)]];
            for (uint256 side; side < 2; side++) {
                for (uint256 kind; kind < 2; kind++) {
                    (uint160 p,,,) = IPoolManager(address(pm)).getSlot0(key.toId());
                    uint160 lim = zfo[side] ? uint160((uint256(p) * 9_990) / 10_000) : uint160((uint256(p) * 10_010) / 10_000);
                    vm.prank(bob);
                    vm.expectRevert();
                    extRouter.swap(key, SwapParams(zfo[side], amounts[side][kind], lim), settings, "");
                }
            }
            _assertClaimsBacked();
        }
    }

    function test_collectSendsProtocolAndNftShares() public {
        PadToken t = _launch();
        _buy(bob, t, 100e18);
        assertEq(pad.pendingNftFees(address(imd)), 1e18);
        vm.prank(dave); // anyone
        pad.collectProtocolFees(address(imd));
        assertEq(imd.balanceOf(FEE_RECIPIENT), 1e18);
        assertEq(imd.balanceOf(address(nft)), 1e18);
        assertEq(pad.pendingNftFees(address(imd)), 0);
        assertEq(pad.pendingProtocolFees(address(imd)), 0);
        _assertClaimsBacked();
        pad.collectProtocolFees(address(imd)); // nothing pending: no-op
    }

    function test_creatorFeesCollect() public {
        PadToken t = _launch();
        _buy(bob, t, 100e18);
        pad.collectCreatorFees(address(t));
        assertEq(alice.balance, 1000 ether + 1e18, "creator paid in ETH");
        assertEq(imd.balanceOf(alice), 1_000_000e18);
        assertEq(address(pad).balance, 0);
    }

    function test_holdersEarnAndSellersKeepRewards() public {
        PadToken t = _launch();
        _buy(bob, t, 100e18);
        _buy(carol, t, 100e18); // bob earns from carol's buy
        uint256 earned = t.withdrawableDividendOf(bob);
        assertGt(earned, 0);
        _sell(bob, t, t.balanceOf(bob));
        assertGe(t.withdrawableDividendOf(bob), earned, "seller keeps earned rewards");
        uint256 before = bob.balance;
        uint256 wBefore = imd.balanceOf(bob);
        vm.prank(bob);
        uint256 got = t.claim();
        assertEq(bob.balance, before + got, "holder paid in ETH");
        assertEq(imd.balanceOf(bob), wBefore);
        assertEq(address(t).balance, 0);
    }

    function test_nftFeeRecipientOnlyOwner() public {
        vm.expectRevert(PepesFamilyV6.NotOwner.selector);
        pad.setNftFeeRecipient(dave);
        vm.prank(owner);
        vm.expectRevert(PepesFamilyV6.ZeroAddress.selector);
        pad.setNftFeeRecipient(address(0));
        vm.prank(owner);
        pad.setNftFeeRecipient(dave);
        PadToken t = _launch();
        _buy(bob, t, 100e18);
        pad.collectProtocolFees(address(imd));
        assertEq(imd.balanceOf(dave), 1_000_000e18 + 1e18);
    }

    function test_lensWorks() public {
        PadToken t = _launch();
        _buy(bob, t, 50e18);
        assertEq(lens.tokenCount(), 1);
        assertGt(lens.marketCap(address(t)), 0);
        assertEq(lens.getTokens(0, 10).length, 1);
    }

    function test_remoteLaunchesOnV6() public {
        address[] memory pads = new address[](1);
        pads[0] = address(pad);
        PepesFamilyRemote remote = new PepesFamilyRemote(owner, pads);
        (address t,) = remote.launchFor(address(pad), carol, "R", "R", "", IRemotePad.FeeSplit(0, 300, 0), 0, 0, 0);
        assertEq(pad.creatorPayout(t), address(remote.vaultOf(t)));
        _buy(bob, PadToken(payable(t)), 100e18);
        remote.collectCreatorFees(t);
        assertEq(imd.balanceOf(carol), 1_000_000e18 + 1e18);
    }

    /// HyperEVM's fast blocks take at most 3M gas: a cross-chain launch (Remote + vault clone + token) must fit.
    function test_remoteLaunchFitsHyperEvmFastBlock() public {
        address[] memory pads = new address[](1);
        pads[0] = address(pad);
        PepesFamilyRemote remote = new PepesFamilyRemote(owner, pads);
        string memory meta =
            '{"image":"https://pepesdotfamily.fun/img/0123456789abcdef0123456789abcdef.webp","description":"A community token launched cross-chain","website":"https://example.com","x":"https://x.com/example","telegram":"https://t.me/example"}';
        uint256 g = gasleft();
        remote.launchFor(address(pad), carol, "Pepes Family Token", "PEPESFAM", meta, IRemotePad.FeeSplit(0, 300, 0), 0, 0, 0);
        uint256 used = g - gasleft();
        emit log_named_uint("remote launch gas", used);
        assertLt(used + 21_000 + 16 * 600, 3_000_000, "fits a 3M block with calldata");
    }

    function testFuzz_feesAndSolvency(uint96 a, uint96 b) public {
        uint256 buyA = bound(a, 1e12, 2_000e18);
        uint256 buyB = bound(b, 1e12, 2_000e18);
        PadToken t1 = _launch();
        PadToken t2 = _launch();
        _buy(bob, t1, buyA);
        _buy(carol, t2, buyB);
        uint256 got = _sell(bob, t1, t1.balanceOf(bob));
        assertLt(got, buyA);
        _assertClaimsBacked();
        pad.collectProtocolFees(address(imd));
        uint256 volume = buyA + buyB + ((got * 10_000) / 9_600);
        assertApproxEqAbs(imd.balanceOf(FEE_RECIPIENT), volume / 100, 1e6, "protocol 1%");
        assertApproxEqAbs(imd.balanceOf(address(nft)), volume / 100, 1e6, "NFT holders 1%");
        assertGe(imd.balanceOf(address(t1)), t1.accountedBalance());
    }

    // ------------------------------------------------------------ NFT

    function test_nft_mint() public {
        _mint(bob, 3);
        assertEq(nft.totalSupply(), 3);
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.ownerOf(3), bob);
        assertEq(address(nft).balance, 3 * PRICE);

        vm.prank(bob);
        vm.expectRevert(PepesFamilyNFT.WrongPayment.selector);
        nft.mint{value: PRICE}(2);
        vm.prank(bob);
        vm.expectRevert(PepesFamilyNFT.BadQuantity.selector);
        nft.mint{value: 11 * PRICE}(11);
        vm.prank(bob);
        vm.expectRevert(PepesFamilyNFT.BadQuantity.selector);
        nft.mint(0);

        vm.prank(owner);
        nft.setMintConfig(PRICE, false, 10);
        vm.prank(bob);
        vm.expectRevert(PepesFamilyNFT.MintClosed.selector);
        nft.mint{value: PRICE}(1);
    }

    function test_nft_maxSupply() public {
        vm.prank(owner);
        nft.ownerMint(dave, 1995);
        _mint(bob, 5);
        assertEq(nft.totalSupply(), 2000);
        vm.prank(bob);
        vm.expectRevert(PepesFamilyNFT.SoldOut.selector);
        nft.mint{value: PRICE}(1);
        vm.prank(owner);
        vm.expectRevert(PepesFamilyNFT.SoldOut.selector);
        nft.ownerMint(dave, 1);
    }

    function test_nft_proceedsAndAdmin() public {
        _mint(bob, 2);
        vm.expectRevert(PepesFamilyNFT.NotOwner.selector);
        nft.withdrawProceeds(dave);
        vm.prank(owner);
        nft.withdrawProceeds(FEE_RECIPIENT);
        assertEq(FEE_RECIPIENT.balance, 2 * PRICE);

        vm.prank(owner);
        nft.setArt(dave);
        assertEq(nft.art(), dave);
        vm.prank(owner);
        nft.freezeMetadata();
        vm.prank(owner);
        vm.expectRevert(PepesFamilyNFT.Frozen.selector);
        nft.setArt(carol);

        (address r, uint256 roy) = nft.royaltyInfo(1, 1 ether);
        assertEq(r, FEE_RECIPIENT);
        assertEq(roy, 0.05 ether, "5%");
        assertTrue(nft.supportsInterface(0x2a55205a));
        assertTrue(nft.supportsInterface(0xad0d7f6c), "ERC-721C");
        assertTrue(nft.supportsInterface(0x80ac58cd));
        vm.prank(owner);
        vm.expectRevert(PepesFamilyNFT.RoyaltyTooHigh.selector);
        nft.setRoyalty(dave, 1001);

        (bool ok,) = address(nft).call{value: 1}("");
        assertFalse(ok, "plain ETH refused");
    }

    function test_nft_rewardsSplitPerNft() public {
        _mint(bob, 1);
        _mint(carol, 3);
        _fund(address(nft), 400e18);
        assertEq(nft.pendingRewardOf(address(imd), bob), 100e18);
        assertEq(nft.pendingRewardOf(address(imd), carol), 300e18);
        uint256 b0 = bob.balance;
        uint256 c0 = carol.balance;
        vm.prank(bob);
        nft.claim();
        assertEq(bob.balance, b0 + 100e18, "paid in ETH");
        vm.prank(carol);
        nft.claim(address(imd));
        assertEq(carol.balance, c0 + 300e18);
        assertEq(imd.balanceOf(bob), 1_000_000e18);
        assertEq(imd.balanceOf(address(nft)), 0);
    }

    function test_nft_fundsBeforeAnyMintWaitForTheFirstMint() public {
        _fund(address(nft), 50e18);
        nft.sync(address(imd)); // no NFT yet: nothing distributed
        assertEq(nft.totalRewardsDistributed(address(imd)), 0);
        _mint(bob, 1);
        _fund(address(nft), 10e18);
        _mint(carol, 1); // the 60 arrived before carol's NFT existed
        assertEq(nft.pendingRewardOf(address(imd), bob), 60e18);
        assertEq(nft.pendingRewardOf(address(imd), carol), 0);
    }

    function test_nft_laterMintersEarnOnlyFromThenOn() public {
        _mint(bob, 1);
        _fund(address(nft), 100e18);
        _mint(carol, 1);
        _fund(address(nft), 100e18);
        assertEq(nft.pendingRewardOf(address(imd), bob), 150e18);
        assertEq(nft.pendingRewardOf(address(imd), carol), 50e18);
    }

    function test_nft_sellerKeepsEarnedRewards() public {
        _mint(bob, 2);
        _fund(address(nft), 100e18);
        nft.sync(address(imd));
        vm.prank(bob);
        nft.transferFrom(bob, carol, 1);
        vm.prank(bob);
        nft.safeTransferFrom(bob, carol, 2);
        _fund(address(nft), 40e18);
        assertEq(nft.pendingRewardOf(address(imd), bob), 100e18, "seller keeps");
        assertEq(nft.pendingRewardOf(address(imd), carol), 40e18, "buyer earns from then on");
        vm.prank(bob);
        nft.claim();
        vm.prank(carol);
        nft.claim();
        assertEq(imd.balanceOf(address(nft)), 0);
    }

    /// Rewards that arrived before a transfer stay with the seller, even if nobody synced them yet.
    function test_nft_unsyncedFundsStayWithSeller() public {
        _mint(bob, 1);
        _fund(address(nft), 100e18);
        vm.prank(bob);
        nft.transferFrom(bob, carol, 1);
        assertEq(nft.withdrawableRewardOf(address(imd), bob), 100e18);
        assertEq(nft.pendingRewardOf(address(imd), carol), 0);
    }

    function test_nft_multipleAssets() public {
        MockIMD other = new MockIMD();
        _mint(bob, 1);
        _mint(carol, 1);
        vm.prank(owner);
        nft.addRewardAsset(address(other));
        other.mint(address(nft), 2e18);
        _fund(address(nft), 10e18);
        uint256 b0 = bob.balance;
        vm.prank(bob);
        nft.claim();
        assertEq(other.balanceOf(bob), 1e18);
        assertEq(bob.balance, b0 + 5e18);
        vm.prank(owner);
        vm.expectRevert(PepesFamilyNFT.KnownAsset.selector);
        nft.addRewardAsset(address(other));
    }

    function test_nft_unknownAssetIgnored() public {
        MockIMD other = new MockIMD();
        _mint(bob, 1);
        other.mint(address(nft), 1e18);
        assertEq(nft.sync(address(other)), 0);
        vm.prank(bob);
        assertEq(nft.claim(address(other)), 0);
    }

    function test_nft_endToEndFromTrades() public {
        _mint(bob, 1);
        _mint(carol, 1);
        PadToken t = _launch();
        _buy(dave, t, 200e18);
        pad.collectProtocolFees(address(imd));
        uint256 b0 = bob.balance;
        vm.prank(bob);
        nft.claim();
        assertEq(bob.balance, b0 + 1e18, "half of the 1% of 200, in ETH");
    }

    function testFuzz_nft_solvent(uint8 m1, uint8 m2, uint96 r1, uint96 r2, uint8 moves) public {
        uint256 n1 = bound(m1, 1, 10);
        uint256 n2 = bound(m2, 1, 10);
        _mint(bob, n1);
        _fund(address(nft), bound(r1, 0, 1e30));
        _mint(carol, n2);
        uint256 k = bound(moves, 0, n1);
        for (uint256 i = 1; i <= k; i++) {
            vm.prank(bob);
            nft.transferFrom(bob, dave, i);
        }
        _fund(address(nft), bound(r2, 0, 1e30));
        address[3] memory who = [bob, carol, dave];
        for (uint256 i; i < 3; i++) {
            vm.prank(who[i]);
            nft.claim();
        }
        assertLe(imd.balanceOf(address(nft)), n1 + n2 + 3, "only rounding dust stays");
        assertEq(nft.accountedBalance(address(imd)), imd.balanceOf(address(nft)));
    }

    // ------------------------------------------------------------ ETH payouts and royalties

    /// Contract wallets that can't receive ETH get WETH instead, for every payout: holders, creators, NFT holders.
    function test_payoutsFallBackToWethForContracts() public {
        NoEthWallet w = new NoEthWallet();
        _fund(address(w), 100e18);
        PadToken unused;
        unused;
        // creator payout to the contract wallet
        vm.prank(address(w));
        address t = pad.launchWithSplit("W", "W", "", address(imd), PepesFamilyV6.FeeSplit(0, 300, 0));
        // the wallet buys, then someone else trades so it earns holder fees
        w.call(address(imd), abi.encodeWithSignature("approve(address,uint256)", address(router), type(uint256).max));
        w.call(address(router), abi.encodeWithSignature("buy(address,uint256,uint256,uint256)", t, 10e18, 0, block.timestamp));
        _buy(bob, PadToken(payable(t)), 100e18);
        uint256 before = imd.balanceOf(address(w));
        pad.collectCreatorFees(t);
        w.call(t, abi.encodeWithSignature("claim()"));
        assertGt(imd.balanceOf(address(w)), before + 1e18, "creator fee + holder rewards arrived as WETH");
        assertEq(address(w).balance, 0);

        // NFT rewards
        vm.prank(owner);
        nft.ownerMint(address(w), 1);
        _fund(address(nft), 3e18);
        uint256 b2 = imd.balanceOf(address(w));
        w.call(address(nft), abi.encodeWithSignature("claim()"));
        assertEq(imd.balanceOf(address(w)), b2 + 3e18);
    }

    function test_cannotSendEthToPadTokenOrNft() public {
        PadToken t = _launch();
        (bool ok,) = address(pad).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(t).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(nft).call{value: 1}("");
        assertFalse(ok);
    }

    /// Plain-ETH payouts never mix with the mint proceeds.
    function test_nft_proceedsSeparateFromRewards() public {
        _mint(bob, 4);
        _fund(address(nft), 8e18);
        vm.prank(bob);
        nft.claim();
        assertEq(nft.proceeds(), 4 * PRICE);
        vm.prank(owner);
        nft.withdrawProceeds(dave);
        assertEq(dave.balance, 1000 ether + 4 * PRICE);
        assertEq(address(nft).balance, 0);
    }

    function test_nft_transferValidator() public {
        Validator v = new Validator();
        _mint(bob, 2);
        vm.expectRevert(PepesFamilyNFT.NotOwner.selector);
        nft.setTransferValidator(address(v));
        vm.prank(owner);
        nft.setTransferValidator(address(v));
        assertEq(nft.getTransferValidator(), address(v));
        (bytes4 sel, bool isView) = nft.getTransferValidationFunction();
        assertEq(sel, Validator.validateTransfer.selector);
        assertTrue(isView);

        v.setBlocked(carol, true); // a marketplace that skips royalties
        vm.prank(bob);
        nft.setApprovalForAll(carol, true);
        vm.prank(carol);
        vm.expectRevert("blocked operator");
        nft.transferFrom(bob, carol, 1);
        vm.prank(bob); // the holder's own transfer
        nft.transferFrom(bob, dave, 1);
        assertEq(nft.ownerOf(1), dave);
        _mint(bob, 1); // mints are never validated

        vm.prank(owner);
        nft.setTransferValidator(address(0));
        vm.prank(carol);
        nft.transferFrom(bob, carol, 2);
    }

    function test_nft_contractURIAndOwnerForOpenSea() public {
        assertEq(nft.owner(), owner);
        vm.prank(owner);
        nft.setContractURI("ipfs://collection.json");
        assertEq(nft.contractURI(), "ipfs://collection.json");
        vm.prank(owner);
        nft.setRoyalty(dave, 750);
        (address r, uint256 roy) = nft.royaltyInfo(1, 1 ether);
        assertEq(r, dave);
        assertEq(roy, 0.075 ether);
    }
}

contract PepesFamilyNftArtTest is Test {
    TestWETH weth;
    PepesFamilyNFT nft;
    FakeArt art;
    address owner = makeAddr("owner");
    address bob = makeAddr("bob");

    function setUp() public {
        weth = new TestWETH();
        art = new FakeArt();
        nft = new PepesFamilyNFT(address(weth), owner, owner, 500, 0.005 ether, address(art));
        vm.deal(bob, 10 ether);
        vm.prank(owner);
        nft.setMintConfig(0.005 ether, true, 10);
    }

    /// Every NFT shows its art from the moment it is minted: token id shows entry id - 1.
    function test_artVisibleAtMint() public {
        vm.prank(bob);
        nft.mint{value: 0.015 ether}(3);
        assertEq(nft.name(), "PEPES FAMILY");
        assertEq(nft.symbol(), "PEPES");
        assertEq(nft.tokenURI(1), "token 1 entry 0");
        assertEq(nft.tokenURI(3), "token 3 entry 2");
        vm.expectRevert("NOT_MINTED");
        nft.tokenURI(4);
    }

    function test_noArtReverts() public {
        vm.prank(owner);
        nft.setArt(address(0));
        vm.prank(bob);
        nft.mint{value: 0.005 ether}(1);
        vm.expectRevert(PepesFamilyNFT.NoArt.selector);
        nft.tokenURI(1);
    }
}

contract FakeArt {
    function tokenURI(uint256 id, uint256 n) external pure returns (string memory) {
        return string.concat("token ", _s(id), " entry ", _s(n));
    }

    function _s(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        bytes memory b;
        while (v != 0) {
            b = bytes.concat(bytes1(uint8(48 + v % 10)), b);
            v /= 10;
        }
        return string(b);
    }
}

contract Validator {
    mapping(address => bool) public blocked;

    function setBlocked(address op, bool b) external {
        blocked[op] = b;
    }

    function validateTransfer(address caller, address from, address, uint256) external view {
        require(caller == from || !blocked[caller], "blocked operator");
    }
}
