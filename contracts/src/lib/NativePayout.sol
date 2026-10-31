// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeTransfer} from "./SafeTransfer.sol";

interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice Pays out a wrapped native coin (WETH, WBNB, WHYPE) as the plain coin. A recipient that can't receive the
///         plain coin (a contract without `receive`) gets the wrapped token instead, so a payout never fails or locks.
library NativePayout {
    using SafeTransfer for address;

    function pay(address wrapped, address to, uint256 amount) internal {
        if (amount == 0) return;
        IWrappedNative(wrapped).withdraw(amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) {
            IWrappedNative(wrapped).deposit{value: amount}();
            wrapped.transferOut(to, amount);
        }
    }
}
