// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PepesFamilyRemote} from "../src/PepesFamilyRemote.sol";
import {Chains} from "./Chains.sol";

/// @notice PepesFamilyRemote's deployment data on one chain (CREATE2 factory, salt 0): owner Chains.OWNER, and the
///         launchpads it works with there. PADS=0xA,0xB REMOTE_CHAIN=name forge script script/RemoteDeployData.s.sol
contract RemoteDeployData is Script {
    function run() external view {
        address[] memory pads = vm.envAddress("PADS", ",");
        bytes memory init = abi.encodePacked(type(PepesFamilyRemote).creationCode, abi.encode(Chains.OWNER, pads));
        address at = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, bytes32(0), keccak256(init))))));
        console.log("remote");
        console.logAddress(at);
        console.log("initCode");
        console.logBytes(init);
    }
}
