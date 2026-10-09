// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PepesFamily} from "../src/PepesFamily.sol";
import {DeployLib} from "./DeployLib.sol";

/// @notice Prints the CREATE2 deployment data (salt, address, init code) of the current PepesFamily version for the
///         browser deploy page.
contract PadDeployData is Script {
    function run() external view {
        int24 tick = DeployLib.startTickForMarketCap(635e18);
        bytes memory initCode = abi.encodePacked(
            type(PepesFamily).creationCode,
            abi.encode(
                IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951),
                0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127, // IMD
                0x3c8A4d94B3219F6633F2cC94094f4765b30c691C, // owner
                0x3c8A4d94B3219F6633F2cC94094f4765b30c691C, // fee recipient (also receives expired rewards)
                tick,
                PepesFamily.ImdEthPool({fee: 10_000, tickSpacing: 100, hooks: address(0)})
            )
        );
        (bytes32 salt, address pad) = DeployLib.mineSalt(CREATE2_FACTORY, uint160(0x28CC), initCode, 0);
        console.log("startTick");
        console.logInt(tick);
        console.log("salt");
        console.logBytes32(salt);
        console.log("pad");
        console.logAddress(pad);
        console.log("initCode");
        console.logBytes(initCode);
    }
}
