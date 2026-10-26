// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PepesFamilyQuoter} from "../src/PepesFamilyQuoter.sol";
import {Chains} from "./Chains.sol";

/// @notice Elysium testnet has no Uniswap v4 yet: our own PoolManager (owned by Chains.OWNER) and PepesFamilyQuoter,
///         both through the CREATE2 factory with salt 0, so their addresses are fixed. Prints them and their init code.
///   forge script script/ElysiumAddrs.s.sol
contract ElysiumAddrs is Script {
    function pmInit() public pure returns (bytes memory) {
        return abi.encodePacked(type(PoolManager).creationCode, abi.encode(Chains.OWNER));
    }

    function quoterInit(address pm) public pure returns (bytes memory) {
        return abi.encodePacked(type(PepesFamilyQuoter).creationCode, abi.encode(IPoolManager(pm)));
    }

    function at(bytes memory init) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, bytes32(0), keccak256(init))))));
    }

    function run() external pure {
        address pm = at(pmInit());
        address q = at(quoterInit(pm));
        console.log("poolManager", pm);
        console.log("quoter", q);
        console.log("pmInit");
        console.logBytes(pmInit());
        console.log("quoterInit");
        console.logBytes(quoterInit(pm));
    }
}
