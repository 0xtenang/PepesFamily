// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LevExchange} from "../src/LevExchange.sol";
import {LevExchangeAdmin} from "../src/LevExchangeAdmin.sol";
import {LevPool} from "../src/LevPool.sol";
import {LevLens} from "../src/LevLens.sol";
import {LevRouter, ILevExchangeForRouter} from "../src/LevRouter.sol";
import {CreatorFeeRouterV2} from "../src/fees/CreatorFeeRouterV2.sol";
import {IPonsLaunchFactory, IPonsFeeEscrow} from "../src/interfaces/IPons.sol";
import {ILevPool, ILevExchange, ILevNav, IFeeSource} from "../src/interfaces/ILevPool.sol";
import {UniV3Oracle, IUniswapV3PoolLike} from "../src/oracles/UniV3Oracle.sol";
import {MockERC20, MockWETH} from "../src/mocks/MockERC20.sol";
import {MockV3Pool} from "../src/mocks/MockV3Pool.sol";
import {TickRatio} from "../src/libraries/TickRatio.sol";

/// @notice Full local stack on anvil: mock WETH, five mock memecoins with Uniswap V3-style pools, the protocol,
///         an LP deposit and a creator-fee donation. Writes deployments/local.json for the keeper and web app.
/// forge script script/DeployLocal.s.sol --rpc-url local --broadcast --private-key <anvil key 0>
contract DeployLocal is Script {
    struct Coin {
        string name;
        string symbol;
        int24 tick; // coin price in ETH = 1.0001^tick
        uint256 liquidityEth;
    }

    function run() external {
        Coin[5] memory coins = [
            Coin("Plonk", "PLONK", -184_200, 600 ether), // 10x tier, 3 ETH net cap
            Coin("Wobble", "WOB", -176_000, 300 ether), // 10x tier, 1.5 ETH net cap
            Coin("Snorkel", "SNRK", -191_500, 20 ether), // 5x tier
            Coin("Grumble", "GRMB", -168_300, 9 ether), // 5x tier
            Coin("Zoomer", "ZOOM", -199_000, 4 ether) // 2x tier
        ];

        vm.startBroadcast();
        address me = msg.sender;
        MockWETH weth = new MockWETH();
        LevPool pool = new LevPool{value: 0.001 ether}(me);
        LevExchange ex = new LevExchange(ILevPool(address(pool)), me, me, address(new LevExchangeAdmin()));
        LevExchangeAdmin exa = LevExchangeAdmin(payable(address(ex)));
        pool.setExchange(ILevExchange(address(ex)));
        LevLens lens = new LevLens(ex);
        pool.setNavSource(ILevNav(address(lens)));
        LevRouter tradeRouter = new LevRouter(ILevExchangeForRouter(address(ex)), me);
        exa.setRouter(address(tradeRouter));
        // The local stack has no Pons: the fee router just splits ETH sent to it (80% pool, 10% buyback, 10% ops).
        CreatorFeeRouterV2 router = new CreatorFeeRouterV2(
            pool, IPonsLaunchFactory(address(0)), IPonsFeeEscrow(address(0)), address(0), 0, me, address(0), 0, me
        );
        pool.setFeeSource(IFeeSource(address(router)));

        string memory marketsJson = "[";
        for (uint256 i; i < coins.length; ++i) {
            MockERC20 coin = new MockERC20(coins[i].name, coins[i].symbol);
            // In-range liquidity that holds `liquidityEth` on the WETH side: amount1 = L * sqrtPrice.
            uint128 liq = uint128((coins[i].liquidityEth * 1e18) / TickRatio.sqrtRatio(coins[i].tick));
            MockV3Pool uni = new MockV3Pool(address(coin), address(weth), coins[i].tick, liq, uint64(block.timestamp - 2 days));
            weth.mint(address(uni), coins[i].liquidityEth);
            UniV3Oracle oracle = new UniV3Oracle(IUniswapV3PoolLike(address(uni)), IERC20(address(weth)), 60, 1800);
            oracle.prepare(1801);
            uint256 id = exa.listMarket(oracle, 10, 5 ether);
            marketsJson = string.concat(
                marketsJson,
                i == 0 ? "" : ",",
                '{"id":',
                vm.toString(id),
                ',"name":"',
                coins[i].name,
                '","symbol":"',
                coins[i].symbol,
                '","coin":"',
                vm.toString(address(coin)),
                '","uniPool":"',
                vm.toString(address(uni)),
                '","oracle":"',
                vm.toString(address(oracle)),
                '","kind":"v3-mock"}'
            );
        }
        marketsJson = string.concat(marketsJson, "]");

        // House money from creator fees, then an LP joins.
        (bool ok,) = address(router).call{value: 3 ether}("");
        require(ok, "router");
        router.harvest();
        pool.deposit{value: 15 ether}();
        vm.stopBroadcast();

        string memory json = string.concat(
            '{"chainId":',
            vm.toString(block.chainid),
            ',"rpcUrl":"http://127.0.0.1:8547","exchange":"',
            vm.toString(address(ex)),
            '","lens":"',
            vm.toString(address(lens)),
            '","tradeRouter":"',
            vm.toString(address(tradeRouter)),
            '","pool":"',
            vm.toString(address(pool)),
            '","router":"',
            vm.toString(address(router)),
            '","weth":"',
            vm.toString(address(weth)),
            '","deployer":"',
            vm.toString(me),
            '","markets":',
            marketsJson,
            "}"
        );
        vm.writeFile("deployments/local.json", json);
    }
}
