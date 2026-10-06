// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {PepesFamily} from "../src/PepesFamily.sol";
import {PepesFamilyRouter} from "../src/PepesFamilyRouter.sol";
import {PepesFamilyEthRouter} from "../src/PepesFamilyEthRouter.sol";
import {PadToken} from "../src/PadToken.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {IV4Quoter, IERC20} from "./Fork.t.sol";

/// @notice v4 deployment on a mainnet fork, trading IMD pairs with ETH through the real Uniswap v4 IMD/ETH pool:
///   FORK_RPC=https://robinhood.drpc.org forge test --mc EthRouterForkTest
contract EthRouterForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IV4Quoter constant QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant FEE_RECIPIENT = 0x3c8A4d94B3219F6633F2cC94094f4765b30c691C;

    PepesFamily pad;
    PepesFamilyRouter router;
    PepesFamilyEthRouter eth;
    address alice = makeAddr("alice");
    address bob;
    uint256 bobKey;
    PadToken imdToken;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        bytes memory initCode = abi.encodePacked(
            type(PepesFamily).creationCode,
            abi.encode(
                PM,
                IMD,
                FEE_RECIPIENT,
                FEE_RECIPIENT,
                DeployLib.startTickForMarketCap(635e18),
                PepesFamily.ImdEthPool(10_000, 100, address(0))
            )
        );
        (bytes32 salt,) = DeployLib.mineSalt(address(this), uint160(0x28CC), initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        pad = PepesFamily(deployed);
        router = PepesFamilyRouter(payable(pad.router()));
        eth = PepesFamilyEthRouter(payable(pad.ethRouter()));

        (bob, bobKey) = makeAddrAndKey("bob");
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.prank(address(PM));
        IERC20(IMD).transfer(alice, 100e18);
        vm.startPrank(alice);
        IERC20(IMD).approve(address(router), type(uint256).max);
        (address t,) = router.launch("Fork Pepe", "FPEPE", "{}", IMD, 20e18, 1);
        imdToken = PadToken(payable(t));
        vm.stopPrank();
    }

    function _quoteBuyWithEth(uint256 ethIn) internal returns (uint256) {
        (uint256 imdOut,) =
            QUOTER.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(eth.imdEthKey(), true, uint128(ethIn), ""));
        (,,,, bool quoteIs0) = pad.launches(address(imdToken));
        (uint256 out,) = QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams(pad.poolKey(address(imdToken)), quoteIs0, uint128(imdOut), "")
        );
        return out;
    }

    function test_fork_tokenIsRenounced() public view {
        assertEq(imdToken.owner(), address(0));
    }

    function test_fork_buyWithEth() public {
        uint256 quoted = _quoteBuyWithEth(0.1 ether);
        uint256 protoBefore = pad.pendingProtocolFees(IMD);
        uint256 aliceDivBefore = imdToken.withdrawableDividendOf(alice);
        uint256 bobEthBefore = bob.balance;

        vm.prank(bob);
        uint256 out = eth.buyWithEth{value: 0.1 ether}(address(imdToken), quoted, block.timestamp);

        assertEq(out, quoted, "matches two-hop quote");
        assertEq(imdToken.balanceOf(bob), out);
        assertEq(bobEthBefore - bob.balance, 0.1 ether);
        assertEq(address(eth).balance, 0);
        assertEq(IERC20(IMD).balanceOf(address(eth)), 0);
        uint256 proto = pad.pendingProtocolFees(IMD) - protoBefore;
        uint256 holders = imdToken.withdrawableDividendOf(alice) - aliceDivBefore;
        assertGt(proto, 0); // 1% of the IMD that 0.1 ETH buys (depends on the IMD price)
        // + the creator's own 20 IMD launch-buy fee (0.6 IMD), which waited for a holder and is paid out now
        assertApproxEqAbs(holders, proto * 3 + 0.6e18, 1e6);
    }

    function test_fork_sellForEth_withApproval() public {
        vm.prank(bob);
        uint256 got = eth.buyWithEth{value: 0.1 ether}(address(imdToken), 1, block.timestamp);
        vm.startPrank(bob);
        imdToken.approve(address(eth), got);
        uint256 before = bob.balance;
        uint256 ethOut = eth.sellForEth(address(imdToken), got, 1, block.timestamp);
        vm.stopPrank();
        assertEq(bob.balance - before, ethOut);
        assertEq(imdToken.balanceOf(bob), 0);
        assertGt(ethOut, 0.085 ether);
        assertLt(ethOut, 0.1 ether);
    }

    function test_fork_sellForEth_withPermit() public {
        vm.prank(bob);
        uint256 got = eth.buyWithEth{value: 0.1 ether}(address(imdToken), 1, block.timestamp);
        bytes32 structHash = keccak256(
            abi.encode(imdToken.PERMIT_TYPEHASH(), bob, address(eth), got, imdToken.nonces(bob), block.timestamp)
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(bobKey, keccak256(abi.encodePacked("\x19\x01", imdToken.DOMAIN_SEPARATOR(), structHash)));
        uint256 before = bob.balance;
        vm.prank(bob);
        uint256 ethOut = eth.sellForEthWithPermit(address(imdToken), got, 1, block.timestamp, v, r, s);
        assertEq(bob.balance - before, ethOut);
        assertEq(imdToken.balanceOf(bob), 0);
        console.log("permit round trip 0.1 ETH ->", ethOut);
    }

    function test_fork_rejectsSlippageAndExpiry() public {
        vm.prank(bob);
        vm.expectRevert(PepesFamilyEthRouter.Slippage.selector);
        eth.buyWithEth{value: 0.1 ether}(address(imdToken), type(uint256).max, block.timestamp);

        vm.prank(bob);
        vm.expectRevert(PepesFamilyEthRouter.Expired.selector);
        eth.buyWithEth{value: 0.1 ether}(address(imdToken), 0, block.timestamp - 1);

        vm.prank(bob);
        vm.expectRevert();
        eth.sellForEth(address(imdToken), 1e18, 0, block.timestamp);
    }
}
