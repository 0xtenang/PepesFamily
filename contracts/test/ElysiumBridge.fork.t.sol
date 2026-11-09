// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";

/// @dev Arbitrum Nitro's Inbox, as Elysium runs it on HyperEVM (HYPE is the native coin on both sides).
interface IInbox {
    function bridge() external view returns (address);
    function calculateRetryableSubmissionFee(uint256 dataLength, uint256 baseFee) external view returns (uint256);
    function createRetryableTicket(
        address to,
        uint256 l2CallValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        bytes calldata data
    ) external payable returns (uint256);
}

/// @dev Stands in for Relay's solver contract, which runs the call on HyperEVM for a payment made elsewhere.
contract Executor {
    function run(address inbox, bytes calldata data) external payable {
        (bool ok, bytes memory ret) = inbox.call{value: msg.value}(data);
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
    }
}

/// @notice The website's bridge to Elysium (HyperEVM -> Elysium) on a HyperEVM fork: a retryable ticket to the user's
///         own address, sent by the user or by a contract (Relay), with the fee settings the site uses. The Elysium
///         side (auto-redeem to the user) is Arbitrum's standard retryable flow, also used by its token gateway.
///   FORK_RPC_HYPER=https://rpc.hyperliquid.xyz/evm forge test --mc ElysiumBridgeForkTest -vv
contract ElysiumBridgeForkTest is Test {
    IInbox constant INBOX = IInbox(0xce59f8B65ad41C9DAE4c07A0571a39824bD92cff);
    // the site's settings: gas limit for the transfer on Elysium and the fee cap per gas there
    uint256 constant GAS_LIMIT = 100_000;
    uint256 constant MAX_FEE = 1 gwei;
    address user = makeAddr("user");

    event InboxMessageDelivered(uint256 indexed messageNum, bytes data);

    function _ticket(address to, uint256 amount) internal view returns (bytes memory data, uint256 value) {
        uint256 sub = INBOX.calculateRetryableSubmissionFee(0, block.basefee) * 4 + 1;
        data = abi.encodeCall(INBOX.createRetryableTicket, (to, amount, sub, to, to, GAS_LIMIT, MAX_FEE, ""));
        value = amount + sub + GAS_LIMIT * MAX_FEE;
    }

    function test_bridgeFromUserAndFromRelay() public {
        string memory rpc = vm.envOr("FORK_RPC_HYPER", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 999, "HyperEVM");
        address bridge = INBOX.bridge();

        // the user sends it from their own wallet
        vm.deal(user, 10 ether);
        (bytes memory data, uint256 value) = _ticket(user, 1 ether);
        console.log("1 HYPE to Elysium costs (wei):", value);
        uint256 b0 = bridge.balance;
        vm.expectEmit(false, false, false, false, address(INBOX));
        emit InboxMessageDelivered(0, "");
        vm.prank(user);
        (bool ok,) = address(INBOX).call{value: value}(data);
        assertTrue(ok, "user ticket");
        assertEq(bridge.balance - b0, value, "all of it is held by the bridge for Elysium");

        // Relay's solver runs the same call for a payment made on another chain: still to the user's address
        Executor ex = new Executor();
        vm.deal(address(ex), 0);
        vm.deal(address(this), 10 ether);
        (data, value) = _ticket(user, 2 ether);
        b0 = bridge.balance;
        ex.run{value: value}(address(INBOX), data);
        assertEq(bridge.balance - b0, value);

        // too little value is refused (nothing is taken)
        (data, value) = _ticket(user, 1 ether);
        vm.prank(user);
        (ok,) = address(INBOX).call{value: value - 1}(data);
        assertFalse(ok, "underpaid ticket reverts");
    }
}
