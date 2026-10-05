// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PepesWorldVault} from "../src/world/PepesWorldVault.sol";
import {MockIMD} from "./PepesFamily.t.sol";

/// @dev Stands in for $Pepes: an ERC20 paid in IMD, whose `claim` pays out whatever `setRewards` set.
contract MockPepesToken is MockIMD {
    MockIMD public immutable quote;
    mapping(address => uint256) public rewards;

    constructor(MockIMD quote_) {
        quote = quote_;
    }

    function setRewards(address who, uint256 amt) external {
        rewards[who] = amt;
    }

    function claim() external returns (uint256 amt) {
        amt = rewards[msg.sender];
        rewards[msg.sender] = 0;
        quote.mint(msg.sender, amt);
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

contract PepesWorldTest is Test {
    MockIMD imd = new MockIMD();
    MockPepesToken pepes = new MockPepesToken(imd);
    MockIMD earn = new MockIMD();
    PepesWorldVault vault;
    address team = makeAddr("team");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 constant PRICE = 50_000e18;

    function setUp() public {
        vault = new PepesWorldVault(address(pepes), address(earn), team, PRICE);
        pepes.mint(alice, 200_000e18);
        vm.prank(alice);
        pepes.approve(address(vault), type(uint256).max);
    }

    function test_constructor() public view {
        assertEq(vault.imd(), address(imd));
        assertEq(vault.owner(), team);
        assertEq(vault.passPrice(), PRICE);
    }

    function test_enter() public {
        assertFalse(vault.canPlay(alice));
        vm.prank(alice);
        vault.enter();
        assertTrue(vault.hasPass(alice));
        assertTrue(vault.canPlay(alice));
        assertEq(pepes.balanceOf(address(vault)), PRICE);
        assertEq(pepes.balanceOf(alice), 150_000e18);
        assertEq(vault.passes(), 1);
        assertEq(vault.totalDeposited(), PRICE);
    }

    function test_enterOnlyOnce() public {
        vm.startPrank(alice);
        vault.enter();
        vm.expectRevert(PepesWorldVault.AlreadyEntered.selector);
        vault.enter();
        vm.stopPrank();
    }

    function test_enterNeedsBalanceAndApproval() public {
        vm.prank(bob);
        vm.expectRevert();
        vault.enter();
        assertFalse(vault.hasPass(bob));
    }

    function test_enterFor_gift() public {
        vm.prank(alice);
        vault.enterFor(bob);
        assertTrue(vault.hasPass(bob));
        assertFalse(vault.hasPass(alice));
        assertEq(pepes.balanceOf(alice), 150_000e18);
        vm.prank(alice);
        vm.expectRevert(PepesWorldVault.AlreadyEntered.selector);
        vault.enterFor(bob);
        vm.prank(alice);
        vm.expectRevert(PepesWorldVault.ZeroAddress.selector);
        vault.enterFor(address(0));
    }

    function test_canPlay_withOneEarn() public {
        earn.mint(bob, 1e18 - 1);
        assertFalse(vault.canPlay(bob), "less than 1 NFT");
        earn.mint(bob, 1);
        assertTrue(vault.canPlay(bob), "1 NFT");
    }

    function test_rejectsFeeOnTransfer() public {
        FeeToken fee = new FeeToken(address(imd));
        PepesWorldVault v = new PepesWorldVault(address(fee), address(earn), team, PRICE);
        fee.mint(alice, PRICE);
        vm.startPrank(alice);
        vm.expectRevert(PepesWorldVault.WrongAmountReceived.selector);
        v.enter();
        vm.stopPrank();
    }

    function test_priceChangeKeepsOldPasses() public {
        vm.prank(alice);
        vault.enter();
        vm.prank(team);
        vault.setPassPrice(80_000e18);
        assertTrue(vault.canPlay(alice));
        vm.prank(alice);
        vault.enterFor(bob);
        assertEq(pepes.balanceOf(address(vault)), PRICE + 80_000e18);
    }

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
        vm.prank(alice);
        vault.enter();
        vm.prank(team);
        vault.withdraw(address(pepes), team, PRICE);
        assertEq(pepes.balanceOf(team), PRICE);
        assertTrue(vault.canPlay(alice), "play forever");
    }

    function test_claimRewards() public {
        vm.prank(alice);
        vault.enter();
        pepes.setRewards(address(vault), 7e18);
        imd.mint(address(vault), 1e18); // IMD sent here directly is swept too
        vm.prank(team);
        uint256 amt = vault.claimRewards(team);
        assertEq(amt, 8e18);
        assertEq(imd.balanceOf(team), 8e18);
        assertEq(imd.balanceOf(address(vault)), 0);
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

    function test_constructorRejectsZero() public {
        vm.expectRevert(PepesWorldVault.ZeroAddress.selector);
        new PepesWorldVault(address(pepes), address(earn), address(0), PRICE);
        vm.expectRevert(PepesWorldVault.ZeroAddress.selector);
        new PepesWorldVault(address(pepes), address(0), team, PRICE);
    }
}
