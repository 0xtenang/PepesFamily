// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Swaps exactly `msg.value` ETH for `token` and sends the tokens to `to`.
/// @dev Reverts if fewer than `minOut` tokens arrive. Any ETH not spent is returned to the caller.
interface IBuybackExecutor {
    function buy(address token, uint256 minOut, address to) external payable returns (uint256 tokensOut);
}
