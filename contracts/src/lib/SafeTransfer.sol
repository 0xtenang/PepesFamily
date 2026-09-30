// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal transfer helpers. `address(0)` stands for native ETH.
library SafeTransfer {
    error TransferFailed();

    function transferOut(address asset, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (asset == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            _call(asset, abi.encodeWithSelector(0xa9059cbb, to, amount)); // transfer(address,uint256)
        }
    }

    function transferFrom(address asset, address from, address to, uint256 amount) internal {
        _call(asset, abi.encodeWithSelector(0x23b872dd, from, to, amount)); // transferFrom(address,address,uint256)
    }

    function balanceOf(address asset, address account) internal view returns (uint256) {
        if (asset == address(0)) return account.balance;
        (bool ok, bytes memory data) = asset.staticcall(abi.encodeWithSelector(0x70a08231, account));
        if (!ok || data.length < 32) revert TransferFailed();
        return abi.decode(data, (uint256));
    }

    function _call(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool))) || token.code.length == 0) revert TransferFailed();
    }
}
