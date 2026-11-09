// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PepesFamilyRemote, IRemotePad} from "../src/PepesFamilyRemote.sol";
import {PadToken} from "../src/PadToken.sol";
import {Chains} from "../script/Chains.sol";

/// @notice PepesFamilyRemote on Elysium mainnet, deployed on a fork exactly as the deploy page sends it (the CREATE2
///         factory, salt 0, the init code of script/RemoteDeployData.s.sol) for the live launchpad v6: a launch and a
///         buy paid on another chain (what Relay's solver calls), and a buy of the live $PEPES FAMILY token.
///   FORK_RPC_ELYSIUM=https://rpc.elysium.kinetiq.xyz forge test --mc ElysiumRemoteForkTest -vv
contract ElysiumRemoteForkTest is Test {
    address constant CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant PAD = 0x2382474CFE9939573Ef16FfACb5B4F0fC98fe8cc;
    address constant PEPES = 0xf75e350445cB3bf6a4c9F4Fe13B865816D11B3E9;
    address alice = makeAddr("pepesfamily-elysium-remote-alice");
    address bob = makeAddr("pepesfamily-elysium-remote-bob");
    address filler = makeAddr("pepesfamily-elysium-remote-filler");

    function test_elysiumRemote() public {
        string memory rpc = vm.envOr("FORK_RPC_ELYSIUM", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 99901, "Elysium mainnet");

        address[] memory pads = new address[](1);
        pads[0] = PAD;
        (bool ok, bytes memory ret) = CREATE2.call(abi.encodePacked(bytes32(0),
            abi.encodePacked(type(PepesFamilyRemote).creationCode, abi.encode(Chains.OWNER, pads))));
        require(ok && ret.length == 20, "create2");
        PepesFamilyRemote remote = PepesFamilyRemote(payable(address(bytes20(ret))));
        console.log("remote", address(remote));
        assertEq(remote.owner(), Chains.OWNER);
        assertTrue(remote.isPad(PAD));

        vm.deal(filler, 10 ether);
        // a launch paid on another chain: 0.05 HYPE buy + 0.001 HYPE gas drop
        vm.prank(filler);
        (address token, uint256 got) = remote.launchFor{value: 0.051 ether}(PAD, alice, "Cross Chain", "XCH", "{}",
            IRemotePad.FeeSplit(100, 100, 0), 0.05 ether, 1, 0.001 ether);
        assertGt(got, 0);
        assertEq(PadToken(payable(token)).balanceOf(alice), got);
        assertEq(alice.balance, 0.001 ether);
        assertEq(remote.creatorOf(token), alice);
        // buys paid on another chain: the new token, and the live $PEPES FAMILY
        vm.prank(filler);
        uint256 got2 = remote.buyFor{value: 0.021 ether}(PAD, token, bob, 1, 0.001 ether);
        assertEq(PadToken(payable(token)).balanceOf(bob), got2);
        assertEq(bob.balance, 0.001 ether);
        vm.prank(filler);
        uint256 got3 = remote.buyFor{value: 0.1 ether}(PAD, PEPES, bob, 1, 0);
        assertGt(got3, 0);
        assertEq(PadToken(payable(PEPES)).balanceOf(bob), got3);
        assertEq(address(remote).balance, 0);
        console.log("launch tokens / buy tokens / PEPES for 0.1 HYPE:", got, got2, got3);
    }
}
