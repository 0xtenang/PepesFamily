// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {PepesFamilySwapRouter} from "../src/PepesFamilySwapRouter.sol";
import {IV4Quoter, IERC20} from "./Fork.t.sol";

/// @notice PepesFamilySwapRouter on an Elysium fork, against real Uniswap v4 pools launched elsewhere: HYPE pools
///         with Volta's hook, WHYPE pools (WHYPE as currency0 and as currency1) with another launchpad's hook, and a
///         plain pool. Buy with HYPE, sell back for HYPE, the quoter predicting the buy, refusals. Skipped without
///         FORK_RPC_ELYSIUM.
///   FORK_RPC_ELYSIUM=https://rpc.volta.family forge test --mc ElysiumSwapRouterForkTest -vv
contract ElysiumSwapRouterForkTest is Test {
    IPoolManager constant PM = IPoolManager(0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1);
    address constant WHYPE = 0xbA876237B0F021A6c6D852d6c26E107997cC5E81;
    address constant QUOTER = 0xfF5Bafce80e990C664C771A5A335Bc6D1E51a793; // PepesFamilyQuoter, deployed
    address constant VOLTA_HOOK = 0x3aB88DDc3CF2A012af88B60828edb4553697E5dC;
    address constant OTHER_HOOK = 0xe0dEF4221b9840a610D4e7d55812a79A6431a8eC;
    PepesFamilySwapRouter router;
    address user = makeAddr("user");

    function _key(address c0, address c1, uint24 fee, int24 ts, address hooks) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, ts, IHooks(hooks));
    }

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_ELYSIUM", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        router = new PepesFamilySwapRouter(PM, WHYPE);
        vm.deal(user, 100 ether);
    }

    function _roundTrip(string memory name, PoolKey memory key, uint256 hypeIn) internal {
        bool native = Currency.unwrap(key.currency0) == address(0);
        bool coinIs0 = native || Currency.unwrap(key.currency0) == WHYPE;
        address token = Currency.unwrap(coinIs0 ? key.currency1 : key.currency0);

        (uint256 quoted,) = IV4Quoter(QUOTER).quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key, coinIs0, uint128(hypeIn), ""));
        uint256 h0 = user.balance;
        vm.prank(user);
        uint256 got = router.buy{value: hypeIn}(key, quoted, block.timestamp);
        assertEq(got, quoted, "quoter predicts the buy");
        assertEq(IERC20(token).balanceOf(user), got, "tokens to the buyer");
        assertEq(h0 - user.balance, hypeIn, "spent what was sent");

        vm.startPrank(user);
        IERC20(token).approve(address(router), got);
        uint256 back = router.sell(key, got, 1, block.timestamp);
        vm.stopPrank();
        assertGt(back, 0);
        assertEq(user.balance, h0 - hypeIn + back, "HYPE back as HYPE");
        assertEq(address(router).balance, 0, "router keeps no HYPE");
        assertEq(IERC20(WHYPE).balanceOf(address(router)), 0, "router keeps no WHYPE");
        assertEq(IERC20(token).balanceOf(address(router)), 0, "router keeps no tokens");
        console.log(name, "HYPE in / back (wei):", hypeIn, back);
    }

    function test_voltaHypePool() public {
        // VOLTA / HYPE: native HYPE, Volta's hook
        _roundTrip("VOLTA", _key(address(0), 0x0f79931689Af199e7CF868ed1107bBA2C83c68f7, 0, 60, VOLTA_HOOK), 1 ether);
    }

    function test_voidHypePool() public {
        _roundTrip("VOID", _key(address(0), 0xD31B21Cb80E431AC996269deC31A40fCf048B77f, 0, 60, VOLTA_HOOK), 0.5 ether);
    }

    function test_whypeAsCurrency0() public {
        // AETHER / WHYPE: WHYPE is currency0, another launchpad's hook, dynamic fee
        _roundTrip("AETHER", _key(WHYPE, 0xf31BceD2eA8F160052D54c8a3fD03381FEDD8E0D, 8388608, 200, OTHER_HOOK), 1 ether);
    }

    function test_whypeAsCurrency1() public {
        // BOZO / WHYPE: WHYPE is currency1
        _roundTrip("BOZO", _key(0x61e6c090Fb341b5Cd41a17BB0F895f0f9E3a756b, WHYPE, 8388608, 200, OTHER_HOOK), 0.5 ether);
    }

    function test_refusals() public {
        PoolKey memory k = _key(address(0), 0x0f79931689Af199e7CF868ed1107bBA2C83c68f7, 0, 60, VOLTA_HOOK);
        vm.startPrank(user);
        vm.expectRevert(PepesFamilySwapRouter.Expired.selector);
        router.buy{value: 1 ether}(k, 1, block.timestamp - 1);
        vm.expectRevert(PepesFamilySwapRouter.BadAmount.selector);
        router.buy(k, 1, block.timestamp);
        vm.expectRevert(); // asks for more than the pool gives
        router.buy{value: 1 ether}(k, type(uint256).max, block.timestamp);
        // a pool without the chain's coin on either side
        PoolKey memory none = _key(0x0f79931689Af199e7CF868ed1107bBA2C83c68f7, 0xD31B21Cb80E431AC996269deC31A40fCf048B77f, 3000, 60, address(0));
        vm.expectRevert();
        router.sell(none, 1 ether, 1, block.timestamp);
        vm.stopPrank();
        // nobody but the PoolManager calls the callback
        vm.expectRevert(PepesFamilySwapRouter.NotPoolManager.selector);
        router.unlockCallback("");
        // plain HYPE sent by anyone else is refused
        vm.prank(user);
        (bool ok,) = address(router).call{value: 1}("");
        assertFalse(ok);
    }
}
