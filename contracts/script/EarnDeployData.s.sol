// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PepesEarnIMD} from "../src/earn/PepesEarnIMD.sol";
import {DeployLib} from "./DeployLib.sol";

/// @notice Prints the PepesEarnIMD CREATE2 deployment data (salt, address, init code) for the browser deploy page.
contract EarnDeployData is Script {
    function run() external view {
        bytes memory initCode = abi.encodePacked(
            type(PepesEarnIMD).creationCode,
            abi.encode(
                IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951),
                0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127, // IMD
                0x3c8A4d94B3219F6633F2cC94094f4765b30c691C, // owner
                0x3c8A4d94B3219F6633F2cC94094f4765b30c691C, // fee recipient
                DeployLib.startTickForMarketCap(2_000e18, 2_000e18),
                PepesEarnIMD.ImdEthPool({fee: 10_000, tickSpacing: 100, hooks: address(0)}),
                0xE2C46c7068566740A33A4C93f5445B07BCfE5644, // $Pepes
                0xA73604EA3C393B47573986ff9Ce5A9EAb61883dC // PepesFamily v1 router
            )
        );
        (bytes32 salt, address hook) = DeployLib.mineSalt(CREATE2_FACTORY, uint160(0x28CC), initCode, 0);
        console.log("startTick");
        console.logInt(DeployLib.startTickForMarketCap(2_000e18, 2_000e18));
        console.log("salt");
        console.logBytes32(salt);
        console.log("hook");
        console.logAddress(hook);
        console.log("initCodeHash");
        console.logBytes32(keccak256(initCode));
        console.log("initCode");
        console.logBytes(initCode);
    }
}
