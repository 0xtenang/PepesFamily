// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PepesFamily} from "../src/PepesFamily.sol";
import {PepesFamilyRouter} from "../src/PepesFamilyRouter.sol";
import {PepesFamilyRemote, IRemotePad} from "../src/PepesFamilyRemote.sol";
import {PadToken} from "../src/PadToken.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {MockWETH} from "./NativeRouter.t.sol";

/// @notice PepesFamilyRemote, the entry point cross-chain fillers (Relay, Across) call: launches and buys for the
///         user who paid on another chain, passes them the tokens and every creator fee, and keeps nothing.
contract RemoteTest is Test {
    PoolManager pm;
    MockWETH weth;
    PepesFamily pad;
    PepesFamilyRouter router;
    PepesFamilyRemote remote;
    address owner = makeAddr("owner");
    address filler = makeAddr("filler"); // stands in for Relay's solver
    address alice = makeAddr("alice"); // paid on another chain
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new PoolManager(address(this));
        weth = new MockWETH();
        bytes memory initCode = abi.encodePacked(
            type(PepesFamily).creationCode,
            abi.encode(pm, address(weth), owner, makeAddr("fees"), DeployLib.startTickForMarketCap(1.5e18),
                PepesFamily.ImdEthPool(0, 0, address(0)))
        );
        (bytes32 salt,) = DeployLib.mineSalt(address(this), uint160(0x28CC), initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        pad = PepesFamily(deployed);
        router = PepesFamilyRouter(payable(pad.router()));
        address[] memory pads = new address[](1);
        pads[0] = address(pad);
        remote = new PepesFamilyRemote(owner, pads);
        vm.deal(filler, 100 ether);
        vm.deal(bob, 100 ether);
        vm.prank(bob);
        weth.deposit{value: 50 ether}();
        vm.prank(bob);
        weth.approve(address(router), type(uint256).max);
    }

    function _split(uint16 c, uint16 h, uint16 b) internal pure returns (IRemotePad.FeeSplit memory) {
        return IRemotePad.FeeSplit(c, h, b);
    }

    function _launchFor(uint256 buy, uint256 drop) internal returns (PadToken t, uint256 got) {
        vm.prank(filler);
        (address token, uint256 tokens) =
            remote.launchFor{value: buy + drop}(address(pad), alice, "Remote", "RMT", "{}", _split(100, 100, 100), buy, 1, drop);
        return (PadToken(payable(token)), tokens);
    }

    function _empty() internal view {
        assertEq(address(remote).balance, 0, "keeps no coin");
        assertEq(weth.balanceOf(address(remote)), 0, "keeps no pair asset");
    }

    function test_launchFor_givesTheCreatorEverything() public {
        uint256 a0 = alice.balance;
        (PadToken t, uint256 got) = _launchFor(1 ether, 0.01 ether);
        assertGt(got, 0);
        assertEq(t.balanceOf(alice), got, "tokens to the real creator");
        assertEq(t.balanceOf(address(remote)), 0);
        assertEq(alice.balance - a0, 0.01 ether, "gas drop");
        assertEq(remote.creatorOf(address(t)), alice);
        assertEq(remote.padOf(address(t)), address(pad));
        (, address creatorOnPad,,,) = pad.launches(address(t));
        assertEq(creatorOnPad, address(remote), "the launchpad sees this contract");
        assertGt(t.lastActive(alice), 0, "first receipt counts as activity");
        _empty();
    }

    function test_launchFor_withoutABuy() public {
        (PadToken t, uint256 got) = _launchFor(0, 0);
        assertEq(got, 0);
        assertEq(remote.creatorOf(address(t)), alice);
        _empty();
    }

    function test_buyFor() public {
        (PadToken t,) = _launchFor(0, 0);
        uint256 b0 = bob.balance;
        vm.prank(filler);
        uint256 got = remote.buyFor{value: 0.51 ether}(address(pad), address(t), bob, 1, 0.01 ether);
        assertEq(t.balanceOf(bob), got);
        assertEq(bob.balance - b0, 0.01 ether);
        _empty();
        // the same as buying directly with 0.5 of the pair asset
        uint256 snap = vm.snapshotState();
        vm.prank(filler);
        uint256 viaRemote = remote.buyFor{value: 1 ether}(address(pad), address(t), alice, 1, 0);
        vm.revertToState(snap);
        vm.prank(bob);
        uint256 direct = router.buy(address(t), 1 ether, 1, block.timestamp);
        assertEq(viaRemote, direct);
    }

    function test_creatorFeesForwarded_thenHandedOver() public {
        (PadToken t,) = _launchFor(0.5 ether, 0);
        vm.prank(bob);
        router.buy(address(t), 10 ether, 1, block.timestamp); // 1% creator fee: 0.1 WETH
        uint256 w0 = weth.balanceOf(alice);
        uint256 fwd = remote.collectCreatorFees(address(t)); // anyone may call
        assertEq(fwd, 0.1 ether + 0.005 ether, "1% of both buys");
        assertEq(weth.balanceOf(alice) - w0, fwd, "paid to the real creator");
        _empty();
        // the creator takes over directly on the launchpad
        vm.prank(bob);
        vm.expectRevert(PepesFamilyRemote.NotCreator.selector);
        remote.handOver(address(t));
        vm.prank(alice);
        remote.handOver(address(t));
        vm.prank(alice);
        pad.acceptCreatorPayout(address(t));
        assertEq(pad.creatorPayout(address(t)), alice);
        vm.prank(bob);
        router.buy(address(t), 10 ether, 1, block.timestamp);
        pad.collectCreatorFees(address(t));
        assertEq(weth.balanceOf(alice) - w0, fwd + 0.1 ether, "now straight from the launchpad");
    }

    function test_transferCreator() public {
        (PadToken t,) = _launchFor(0, 0);
        vm.prank(bob);
        vm.expectRevert(PepesFamilyRemote.NotCreator.selector);
        remote.transferCreator(address(t), bob);
        vm.prank(alice);
        remote.transferCreator(address(t), bob);
        assertEq(remote.creatorOf(address(t)), bob);
        vm.prank(bob);
        router.buy(address(t), 10 ether, 1, block.timestamp);
        uint256 w0 = weth.balanceOf(bob);
        remote.collectCreatorFees(address(t));
        assertEq(weth.balanceOf(bob) - w0, 0.1 ether);
    }

    function test_onlyAllowedLaunchpads_andExactValue() public {
        vm.prank(filler);
        vm.expectRevert(PepesFamilyRemote.NotPad.selector);
        remote.launchFor{value: 1 ether}(makeAddr("fake"), alice, "X", "X", "{}", _split(0, 300, 0), 1 ether, 1, 0);
        vm.prank(filler);
        vm.expectRevert(PepesFamilyRemote.BadValue.selector);
        remote.launchFor{value: 1 ether}(address(pad), alice, "X", "X", "{}", _split(0, 300, 0), 0.5 ether, 1, 0);
        vm.prank(filler);
        vm.expectRevert(PepesFamilyRemote.ZeroAddress.selector);
        remote.launchFor(address(pad), address(0), "X", "X", "{}", _split(0, 300, 0), 0, 1, 0);
        (PadToken t,) = _launchFor(0, 0);
        vm.prank(filler);
        vm.expectRevert(PepesFamilyRemote.BadValue.selector);
        remote.buyFor{value: 0.01 ether}(address(pad), address(t), bob, 1, 0.01 ether);
        // slippage protection reaches the router
        vm.prank(filler);
        vm.expectRevert();
        remote.buyFor{value: 1 ether}(address(pad), address(t), bob, type(uint256).max, 0);
    }

    function test_ownerManagesLaunchpads_only() public {
        address other = makeAddr("otherPad");
        vm.prank(bob);
        vm.expectRevert(PepesFamilyRemote.NotOwner.selector);
        remote.setPad(other, true);
        vm.prank(owner);
        remote.setPad(other, true);
        assertTrue(remote.isPad(other));
        vm.prank(owner);
        remote.transferOwnership(bob);
        vm.prank(bob);
        remote.acceptOwnership();
        assertEq(remote.owner(), bob);
    }

    function testFuzz_buyFor(uint96 v, uint96 d) public {
        uint256 value = bound(uint256(v), 1e12, 20 ether);
        uint256 drop = bound(uint256(d), 0, value - 1);
        (PadToken t,) = _launchFor(0, 0);
        uint256 b0 = bob.balance;
        vm.prank(filler);
        uint256 got = remote.buyFor{value: value}(address(pad), address(t), bob, 1, drop);
        assertEq(t.balanceOf(bob), got);
        assertEq(bob.balance - b0, drop);
        _empty();
    }
}
