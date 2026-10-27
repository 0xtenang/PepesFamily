// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PepesFamily} from "../src/PepesFamily.sol";
import {PepesFamilyRemote, IRemotePad} from "../src/PepesFamilyRemote.sol";
import {PadToken} from "../src/PadToken.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {Chains} from "../script/Chains.sol";

/// @notice PepesFamilyRemote on forks: Robinhood Chain's live IMD launchpad (paying with ETH swaps to IMD through the
///         ETH/IMD pool), and the new ETH launchpad on Base, HYPE launchpad on HyperEVM and BNB launchpad on BSC (wrapping).
///   FORK_RPC=https://robinhood.drpc.org FORK_RPC_BASE=https://base-rpc.publicnode.com \
///   FORK_RPC_HYPER=https://rpc.hyperliquid.xyz/evm FORK_RPC_BSC=https://bsc-rpc.publicnode.com forge test --mc RemoteForkTest -vv
contract RemoteForkTest is Test {
    // unique addresses: common test names can be real accounts (with code) on a forked chain
    address alice = makeAddr("pepesfamily-remote-alice");
    address bob = makeAddr("pepesfamily-remote-bob");
    address filler = makeAddr("pepesfamily-remote-filler");

    function test_robinhoodImdPad() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        _run(0xC26003787503b978033427F77047fAF5551Ca8CC, "robinhood v5 (IMD)");
    }

    function test_baseWeth() public { _newPad("base-weth", "FORK_RPC_BASE"); }
    function test_hyperevmWhype() public { _newPad("hyperevm-whype", "FORK_RPC_HYPER"); }
    function test_bscWbnb() public { _newPad("bsc-wbnb", "FORK_RPC_BSC"); }

    function _newPad(string memory key, string memory env) internal {
        string memory rpc = vm.envOr(env, string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        Chains.Pad memory p = Chains.pad(key);
        bytes memory initCode = abi.encodePacked(type(PepesFamily).creationCode,
            abi.encode(p.poolManager, p.quote, Chains.OWNER, Chains.OWNER, DeployLib.startTickForMarketCap(p.startMcap), p.ethPool));
        (bytes32 salt,) = DeployLib.mineSalt(address(this), uint160(0x28CC), initCode, 0);
        address pad;
        assembly { pad := create2(0, add(initCode, 0x20), mload(initCode), salt) }
        _run(pad, key);
    }

    function _run(address pad, string memory label) internal {
        address[] memory pads = new address[](1);
        pads[0] = pad;
        PepesFamilyRemote remote = new PepesFamilyRemote(Chains.OWNER, pads);
        vm.deal(filler, 10 ether);
        // a launch paid on another chain: 0.05 coin buy + 0.001 gas drop
        vm.prank(filler);
        (address token, uint256 got) = remote.launchFor{value: 0.051 ether}(pad, alice, "Cross Chain", "XCH", "{}",
            IRemotePad.FeeSplit(100, 100, 100), 0.05 ether, 1, 0.001 ether);
        assertGt(got, 0);
        assertEq(PadToken(payable(token)).balanceOf(alice), got);
        assertEq(alice.balance, 0.001 ether);
        assertEq(remote.creatorOf(token), alice);
        // a buy paid on another chain
        vm.prank(filler);
        uint256 got2 = remote.buyFor{value: 0.02 ether}(pad, token, bob, 1, 0);
        assertEq(PadToken(payable(token)).balanceOf(bob), got2);
        // creator fees reach the real creator
        (address quote,,,,) = PepesFamily(pad).launches(token);
        uint256 q0 = IERC20Lite(quote).balanceOf(alice);
        uint256 fwd = remote.collectCreatorFees(token);
        assertGt(fwd, 0);
        assertEq(IERC20Lite(quote).balanceOf(alice) - q0, fwd);
        assertEq(address(remote).balance, 0);
        assertEq(IERC20Lite(quote).balanceOf(address(remote)), 0);
        console.log(label, "tokens for 0.05 coin / creator fees forwarded:", got, fwd);
    }
}

interface IERC20Lite {
    function balanceOf(address) external view returns (uint256);
}
