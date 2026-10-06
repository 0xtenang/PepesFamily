// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PepesFamily} from "../src/PepesFamily.sol";
import {DeployLib} from "./DeployLib.sol";

/// @notice Deploys PepesFamily v4 (with its routers and the shared $Pepes buyback) to Robinhood Chain at a mined
///         hook address.
///   forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --interactive
contract Deploy is Script {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant FEE_RECIPIENT = 0x3c8A4d94B3219F6633F2cC94094f4765b30c691C;
    // Expired holder rewards buy $Pepes through the PepesFamily v1 router and burn it.
    address constant PEPES = 0xE2C46c7068566740A33A4C93f5445B07BCfE5644;
    address constant PEPES_ROUTER = 0xA73604EA3C393B47573986ff9Ce5A9EAb61883dC;
    // Uniswap v4 IMD/ETH pool 0xd2fc01ee…8f02 (1% fee, tick spacing 100, no hooks), used by the ETH router.
    uint24 constant IMD_ETH_FEE = 10_000;
    int24 constant IMD_ETH_TICK_SPACING = 100;

    function _l2BlockNumber() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(100).staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        return ok && data.length == 32 ? abi.decode(data, (uint256)) : block.number;
    }

    function run() external {
        // Starting market cap (full supply), the same as v3: 635 IMD.
        uint256 imdStartMcap = vm.envOr("IMD_START_MCAP", uint256(635e18));
        address owner = vm.envOr("OWNER", FEE_RECIPIENT);

        bytes memory initCode = abi.encodePacked(
            type(PepesFamily).creationCode,
            abi.encode(
                POOL_MANAGER,
                IMD,
                owner,
                FEE_RECIPIENT,
                DeployLib.startTickForMarketCap(imdStartMcap),
                PepesFamily.ImdEthPool({fee: IMD_ETH_FEE, tickSpacing: IMD_ETH_TICK_SPACING, hooks: address(0)}),
                PEPES,
                PEPES_ROUTER
            )
        );
        (bytes32 salt, address expected) =
            DeployLib.mineSalt(CREATE2_FACTORY, uint160(0x28CC), initCode, vm.envOr("SALT_START", uint256(0)));
        require(expected.code.length == 0, "already deployed at mined address");

        vm.startBroadcast();
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        vm.stopBroadcast();
        require(ok && expected.code.length > 0, "deploy failed");

        PepesFamily pad = PepesFamily(expected);
        console.log("PepesFamily (hook)  :", address(pad));
        console.log("PepesFamilyRouter   :", pad.router());
        console.log("PepesFamilyEthRouter:", pad.ethRouter());
        console.log("PepesBuyback        :", pad.buyback());
        console.log("Owner               :", pad.owner());
        console.log("Fee recipient       :", pad.feeRecipient());
        uint256 l2Block = _l2BlockNumber();
        console.log("L2 block            :", l2Block);

        // Only record real deployments; simulations must not overwrite the deployment file.
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;
        string memory json = "deployment";
        vm.serializeAddress(json, "pad", address(pad));
        vm.serializeAddress(json, "router", pad.router());
        vm.serializeAddress(json, "ethRouter", pad.ethRouter());
        vm.serializeAddress(json, "buyback", pad.buyback());
        vm.serializeAddress(json, "owner", pad.owner());
        vm.serializeAddress(json, "feeRecipient", pad.feeRecipient());
        string memory out = vm.serializeUint(json, "block", l2Block);
        vm.writeJson(out, "./deployments/robinhood-v4.json");
    }
}
