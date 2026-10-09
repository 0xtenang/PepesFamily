// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PepesFamily} from "../src/PepesFamily.sol";
import {DeployLib} from "./DeployLib.sol";
import {Chains} from "./Chains.sol";

/// @notice Prints the CREATE2 deployment data (salt, address, init code) of the current PepesFamily version for the
///         browser deploy page. Chain by id (default Robinhood Chain): CHAIN_ID=1 forge script script/PadDeployData.s.sol
contract PadDeployData is Script {
    function run() external view {
        Chains.Config memory c = Chains.get(vm.envOr("CHAIN_ID", uint256(4663)));
        int24 tick = DeployLib.startTickForMarketCap(635e18);
        bytes memory initCode = abi.encodePacked(
            type(PepesFamily).creationCode,
            abi.encode(c.poolManager, c.imd, Chains.OWNER, Chains.OWNER, tick, c.imdEthPool)
        );
        (bytes32 salt, address pad) = DeployLib.mineSalt(CREATE2_FACTORY, uint160(0x28CC), initCode, 0);
        console.log("chain", c.name);
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
