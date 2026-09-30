// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {PepesFamily} from "../src/PepesFamily.sol";
import {PepesFamilyRouter} from "../src/PepesFamilyRouter.sol";
import {PepesFamilyEthRouter} from "../src/PepesFamilyEthRouter.sol";
import {PadToken} from "../src/PadToken.sol";
import {IV4Quoter, IERC20} from "./Fork.t.sol";

/// @notice Runs against the LIVE mainnet deployment:
///   FORK_RPC=https://robinhood.drpc.org forge test --mc EthRouterForkTest
contract EthRouterForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IV4Quoter constant QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    PepesFamily constant PAD = PepesFamily(0x2d7689E48Fd71D9A0f225C673D7b8F8A693368CC);
    PepesFamilyRouter constant ROUTER = PepesFamilyRouter(payable(0xA73604EA3C393B47573986ff9Ce5A9EAb61883dC));

    PepesFamilyEthRouter eth;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    PadToken imdToken;
    PadToken ethToken;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        eth = new PepesFamilyEthRouter(PM, address(PAD), IMD, 10_000, 100, address(0));
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.prank(address(PM));
        IERC20(IMD).transfer(alice, 100e18);
        vm.startPrank(alice);
        IERC20(IMD).approve(address(ROUTER), type(uint256).max);
        (address t,) = ROUTER.launch("Fork Pepe", "FPEPE", "{}", IMD, 20e18, 1);
        imdToken = PadToken(payable(t));
        (t,) = ROUTER.launch{value: 0.01 ether}("Fork Eth", "FETH", "{}", address(0), 0.01 ether, 1);
        ethToken = PadToken(payable(t));
        vm.stopPrank();
    }

    function _quoteBuyWithEth(uint256 ethIn) internal returns (uint256) {
        (uint256 imdOut,) = QUOTER.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(eth.imdEthKey(), true, uint128(ethIn), ""));
        (,,,, bool quoteIs0) = PAD.launches(address(imdToken));
        (uint256 out,) = QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams(PAD.poolKey(address(imdToken)), quoteIs0, uint128(imdOut), "")
        );
        return out;
    }

    function test_fork_buyWithEth() public {
        uint256 quoted = _quoteBuyWithEth(0.1 ether);
        uint256 protoBefore = PAD.pendingProtocolFees(IMD);
        uint256 aliceDivBefore = imdToken.withdrawableDividendOf(alice);
        uint256 bobEthBefore = bob.balance;

        vm.prank(bob);
        uint256 out = eth.buyWithEth{value: 0.1 ether}(address(imdToken), quoted, block.timestamp);

        assertEq(out, quoted, "matches two-hop quote");
        assertEq(imdToken.balanceOf(bob), out);
        assertEq(bobEthBefore - bob.balance, 0.1 ether);
        assertEq(address(eth).balance, 0);
        assertEq(IERC20(IMD).balanceOf(address(eth)), 0);
        // ~0.1 ETH ≈ 42 IMD after the IMD/ETH pool fee: protocol gets 1% of that, holders 3%
        uint256 proto = PAD.pendingProtocolFees(IMD) - protoBefore;
        uint256 holders = imdToken.withdrawableDividendOf(alice) - aliceDivBefore;
        assertGt(proto, 0.3e18);
        // + the creator's own 20 IMD launch-buy fee (0.6 IMD), which waited for a holder and is paid out now
        assertApproxEqAbs(holders, proto * 3 + 0.6e18, 1e6);
        console.log("0.1 ETH bought tokens:", out);
    }

    function test_fork_sellForEth() public {
        vm.prank(bob);
        uint256 got = eth.buyWithEth{value: 0.1 ether}(address(imdToken), 1, block.timestamp);
        vm.startPrank(bob);
        imdToken.approve(address(eth), got);
        uint256 before = bob.balance;
        uint256 ethOut = eth.sellForEth(address(imdToken), got, 1, block.timestamp);
        vm.stopPrank();
        assertEq(bob.balance - before, ethOut);
        assertEq(imdToken.balanceOf(bob), 0);
        // round trip loses ~4% + 4% hook fees + 2x 1% IMD/ETH pool fee
        assertGt(ethOut, 0.085 ether);
        assertLt(ethOut, 0.1 ether);
        console.log("round trip 0.1 ETH ->", ethOut);
    }

    function test_fork_rejectsEthPairsAndSlippage() public {
        vm.prank(bob);
        vm.expectRevert(PepesFamilyEthRouter.NotImdPair.selector);
        eth.buyWithEth{value: 0.1 ether}(address(ethToken), 0, block.timestamp);

        vm.prank(bob);
        vm.expectRevert(PepesFamilyEthRouter.Slippage.selector);
        eth.buyWithEth{value: 0.1 ether}(address(imdToken), type(uint256).max, block.timestamp);

        vm.prank(bob);
        vm.expectRevert(PepesFamilyEthRouter.Expired.selector);
        eth.buyWithEth{value: 0.1 ether}(address(imdToken), 0, block.timestamp - 1);

        // can't sell someone else's tokens
        vm.prank(bob);
        vm.expectRevert();
        eth.sellForEth(address(imdToken), 1e18, 0, block.timestamp);
    }
}
