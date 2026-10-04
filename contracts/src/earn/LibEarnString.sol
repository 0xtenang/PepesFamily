// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Number-to-string and Base64 helpers for the on-chain renderer.
library LibEarnString {
    bytes internal constant B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) len++;
        bytes memory b = new bytes(len);
        for (; v != 0; v /= 10) b[--len] = bytes1(uint8(48 + (v % 10)));
        return string(b);
    }

    /// @dev `id` left-padded with zeros to 4 digits ("#0042").
    function pad4(uint256 v) internal pure returns (string memory) {
        string memory s = toString(v);
        uint256 n = bytes(s).length;
        if (n >= 4) return s;
        return string.concat(n == 3 ? "0" : n == 2 ? "00" : "000", s);
    }

    /// @dev Standard Base64 with padding, encoding 3 bytes per iteration in assembly (the OpenZeppelin approach):
    ///      a few gas per byte, so a full tokenURI stays far below eth_call gas limits.
    function base64(bytes memory data) internal pure returns (string memory result) {
        if (data.length == 0) return "";
        bytes memory table = B64;
        result = new string(4 * ((data.length + 2) / 3));
        assembly ("memory-safe") {
            let tablePtr := add(table, 1)
            let resultPtr := add(result, 0x20)
            let dataPtr := data
            let endPtr := add(data, mload(data))
            // The loop reads up to 2 bytes past the end; zero them for the duration and restore afterwards.
            let afterPtr := add(endPtr, 0x20)
            let afterCache := mload(afterPtr)
            mstore(afterPtr, 0x00)
            for {} lt(dataPtr, endPtr) {} {
                dataPtr := add(dataPtr, 3)
                let input := mload(dataPtr)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(18, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(12, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(shr(6, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr, mload(add(tablePtr, and(input, 0x3F))))
                resultPtr := add(resultPtr, 1)
            }
            mstore(afterPtr, afterCache)
            switch mod(mload(data), 3)
            case 1 {
                mstore8(sub(resultPtr, 1), 0x3d)
                mstore8(sub(resultPtr, 2), 0x3d)
            }
            case 2 { mstore8(sub(resultPtr, 1), 0x3d) }
        }
    }
}
