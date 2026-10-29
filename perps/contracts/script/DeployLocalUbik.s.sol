// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {LevExchange} from "../src/LevExchange.sol";
import {LevExchangeAdmin} from "../src/LevExchangeAdmin.sol";
import {LevPool} from "../src/LevPool.sol";
import {LevLens} from "../src/LevLens.sol";
import {ILevPool, ILevExchange, ILevNav} from "../src/interfaces/ILevPool.sol";
import {UniV4BridgedOracle} from "../src/oracles/UniV4BridgedOracle.sol";
import {IExtsload} from "../src/oracles/UniV4SampledOracle.sol";
import {IUniswapV3PoolLike} from "../src/oracles/UniV3Oracle.sol";
import {PoolKey, toPoolId} from "../src/interfaces/IUniswapV4Minimal.sol";
import {MockPoolManager} from "../src/mocks/MockPoolManager.sol";
import {MockV3Pool} from "../src/mocks/MockV3Pool.sol";

/// @notice For testing the PepesFamily Long/Short page on a local chain (anvil --chain-id 4663): the pool, exchange
///         and lens owned by the sender, a 10 ETH LP deposit, and UBIK's bridged price feed reading stand-in pools
///         set to the live values passed in (UBIK/USDG V4 slot0 and liquidity, WETH/USDG V3 tick and liquidity).
///         The sender is the feed's keeper: sample it for 30 minutes of chain time, then list it (market 0).
///   V4_SQRTP=… V4_TICK=… V4_LIQ=… BRIDGE_TICK=… BRIDGE_LIQ=… forge script script/DeployLocalUbik.s.sol \
///     --rpc-url http://127.0.0.1:8548 --broadcast --unlocked --sender <anvil account>
contract DeployLocalUbik is Script {
    function run() external {
        address weth = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
        address usdg = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
        address ubik = 0x812486EAea648819853F8E372dc9f1516C7868Bd;
        PoolKey memory key =
            PoolKey({currency0: usdg, currency1: ubik, fee: 0x800000, tickSpacing: 200, hooks: 0x08E52564Bad99E05a694b4809F397edcA417A080});
        vm.startBroadcast();
        MockPoolManager pm = new MockPoolManager();
        pm.setSlot0(toPoolId(key), uint160(vm.envUint("V4_SQRTP")), int24(vm.envInt("V4_TICK")));
        pm.setLiquidity(toPoolId(key), uint128(vm.envUint("V4_LIQ")));
        MockV3Pool bridge = new MockV3Pool(
            weth, usdg, int24(vm.envInt("BRIDGE_TICK")), uint128(vm.envUint("BRIDGE_LIQ")), uint64(block.timestamp - 3600)
        );
        LevPool pool = new LevPool{value: 0.001 ether}(msg.sender);
        LevExchange ex = new LevExchange(ILevPool(address(pool)), msg.sender, msg.sender, address(new LevExchangeAdmin()));
        LevLens lens = new LevLens(ex);
        pool.setExchange(ILevExchange(address(ex)));
        pool.setNavSource(ILevNav(address(lens)));
        UniV4BridgedOracle oracle = new UniV4BridgedOracle(
            IExtsload(address(pm)), key, ubik, IUniswapV3PoolLike(address(bridge)), weth, 120, 1800, 30, 60, msg.sender
        );
        oracle.setKeeper(msg.sender, true);
        pool.deposit{value: 10 ether}();
        vm.stopBroadcast();
        console.log("exchange", address(ex));
        console.log("lens", address(lens));
        console.log("pool", address(pool));
        console.log("oracle", address(oracle));
        console.log("poolManager", address(pm));
    }
}
