// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DN404Mirror} from "dn404/DN404Mirror.sol";

/// @title PepesEarnMirror
/// @notice The ERC-721 side of $EARN (what wallets, explorers and marketplaces show). Adds an ERC-2981 royalty of
///         4% paid to PepesEarnIMD, which converts it to IMD and splits it like a pool trade: 1% protocol,
///         3% to holders. Marketplaces decide whether to pay royalties; pool trades always pay the 4%.
contract PepesEarnMirror is DN404Mirror {
    uint256 public constant ROYALTY_BPS = 400;
    address public immutable royaltyReceiver;

    /// @dev Only the account deploying this mirror can link it, so it must also deploy the token right after.
    constructor(address hook) DN404Mirror(msg.sender) {
        royaltyReceiver = hook;
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (royaltyReceiver, (salePrice * ROYALTY_BPS) / 10_000);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x2a55205a || super.supportsInterface(interfaceId); // ERC-2981
    }
}
