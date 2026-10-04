// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PepesEarnIMD} from "../src/earn/PepesEarnIMD.sol";
import {PepesEarnToken} from "../src/earn/PepesEarnToken.sol";
import {PepesEarnMirror} from "../src/earn/PepesEarnMirror.sol";
import {PepesEarnRenderer} from "../src/earn/PepesEarnRenderer.sol";
import {DeployLib} from "./DeployLib.sol";

/// @notice Deploys Pepes Earn IMD: renderer, PepesEarnIMD (hook, at a mined CREATE2 address) and $EARN (which deploys
///         its NFT mirror itself), then opens the pool when the broadcasting account is the owner.
///   forge script script/DeployEarn.s.sol --rpc-url robinhood --broadcast --interactive
contract DeployEarn is Script {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant PEPES = 0xE2C46c7068566740A33A4C93f5445B07BCfE5644;
    address constant V1_ROUTER = 0xA73604EA3C393B47573986ff9Ce5A9EAb61883dC;
    address constant FEE_RECIPIENT = 0x3c8A4d94B3219F6633F2cC94094f4765b30c691C;
    uint256 constant SUPPLY = 2_000e18;

    function run() external {
        uint256 startMcap = vm.envOr("EARN_START_MCAP", uint256(2_000e18)); // 1 IMD per NFT
        address owner = vm.envOr("OWNER", FEE_RECIPIENT);

        bytes memory initCode = abi.encodePacked(
            type(PepesEarnIMD).creationCode,
            abi.encode(
                POOL_MANAGER,
                IMD,
                owner,
                FEE_RECIPIENT,
                DeployLib.startTickForMarketCap(startMcap, SUPPLY),
                PepesEarnIMD.ImdEthPool({fee: 10_000, tickSpacing: 100, hooks: address(0)}),
                PEPES,
                V1_ROUTER
            )
        );
        (bytes32 salt, address expected) =
            DeployLib.mineSalt(CREATE2_FACTORY, uint160(0x28CC), initCode, vm.envOr("SALT_START", uint256(0)));
        require(expected.code.length == 0, "already deployed at mined address");

        vm.startBroadcast();
        PepesEarnRenderer renderer = new PepesEarnRenderer();
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        require(ok && expected.code.length > 0, "hook deploy failed");
        PepesEarnIMD earnIMD = PepesEarnIMD(payable(expected));
        // the token deploys and links its NFT mirror in the same transaction
        PepesEarnToken token = new PepesEarnToken(address(earnIMD), address(renderer));
        PepesEarnMirror mirror = PepesEarnMirror(payable(token.mirrorERC721()));
        bool opened = msg.sender == owner;
        if (opened) earnIMD.openPool(address(token));
        vm.stopBroadcast();

        console.log("PepesEarnIMD (hook):", address(earnIMD));
        console.log("$EARN token        :", address(token));
        console.log("NFT mirror         :", address(mirror));
        console.log("Renderer           :", address(renderer));
        console.log("Router / ETH router:", earnIMD.router(), earnIMD.ethRouter());
        console.log("Pool opened        :", opened);

        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || !vm.envOr("RECORD", true)) return;
        string memory json = "earn";
        vm.serializeAddress(json, "earnIMD", address(earnIMD));
        vm.serializeAddress(json, "token", address(token));
        vm.serializeAddress(json, "mirror", address(mirror));
        vm.serializeAddress(json, "renderer", address(renderer));
        vm.serializeAddress(json, "router", earnIMD.router());
        string memory out = vm.serializeAddress(json, "ethRouter", earnIMD.ethRouter());
        vm.writeJson(out, "./deployments/robinhood-earn.json");
    }
}
