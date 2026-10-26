// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PepesFamily} from "../src/PepesFamily.sol";
import {PepesFamilyRouter} from "../src/PepesFamilyRouter.sol";
import {PepesFamilyQuoter} from "../src/PepesFamilyQuoter.sol";
import {PadToken} from "../src/PadToken.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {MockWETH} from "./NativeRouter.t.sol";

/// @notice PepesFamilyQuoter (for chains without Uniswap's V4Quoter, such as the Elysium testnet) predicts exactly
///         what the router delivers, buying and selling, in both token orderings, fees and burn included, and
///         changes nothing.
contract QuoterTest is Test {
    PoolManager pm;
    MockWETH weth;
    PepesFamily pad;
    PepesFamilyRouter router;
    PepesFamilyQuoter quoter;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new PoolManager(address(this));
        weth = new MockWETH();
        quoter = new PepesFamilyQuoter(pm);
        bytes memory initCode = abi.encodePacked(
            type(PepesFamily).creationCode,
            abi.encode(pm, address(weth), makeAddr("owner"), makeAddr("fees"), DeployLib.startTickForMarketCap(47e18),
                PepesFamily.ImdEthPool(0, 0, address(0)))
        );
        (bytes32 salt,) = DeployLib.mineSalt(address(this), uint160(0x28CC), initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        pad = PepesFamily(deployed);
        router = PepesFamilyRouter(payable(pad.router()));
        for (uint256 i; i < 2; i++) {
            address u = i == 0 ? alice : bob;
            vm.deal(u, 100 ether);
            vm.prank(u);
            weth.deposit{value: 100 ether}();
            vm.prank(u);
            weth.approve(address(router), type(uint256).max);
        }
    }

    function _launch(bool wethIs0) internal returns (PadToken t) {
        for (uint256 i; i < 40; i++) {
            vm.prank(alice);
            t = PadToken(payable(pad.launchWithSplit("Q", "Q", "{}", address(weth), PepesFamily.FeeSplit(100, 100, 100))));
            (,,,, bool q0) = pad.launches(address(t));
            if (q0 == wethIs0) return t;
        }
        revert("ordering");
    }

    function _quote(PadToken t, bool buying, uint256 amount) internal returns (uint256 out) {
        PoolKey memory key = pad.poolKey(address(t));
        (,,,, bool q0) = pad.launches(address(t));
        (out,) = quoter.quoteExactInputSingle(PepesFamilyQuoter.QuoteExactSingleParams(key, buying == q0, uint128(amount), ""));
    }

    function test_quotesMatchTrades_bothOrderings() public {
        for (uint256 o; o < 2; o++) {
            PadToken t = _launch(o == 0);
            uint256 q = _quote(t, true, 3 ether);
            vm.prank(bob);
            assertEq(router.buy(address(t), 3 ether, q, block.timestamp), q, "buy");
            uint256 half = t.balanceOf(bob) / 2;
            uint256 qs = _quote(t, false, half);
            vm.startPrank(bob);
            t.approve(address(router), half);
            assertEq(router.sell(address(t), half, qs, block.timestamp), qs, "sell");
            vm.stopPrank();
        }
    }

    function test_quoteChangesNothing() public {
        PadToken t = _launch(true);
        uint256 snap = vm.snapshotState();
        _quote(t, true, 5 ether);
        vm.prank(bob);
        uint256 a = router.buy(address(t), 1 ether, 1, block.timestamp);
        vm.revertToState(snap);
        vm.prank(bob);
        uint256 b = router.buy(address(t), 1 ether, 1, block.timestamp);
        assertEq(a, b, "a quote leaves the pool as it was");
        assertEq(weth.balanceOf(address(quoter)), 0);
    }

    function test_onlyThePoolManagerCallsBack() public {
        vm.expectRevert(PepesFamilyQuoter.NotPoolManager.selector);
        quoter.unlockCallback("");
    }
}
