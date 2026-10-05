// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PepesWorldVault} from "../src/world/PepesWorldVault.sol";
import {PadTokenV1} from "../src/v1/PadTokenV1.sol";
import {SafeTransfer} from "../src/lib/SafeTransfer.sol";
import {MockIMD} from "./PepesFamily.t.sol";

/// @dev Stands in for $EARN: 2,000 tokens of 18 decimals; balances set freely.
contract MockEarn {
    uint256 public constant totalSupply = 2_000e18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

/// @dev Stands in for the $EARN NFT mirror: balanceOf counts NFTs, totalSupply counts NFTs too.
contract MockMirror {
    function totalSupply() external pure returns (uint256) {
        return 1_206;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1;
    }
}

/// @dev A token that delivers less than requested (fee-on-transfer).
contract FeeToken {
    address public immutable quote;
    mapping(address => uint256) public balanceOf;

    constructor(address quote_) {
        quote = quote_;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt - amt / 100;
        return true;
    }
}

/// @dev Stands in for PepesFamily v1: $Pepes holder fees from other routers wait here until `flush`, which forwards
///      them to the token and distributes them to whoever holds at that moment (PadTokenV1.claim() flushes first).
contract StubPad {
    MockIMD public imd;
    PadTokenV1 public token;
    uint256 public pending;

    constructor(MockIMD imd_) {
        imd = imd_;
        token = new PadTokenV1("Pepes", "PEPES", "", address(imd_), address(this), address(0xbeef), address(0xcafe));
    }

    function give(address to, uint256 amt) external {
        token.transfer(to, amt);
    }

    function addPending(uint256 amt) external {
        imd.mint(address(this), amt);
        pending += amt;
    }

    function flush(address) external {
        if (pending == 0) return;
        uint256 amt = pending;
        pending = 0;
        imd.transfer(address(token), amt);
        token.distribute();
    }
}

/// @notice The vault against the real $Pepes token code (PadTokenV1) behind a stub launchpad.
contract PepesWorldTest is Test {
    MockIMD imd = new MockIMD();
    StubPad pad = new StubPad(imd);
    PadTokenV1 pepes = pad.token();
    MockEarn earn = new MockEarn();
    PepesWorldVault vault;
    address team = makeAddr("team");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    uint256 constant PRICE = 50_000e18;

    function setUp() public {
        vault = new PepesWorldVault(address(pepes), address(earn), team, PRICE);
        pad.give(alice, 200_000e18);
        pad.give(bob, 200_000e18);
        pad.give(carol, 1_000_000e18);
    }

    function _enter(address who) internal {
        vm.startPrank(who);
        pepes.approve(address(vault), PRICE);
        vault.enter(PRICE);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ setup

    function test_constructor() public view {
        assertEq(vault.imd(), address(imd));
        assertEq(vault.pepes(), address(pepes));
        assertEq(vault.earn(), address(earn));
        assertEq(vault.owner(), team);
        assertEq(vault.passPrice(), PRICE);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(PepesWorldVault.ZeroAddress.selector);
        new PepesWorldVault(address(pepes), address(earn), address(0), PRICE);
        vm.expectRevert(PepesWorldVault.ZeroAddress.selector);
        new PepesWorldVault(address(pepes), address(0), team, PRICE);
        vm.expectRevert(PepesWorldVault.ZeroAddress.selector);
        new PepesWorldVault(address(0), address(earn), team, PRICE);
        vm.expectRevert(PepesWorldVault.ZeroPrice.selector);
        new PepesWorldVault(address(pepes), address(earn), team, 0);
    }

    /// Audit finding 3: the NFT mirror (or an address without code) instead of the $EARN token.
    function test_constructorRejectsMirrorAsEarn() public {
        MockMirror mirror = new MockMirror();
        vm.expectRevert(PepesWorldVault.NotEarn.selector);
        new PepesWorldVault(address(pepes), address(mirror), team, PRICE);
        vm.expectRevert(PepesWorldVault.NotEarn.selector);
        new PepesWorldVault(address(pepes), makeAddr("eoa"), team, PRICE);
    }

    /// Audit finding 3: an ETH-paired token would strand its rewards (the vault can't receive ETH).
    function test_constructorRejectsEthQuotedToken() public {
        PadTokenV1 ethToken = new PadTokenV1("X", "X", "", address(0), address(this), address(1), address(2));
        vm.expectRevert(PepesWorldVault.ZeroAddress.selector);
        new PepesWorldVault(address(ethToken), address(earn), team, PRICE);
    }

    // ------------------------------------------------------------ entering

    function test_enter() public {
        assertFalse(vault.canPlay(alice));
        _enter(alice);
        assertTrue(vault.hasPass(alice));
        assertTrue(vault.canPlay(alice));
        assertEq(pepes.balanceOf(address(vault)), PRICE);
        assertEq(pepes.balanceOf(alice), 150_000e18);
        assertEq(vault.passes(), 1);
        assertEq(vault.totalDeposited(), PRICE);
    }

    function test_enterOnlyOnce() public {
        _enter(alice);
        vm.startPrank(alice);
        pepes.approve(address(vault), PRICE);
        vm.expectRevert(PepesWorldVault.AlreadyEntered.selector);
        vault.enter(PRICE);
        vm.stopPrank();
    }

    function test_enterNeedsApproval() public {
        vm.prank(alice);
        vm.expectRevert(SafeTransfer.TransferFailed.selector);
        vault.enter(PRICE);
        assertFalse(vault.hasPass(alice));
    }

    function test_enterNeedsBalance() public {
        address poor = makeAddr("poor");
        pad.give(poor, PRICE - 1);
        vm.startPrank(poor);
        pepes.approve(address(vault), PRICE);
        vm.expectRevert(SafeTransfer.TransferFailed.selector);
        vault.enter(PRICE);
        vm.stopPrank();
        assertFalse(vault.hasPass(poor));
    }

    function test_enterFor_gift() public {
        vm.startPrank(alice);
        pepes.approve(address(vault), 2 * PRICE);
        vault.enterFor(bob, PRICE);
        assertTrue(vault.hasPass(bob));
        assertFalse(vault.hasPass(alice));
        assertEq(pepes.balanceOf(alice), 150_000e18);
        vm.expectRevert(PepesWorldVault.AlreadyEntered.selector);
        vault.enterFor(bob, PRICE);
        vm.expectRevert(PepesWorldVault.ZeroAddress.selector);
        vault.enterFor(address(0), PRICE);
        vm.stopPrank();
    }

    function test_rejectsFeeOnTransfer() public {
        FeeToken fee = new FeeToken(address(imd));
        PepesWorldVault v = new PepesWorldVault(address(fee), address(earn), team, PRICE);
        fee.mint(alice, PRICE);
        vm.prank(alice);
        vm.expectRevert(PepesWorldVault.WrongAmountReceived.selector);
        v.enter(PRICE);
    }

    function test_canPlay_withOneEarn() public {
        earn.mint(bob, 1e18 - 1);
        assertFalse(vault.canPlay(bob), "less than 1 NFT");
        earn.mint(bob, 1);
        assertTrue(vault.canPlay(bob), "1 NFT");
    }

    // ------------------------------------------------------------ price (audit findings 1 and 4)

    /// Audit finding 1: an unlimited approval can't be charged a price raised after the player saw it.
    function test_raisedPriceNeverOvercharges() public {
        vm.prank(bob);
        pepes.approve(address(vault), type(uint256).max);
        vm.prank(team);
        vault.setPassPrice(150_000e18);
        vm.prank(bob);
        vm.expectRevert(PepesWorldVault.PriceAboveMax.selector);
        vault.enter(PRICE);
        assertEq(pepes.balanceOf(bob), 200_000e18, "nothing taken");
        assertFalse(vault.hasPass(bob));
    }

    function test_exactApprovalRevertsOnRaise() public {
        vm.prank(alice);
        pepes.approve(address(vault), PRICE);
        vm.prank(team);
        vault.setPassPrice(PRICE + 1);
        vm.prank(alice);
        vm.expectRevert(PepesWorldVault.PriceAboveMax.selector);
        vault.enter(PRICE);
        assertEq(pepes.balanceOf(alice), 200_000e18);
    }

    function test_loweredPriceChargesTheLowerPrice() public {
        vm.prank(bob);
        pepes.approve(address(vault), type(uint256).max);
        vm.prank(team);
        vault.setPassPrice(30_000e18);
        vm.prank(bob);
        vault.enter(PRICE);
        assertEq(pepes.balanceOf(bob), 170_000e18);
    }

    /// Audit finding 4: no free open enrollment; free passes only through grantPass.
    function test_zeroPriceRejected() public {
        vm.prank(team);
        vm.expectRevert(PepesWorldVault.ZeroPrice.selector);
        vault.setPassPrice(0);
    }

    function test_priceChangeKeepsOldPasses() public {
        _enter(alice);
        vm.prank(team);
        vault.setPassPrice(80_000e18);
        assertTrue(vault.canPlay(alice));
        vm.startPrank(alice);
        pepes.approve(address(vault), 80_000e18);
        vault.enterFor(bob, 80_000e18);
        vm.stopPrank();
        assertEq(pepes.balanceOf(address(vault)), PRICE + 80_000e18);
    }

    // ------------------------------------------------------------ owner

    function test_grantPass() public {
        vm.prank(team);
        vault.grantPass(bob);
        assertTrue(vault.canPlay(bob));
        assertEq(vault.passes(), 1);
        assertEq(vault.totalDeposited(), 0);
        vm.prank(team);
        vm.expectRevert(PepesWorldVault.AlreadyEntered.selector);
        vault.grantPass(bob);
    }

    function test_ownerOnly() public {
        vm.startPrank(alice);
        vm.expectRevert(PepesWorldVault.NotOwner.selector);
        vault.grantPass(bob);
        vm.expectRevert(PepesWorldVault.NotOwner.selector);
        vault.setPassPrice(1);
        vm.expectRevert(PepesWorldVault.NotOwner.selector);
        vault.withdraw(address(pepes), alice, 1);
        vm.expectRevert(PepesWorldVault.NotOwner.selector);
        vault.claimRewards(alice);
        vm.expectRevert(PepesWorldVault.NotOwner.selector);
        vault.transferOwnership(alice);
        vm.stopPrank();
    }

    function test_withdrawKeepsPasses() public {
        _enter(alice);
        vm.prank(team);
        vault.withdraw(address(pepes), team, PRICE);
        assertEq(pepes.balanceOf(team), PRICE);
        assertTrue(vault.canPlay(alice), "play forever");
    }

    function test_withdrawOtherTokens() public {
        imd.mint(address(vault), 3e18);
        MockIMD other = new MockIMD();
        other.mint(address(vault), 5e18);
        vm.startPrank(team);
        vault.withdraw(address(imd), team, 3e18);
        vault.withdraw(address(other), team, 5e18);
        vm.stopPrank();
        assertEq(imd.balanceOf(team), 3e18);
        assertEq(other.balanceOf(team), 5e18);
    }

    function test_claimRewards() public {
        _enter(alice);
        // 14 IMD of holder fees while the vault holds 50k of 1.4M eligible $Pepes
        pad.addPending(14e18);
        vm.prank(team);
        uint256 got = vault.claimRewards(team);
        assertApproxEqAbs(got, 0.5e18, 2);
        assertEq(imd.balanceOf(team), got);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_claimRewardsWithNothingOwed() public {
        vm.prank(team);
        assertEq(vault.claimRewards(team), 0);
    }

    /// Audit finding 2: withdrawing the deposit before claiming must not forfeit fees still pending in the pad.
    function test_withdrawThenClaimKeepsVaultShare() public {
        _enter(alice);
        pad.addPending(14e18);
        assertEq(pepes.withdrawableDividendOf(address(vault)), 0, "nothing flushed yet");
        vm.startPrank(team);
        vault.withdraw(address(pepes), team, PRICE);
        uint256 got = vault.claimRewards(team);
        vm.stopPrank();
        assertApproxEqAbs(got, 0.5e18, 2, "the vault's share of pending fees");
        assertApproxEqAbs(imd.balanceOf(team), 0.5e18, 2);
        assertEq(pepes.balanceOf(team), PRICE);
    }

    function test_twoStepOwnership() public {
        vm.prank(team);
        vault.transferOwnership(bob);
        assertEq(vault.owner(), team);
        vm.prank(alice);
        vm.expectRevert(PepesWorldVault.NotOwner.selector);
        vault.acceptOwnership();
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob);
        assertEq(vault.pendingOwner(), address(0));
    }

    function test_transferOwnershipToZeroCancels() public {
        vm.startPrank(team);
        vault.transferOwnership(bob);
        vault.transferOwnership(address(0));
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(PepesWorldVault.NotOwner.selector);
        vault.acceptOwnership();
        assertEq(vault.owner(), team);
    }

    // ------------------------------------------------------------ fuzz

    /// Whatever the price and the player's limit: the player pays exactly the price or nothing, never more than
    /// their limit, and has a pass exactly when they paid.
    function testFuzz_enter(uint256 price, uint256 maxPrice, uint256 allowance) public {
        price = bound(price, 1, 200_000e18);
        vm.prank(team);
        vault.setPassPrice(price);
        vm.prank(bob);
        pepes.approve(address(vault), allowance);
        uint256 before = pepes.balanceOf(bob);
        vm.prank(bob);
        try vault.enter(maxPrice) {
            assertLe(price, maxPrice);
            assertEq(before - pepes.balanceOf(bob), price);
            assertTrue(vault.hasPass(bob));
        } catch {
            assertEq(pepes.balanceOf(bob), before);
            assertFalse(vault.hasPass(bob));
        }
    }
}
