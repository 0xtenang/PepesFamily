// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PadTokenV6} from "./PadTokenV6.sol";

/// @title PadTokenFactory
/// @notice Deploys PepesFamily v6 tokens for one launchpad. Keeping the token's code here keeps the launchpad (the
///         pools' v4 hook) under the contract size limits. Deployed first; the launchpad binds itself to it in its
///         constructor, once (if anyone else bound it first, that launchpad's deployment fails and nothing is lost).
contract PadTokenFactory {
    error NotPad();
    error Bound();

    address public pad;

    function bind() external {
        if (pad != address(0)) revert Bound();
        pad = msg.sender;
    }

    function create(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address quote,
        address creator,
        address router,
        address poolManager
    ) external returns (address) {
        if (msg.sender != pad) revert NotPad();
        return address(new PadTokenV6(pad, name, symbol, metadata, quote, creator, router, poolManager));
    }
}
