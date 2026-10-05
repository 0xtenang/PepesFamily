// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PepesWorldVault} from "../src/world/PepesWorldVault.sol";
import {IERC20} from "./Fork.t.sol";

interface IV1RouterW {
    function buy(address token, uint256 amountIn, uint256 minTokensOut, uint256 deadline) external payable returns (uint256);
}

interface IPepesW {
    function withdrawableDividendOf(address holder) external view returns (uint256);
}

/// @notice Pepes World vault against the real $Pepes, $EARN and v1 router on a Robinhood Chain fork.
///   FORK_RPC=https://robinhood.drpc.org forge test --mc PepesWorldForkTest -vv
contract PepesWorldForkTest is Test {
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant PEPES = 0xE2C46c7068566740A33A4C93f5445B07BCfE5644;
    address constant EARN = 0xf2363c208B1772C3c9dB7a3fe84d75Bf2881fc20;
    address constant V1_ROUTER = 0xA73604EA3C393B47573986ff9Ce5A9EAb61883dC;

    PepesWorldVault vault;
    address team = makeAddr("team");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        vault = new PepesWorldVault(PEPES, EARN, team, 50_000e18);
    }

    function _buyPepes(address who, uint256 imdIn) internal returns (uint256 out) {
        vm.prank(PM);
        IERC20(IMD).transfer(who, imdIn);
        vm.startPrank(who);
        IERC20(IMD).approve(V1_ROUTER, imdIn);
        out = IV1RouterW(V1_ROUTER).buy(PEPES, imdIn, 1, block.timestamp);
        vm.stopPrank();
    }

    function test_fork_enterAndEarn() public {
        assertEq(vault.imd(), IMD);
        uint256 got = _buyPepes(alice, 50e18);
        assertGe(got, 50_000e18, "50 IMD buys at least 50k $Pepes");
        vm.startPrank(alice);
        IERC20(PEPES).approve(address(vault), 50_000e18);
        vault.enter(50_000e18);
        vm.stopPrank();
        assertTrue(vault.canPlay(alice));
        assertEq(IERC20(PEPES).balanceOf(address(vault)), 50_000e18);

        // later trades pay the vault's deposit its share of the 3% holder fee, which the team can claim
        _buyPepes(bob, 100e18);
        assertGt(IPepesW(PEPES).withdrawableDividendOf(address(vault)), 0, "the vault earns IMD");
        vm.prank(team);
        uint256 claimed = vault.claimRewards(team);
        assertGt(claimed, 0);
        assertEq(IERC20(IMD).balanceOf(team), claimed);

        // withdrawing the deposit keeps the pass
        vm.prank(team);
        vault.withdraw(PEPES, team, 50_000e18);
        assertTrue(vault.canPlay(alice));
        emit log_named_decimal_uint("IMD earned by the vault", claimed, 18);
    }
}
