// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LevExchange} from "../src/LevExchange.sol";
import {LevExchangeAdmin} from "../src/LevExchangeAdmin.sol";
import {LevPool} from "../src/LevPool.sol";
import {LevLens} from "../src/LevLens.sol";
import {LevRouter, ILevExchangeForRouter} from "../src/LevRouter.sol";
import {ILevPool, ILevExchange, ILevNav} from "../src/interfaces/ILevPool.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {UniV3Oracle, IUniswapV3PoolLike} from "../src/oracles/UniV3Oracle.sol";

/// @notice Deploy the protocol to Robinhood Chain (or its testnet).
/// Env: OWNER (multisig), GUARDIAN (hot key that can only pause), TREASURY.
/// forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast --account <keystore>
/// The platform token's fee router is deployed separately with DeployPonsFeeRouter, then wired with
/// pool.setFeeSource(router) before the token launches.
contract Deploy is Script {
    function run() external {
        address owner = vm.envAddress("OWNER");
        address guardian = vm.envAddress("GUARDIAN");
        address treasury = vm.envAddress("TREASURY");
        // A multisig must already exist on this chain: a typo or an undeployed Safe would own everything.
        if (vm.envOr("OWNER_IS_CONTRACT", true)) require(owner.code.length > 0, "OWNER has no code on this chain");

        vm.startBroadcast();
        // The deployer owns everything while wiring it up, then hands over. OWNER must accept each handoff.
        LevPool pool = new LevPool{value: 0.001 ether}(msg.sender);
        LevExchangeAdmin adminCode = new LevExchangeAdmin();
        LevExchange ex = new LevExchange(ILevPool(address(pool)), msg.sender, treasury, address(adminCode));
        LevExchangeAdmin exa = LevExchangeAdmin(payable(address(ex)));
        pool.setExchange(ILevExchange(address(ex)));
        LevLens lens = new LevLens(ex);
        pool.setNavSource(ILevNav(address(lens)));
        // The trade router is set once and can never be swapped.
        LevRouter tradeRouter = new LevRouter(ILevExchangeForRouter(address(ex)), msg.sender);
        exa.setRouter(address(tradeRouter));
        exa.setGuardian(guardian);
        tradeRouter.setGuardian(guardian);
        pool.transferOwnership(owner);
        exa.transferOwnership(owner);
        tradeRouter.transferOwnership(owner);
        vm.stopBroadcast();

        console.log("LevPool", address(pool));
        console.log("LevExchange", address(ex));
        console.log("LevExchangeAdmin (code only)", address(adminCode));
        console.log("LevLens", address(lens));
        console.log("LevRouter (one-click trading)", address(tradeRouter));
        console.log("Guardian", guardian);
        console.log("OWNER must call acceptOwnership() on LevPool, LevExchange and LevRouter.");
    }
}

/// @notice Deploy a price feed for a curated coin's Uniswap V3 pool. Listing is a separate owner call:
///         exchange.listMarket(oracle, maxLeverage, netCapEth), from the multisig.
/// Env: UNI_POOL, WETH. Optional FAST_WINDOW (60), SLOW_WINDOW (1800), CARDINALITY_STEP (300), ORACLE (to resume).
/// The feed only reports once the pool keeps more than SLOW_WINDOW observations. Growing that costs gas per slot,
/// so this grows it in steps; run it again until `ready` is logged, then list the coin.
contract DeployV3Oracle is Script {
    function run() external {
        IUniswapV3PoolLike uni = IUniswapV3PoolLike(vm.envAddress("UNI_POOL"));
        uint32 fast = uint32(vm.envOr("FAST_WINDOW", uint256(60)));
        uint32 slow = uint32(vm.envOr("SLOW_WINDOW", uint256(1800)));
        uint256 step = vm.envOr("CARDINALITY_STEP", uint256(300));
        address existing = vm.envOr("ORACLE", address(0));
        vm.startBroadcast();
        UniV3Oracle oracle = existing == address(0)
            ? new UniV3Oracle(uni, IERC20(vm.envAddress("WETH")), fast, slow)
            : UniV3Oracle(existing);
        (,,,, uint16 next,,) = uni.slot0();
        uint256 target = uint256(oracle.slowWindow()) + 1;
        if (next < target) {
            uint256 grow = uint256(next) + step < target ? uint256(next) + step : target;
            oracle.prepare(uint16(grow));
            next = uint16(grow);
        }
        vm.stopBroadcast();
        console.log("UniV3Oracle", address(oracle));
        console.log("observation slots requested", next, "of", target);
        try IPriceOracle(address(oracle)).read() returns (int24 spot, int24 f, int24 s, uint256 liq) {
            console.log("ready; liquidity (wei of ETH)", liq);
            console.logInt(spot);
            console.logInt(f);
            console.logInt(s);
        } catch {
            console.log("not ready yet: the pool needs more observation slots or history; run again later (ORACLE=<addr>)");
        }
    }
}
