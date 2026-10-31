// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PepesFamilyV6} from "../src/PepesFamilyV6.sol";
import {PadTokenFactory} from "../src/PadTokenFactory.sol";
import {PepesFamilyNFT} from "../src/nft/PepesFamilyNFT.sol";
import {PepesFamilyArt} from "../src/nft/PepesFamilyArt.sol";
import {DeployLib} from "./DeployLib.sol";
import {Chains} from "./Chains.sol";

/// @notice Prints the CREATE2 deployment data (through the 0x4e59…956c factory, salt as printed) for PepesFamily v6,
///         in deploy order, for the browser deploy page:
///           0. ART=1                 the on-chain art (Robinhood Chain only); the owner then uploads art/pieces and seals
///           1. NFT=1                 the PEPES FAMILY NFT (Robinhood Chain only)
///           2. PAD=<key> PART=factory the launchpad's token factory (salt 0)
///           3. PAD=<key>              the launchpad, bound to that factory in its constructor
///         Keys: robinhood-weth, ethereum-weth, base-weth, hyperevm-whype, bsc-wbnb (script/Chains.sol `pad`).
///         The NFT 1% goes to the NFT contract on Robinhood Chain and to the team address (Chains.OWNER) elsewhere,
///         which moves it to the NFT contract.
contract V6DeployData is Script {
    uint256 internal constant NFT_PRICE = 0.005 ether;
    uint96 internal constant NFT_ROYALTY_BPS = 500;
    /// @dev Robinhood Chain WETH (Arbitrum's aeWETH)
    address internal constant ROBINHOOD_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    function run() external view {
        if (vm.envOr("ART", false)) return _print("art", bytes32(0), artInitCode());
        if (vm.envOr("NFT", false)) return _print("nft", bytes32(0), nftInitCode());
        string memory key = vm.envString("PAD");
        bytes memory factoryCode = type(PadTokenFactory).creationCode;
        if (keccak256(bytes(vm.envOr("PART", string("")))) == keccak256("factory")) {
            return _print("factory", bytes32(0), factoryCode);
        }
        Chains.Pad memory p = Chains.pad(key);
        address factory = _create2(bytes32(0), factoryCode);
        address nftFee = p.chainId == 4663 ? _create2(bytes32(0), nftInitCode()) : Chains.OWNER;
        bytes memory initCode = abi.encodePacked(
            type(PepesFamilyV6).creationCode,
            abi.encode(
                p.poolManager,
                p.quote,
                Chains.OWNER,
                Chains.OWNER,
                nftFee,
                DeployLib.startTickForMarketCap(p.startMcap),
                p.ethPool,
                factory
            )
        );
        (bytes32 salt,) = DeployLib.mineSalt(CREATE2_FACTORY, uint160(0x28CC), initCode, 0);
        console.log("factory", factory);
        console.log("nftFeeRecipient", nftFee);
        _print(key, salt, initCode);
    }

    function artInitCode() internal pure returns (bytes memory) {
        return abi.encodePacked(type(PepesFamilyArt).creationCode, abi.encode(Chains.OWNER));
    }

    function nftInitCode() internal pure returns (bytes memory) {
        address art = _create2(bytes32(0), artInitCode());
        return abi.encodePacked(
            type(PepesFamilyNFT).creationCode,
            abi.encode(ROBINHOOD_WETH, Chains.OWNER, Chains.OWNER, NFT_ROYALTY_BPS, NFT_PRICE, art)
        );
    }

    function _create2(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt, keccak256(initCode)))))
        );
    }

    function _print(string memory name, bytes32 salt, bytes memory initCode) internal pure {
        console.log("contract", name);
        console.log("salt");
        console.logBytes32(salt);
        console.log("address");
        console.logAddress(_create2(salt, initCode));
        console.log("initCode");
        console.logBytes(initCode);
    }
}
