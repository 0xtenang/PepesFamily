// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PepesFamily} from "../src/PepesFamily.sol";
import {PepesFamilyRouter} from "../src/PepesFamilyRouter.sol";
import {PepesFamilyNativeRouter} from "../src/PepesFamilyNativeRouter.sol";
import {PadToken} from "../src/PadToken.sol";
import {DeployLib} from "../script/DeployLib.sol";

/// @dev WETH9, as on every chain (WETH, WBNB, WHYPE).
contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    receive() external payable { deposit(); }

    function deposit() public payable { balanceOf[msg.sender] += msg.value; }

    function withdraw(uint256 wad) external {
        balanceOf[msg.sender] -= wad;
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "withdraw");
    }

    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { return transferFrom(msg.sender, to, a); }

    function transferFrom(address f, address to, uint256 a) public returns (bool) {
        if (f != msg.sender && allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @notice A launchpad paired with the chain's wrapped native coin (ImdEthPool tickSpacing 0): its `ethRouter` is a
///         PepesFamilyNativeRouter, which wraps on the way in and unwraps on the way out.
contract NativeRouterTest is Test {
    address constant FEE_RECIPIENT = 0x3c8A4d94B3219F6633F2cC94094f4765b30c691C;
    PoolManager pm;
    MockWETH weth;
    PepesFamily pad;
    PepesFamilyRouter router;
    PepesFamilyNativeRouter native;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 bobKey;

    function setUp() public {
        vm.warp(1_800_000_000);
        (bob, bobKey) = makeAddrAndKey("bob");
        pm = new PoolManager(address(this));
        weth = new MockWETH();
        bytes memory initCode = abi.encodePacked(
            type(PepesFamily).creationCode,
            abi.encode(pm, address(weth), makeAddr("owner"), FEE_RECIPIENT, DeployLib.startTickForMarketCap(1.5e18),
                PepesFamily.ImdEthPool(0, 0, address(0)))
        );
        (bytes32 salt,) = DeployLib.mineSalt(address(this), uint160(0x28CC), initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        pad = PepesFamily(deployed);
        router = PepesFamilyRouter(payable(pad.router()));
        native = PepesFamilyNativeRouter(payable(pad.ethRouter()));
        for (uint256 i; i < 2; i++) {
            address u = i == 0 ? alice : bob;
            vm.deal(u, 100 ether);
            vm.prank(u);
            weth.deposit{value: 50 ether}();
            vm.prank(u);
            weth.approve(address(router), type(uint256).max);
        }
    }

    function _launch(bool wethIs0) internal returns (PadToken t) {
        for (uint256 i; i < 40; i++) {
            vm.prank(alice);
            t = PadToken(payable(pad.launchWithSplit("Native", "NAT", "{}", address(weth), PepesFamily.FeeSplit(0, 300, 0))));
            (,,,, bool q0) = pad.launches(address(t));
            if (q0 == wethIs0) return t;
        }
        revert("ordering");
    }

    function _empty() internal view {
        assertEq(address(native).balance, 0, "router keeps no native coin");
        assertEq(weth.balanceOf(address(native)), 0, "router keeps no wrapped coin");
    }

    function test_wiring() public view {
        assertEq(native.wrapped(), address(weth));
        assertEq(address(native.pad()), address(pad));
        assertEq(address(native.poolManager()), address(pm));
    }

    function test_buyAndSellWithNativeCoin_bothOrderings() public {
        for (uint256 o; o < 2; o++) {
            PadToken t = _launch(o == 0);
            uint256 eth0 = bob.balance;
            vm.prank(bob);
            uint256 got = native.buyWithEth{value: 1 ether}(address(t), 1, block.timestamp);
            assertGt(got, 0);
            assertEq(t.balanceOf(bob), got);
            assertEq(bob.balance, eth0 - 1 ether);
            _empty();

            uint256 half = got / 2;
            vm.prank(bob);
            t.approve(address(native), half);
            uint256 eth1 = bob.balance;
            vm.prank(bob);
            uint256 back = native.sellForEth(address(t), half, 1, block.timestamp);
            assertGt(back, 0);
            assertEq(bob.balance, eth1 + back, "paid in the native coin");
            assertEq(t.balanceOf(bob), got - half);
            _empty();
        }
    }

    /// The native router gives exactly what the plain router gives for the same amount of the wrapped coin.
    function test_sameAsPlainRouter() public {
        PadToken t = _launch(true);
        uint256 snap = vm.snapshotState();
        vm.prank(bob);
        uint256 a = native.buyWithEth{value: 2 ether}(address(t), 1, block.timestamp);
        vm.revertToState(snap);
        vm.prank(bob);
        uint256 b = router.buy(address(t), 2 ether, 1, block.timestamp);
        assertEq(a, b);
    }

    function test_holdersCredited() public {
        PadToken t = _launch(false);
        vm.prank(alice);
        native.buyWithEth{value: 1 ether}(address(t), 1, block.timestamp);
        vm.prank(bob);
        native.buyWithEth{value: 1 ether}(address(t), 1, block.timestamp);
        assertGt(t.withdrawableDividendOf(alice), 0, "alice earned from bob's buy, in the wrapped coin");
        assertEq(pad.pendingHolderFees(address(t)), 0, "flushed to the token on every trade");
    }

    function test_sellWithPermit() public {
        PadToken t = _launch(true);
        vm.prank(bob);
        uint256 got = native.buyWithEth{value: 1 ether}(address(t), 1, block.timestamp);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", t.DOMAIN_SEPARATOR(), keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            bob, address(native), got, t.nonces(bob), deadline))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobKey, digest);
        uint256 eth0 = bob.balance;
        vm.prank(bob);
        uint256 back = native.sellForEthWithPermit(address(t), got, 1, deadline, v, r, s);
        assertEq(bob.balance, eth0 + back);
        assertEq(t.balanceOf(bob), 0);
        _empty();
    }

    function test_slippageAndDeadline() public {
        PadToken t = _launch(true);
        vm.prank(bob);
        vm.expectRevert();
        native.buyWithEth{value: 1 ether}(address(t), type(uint256).max, block.timestamp);
        vm.prank(bob);
        vm.expectRevert(PepesFamilyNativeRouter.Expired.selector);
        native.buyWithEth{value: 1 ether}(address(t), 1, block.timestamp - 1);
        vm.prank(bob);
        vm.expectRevert(PepesFamilyNativeRouter.BadAmount.selector);
        native.buyWithEth(address(t), 1, block.timestamp);
    }

    function test_onlyThisPadsTokens_andNoStrayCoin() public {
        vm.prank(bob);
        vm.expectRevert(PepesFamilyNativeRouter.NotPair.selector);
        native.buyWithEth{value: 1 ether}(makeAddr("random"), 1, block.timestamp);
        vm.prank(bob);
        (bool ok,) = address(native).call{value: 1 ether}("");
        assertFalse(ok, "only the wrapped coin may send native coin in");
    }

    function testFuzz_roundTrip(uint96 amount) public {
        uint256 v = bound(uint256(amount), 1e9, 40 ether);
        PadToken t = _launch(v % 2 == 0);
        vm.prank(bob);
        uint256 got = native.buyWithEth{value: v}(address(t), 1, block.timestamp);
        vm.prank(bob);
        t.approve(address(native), got);
        vm.prank(bob);
        uint256 back = native.sellForEth(address(t), got, 1, block.timestamp);
        assertLt(back, v, "a round trip pays the fees");
        _empty();
    }
}
