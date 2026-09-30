// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PepesFamilyEthRouter} from "../src/PepesFamilyEthRouter.sol";

/// @notice Deploys PepesFamilyEthRouter (buy/sell IMD-paired tokens with ETH) via the CREATE2 factory.
///   forge script script/DeployEthRouter.s.sol --rpc-url robinhood --broadcast --interactive
contract DeployEthRouter is Script {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant PAD = 0x2d7689E48Fd71D9A0f225C673D7b8F8A693368CC;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    // Uniswap v4 IMD/ETH pool 0xd2fc01ee…8f02: 1% fee, tick spacing 100, no hooks.
    uint24 constant IMD_ETH_FEE = 10_000;
    int24 constant IMD_ETH_TICK_SPACING = 100;

    function run() external {
        bytes memory initCode = abi.encodePacked(
            type(PepesFamilyEthRouter).creationCode,
            abi.encode(POOL_MANAGER, PAD, IMD, IMD_ETH_FEE, IMD_ETH_TICK_SPACING, address(0))
        );
        bytes32 salt = bytes32(0);
        address expected = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_FACTORY);
        require(expected.code.length == 0, "already deployed");

        vm.startBroadcast();
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        vm.stopBroadcast();
        require(ok && expected.code.length > 0, "deploy failed");
        console.log("PepesFamilyEthRouter:", expected);
    }
}
