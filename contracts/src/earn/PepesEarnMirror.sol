// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DN404Mirror} from "dn404/DN404Mirror.sol";

interface IEarnFeeRecipient {
    function feeRecipient() external view returns (address);
}

/// @title PepesEarnMirror
/// @notice The ERC-721 side of $EARN (what wallets, explorers and marketplaces show). Adds an ERC-2981 royalty of
///         1%, paid by marketplaces straight to the protocol fee recipient of PepesEarnIMD. Nothing is held or
///         swapped on-chain for it. Marketplaces decide whether to pay royalties; holders earn their 3% from pool
///         trades, which always pay.
contract PepesEarnMirror is DN404Mirror {
    uint256 public constant ROYALTY_BPS = 100;
    address public immutable hook;

    /// @dev Deployed by PepesEarnToken's constructor, which links it in the same transaction. `deployer` is the
    ///      account deploying the token: DN404 checks the link against it, and no one can step in between.
    constructor(address hook_, address deployer) DN404Mirror(deployer) {
        hook = hook_;
    }

    /// @notice Follows PepesEarnIMD.feeRecipient, so royalties go wherever the protocol fee goes.
    function royaltyReceiver() public view returns (address) {
        return IEarnFeeRecipient(hook).feeRecipient();
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (royaltyReceiver(), (salePrice * ROYALTY_BPS) / 10_000);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x2a55205a || super.supportsInterface(interfaceId); // ERC-2981
    }
}
