// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {UniV4BridgedOracle} from "../src/oracles/UniV4BridgedOracle.sol";
import {IExtsload} from "../src/oracles/UniV4SampledOracle.sol";
import {IUniswapV3PoolLike} from "../src/oracles/UniV3Oracle.sol";
import {PoolKey} from "../src/interfaces/IUniswapV4Minimal.sol";

/// @notice Deploys a UniV4BridgedOracle for a coin traded against a stablecoin on Uniswap V4. The defaults list
///         UBIK on Robinhood Chain (UBIK/USDG V4, bridged through WETH/USDG V3); override any of them by env.
///   KEEPER=<keeper wallet> OWNER=<multisig> forge script script/DeployBridgedOracle.s.sol --rpc-url robinhood --broadcast --account <keystore>
/// Then: run the keeper with V4_ORACLES=<oracle> for at least the slow window (30 min), check `read()`, and list the
/// coin from the owner: listMarket(oracle, maxLeverage, netCapEth).
contract DeployBridgedOracle is Script {
    function run() external {
        PoolKey memory key = PoolKey({
            currency0: vm.envOr("CURRENCY0", address(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168)), // USDG
            currency1: vm.envOr("CURRENCY1", address(0x812486EAea648819853F8E372dc9f1516C7868Bd)), // UBIK
            fee: uint24(vm.envOr("POOL_FEE", uint256(0x800000))), // dynamic fee
            tickSpacing: int24(int256(vm.envOr("TICK_SPACING", uint256(200)))),
            hooks: vm.envOr("HOOKS", address(0x08E52564Bad99E05a694b4809F397edcA417A080))
        });
        address coin = vm.envOr("COIN", address(0x812486EAea648819853F8E372dc9f1516C7868Bd));
        IUniswapV3PoolLike bridge = IUniswapV3PoolLike(vm.envOr("BRIDGE", address(0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca)));
        address weth = vm.envOr("WETH", address(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73));
        address manager = vm.envOr("POOL_MANAGER", address(0x8366a39CC670B4001A1121B8F6A443A643e40951));
        address owner = vm.envAddress("OWNER");
        address keeper = vm.envAddress("KEEPER");

        vm.startBroadcast();
        // fast price: median of the last 3 samples, all within 120 s (a sample every 30 s leaves the keeper 30 s of
        // slack before the feed counts as down); slow: 30 min. Owned by the deployer until the keeper is approved,
        // then handed to OWNER (who must acceptOwnership)
        UniV4BridgedOracle oracle = new UniV4BridgedOracle(
            IExtsload(manager), key, coin, bridge, weth, 120, 1800, 30, 60, msg.sender
        );
        oracle.setKeeper(keeper, true);
        if (owner != msg.sender) oracle.transferOwnership(owner);
        vm.stopBroadcast();

        console.log("UniV4BridgedOracle", address(oracle));
        console.log("keeper approved", keeper);
        if (owner != msg.sender) console.log("OWNER must call acceptOwnership() on the oracle:", owner);
    }
}
