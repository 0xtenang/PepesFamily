// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {UniV4SampledOracle, IExtsload} from "../src/oracles/UniV4SampledOracle.sol";
import {UniV4BridgedOracle} from "../src/oracles/UniV4BridgedOracle.sol";
import {IUniswapV3PoolLike} from "../src/oracles/UniV3Oracle.sol";
import {PoolKey, toPoolId} from "../src/interfaces/IUniswapV4Minimal.sol";
import {MockPoolManager} from "../src/mocks/MockPoolManager.sol";
import {MockV3Pool} from "../src/mocks/MockV3Pool.sol";

contract UniV4BridgedOracleTest is Test {
    MockPoolManager pm;
    MockV3Pool bridge;
    UniV4BridgedOracle o;
    PoolKey key;
    bytes32 id;
    address keeper = makeAddr("keeper");
    address weth = address(0x1000);
    address usd = address(0x2000); // sorts after WETH: WETH is token0 of the bridge
    address coin = address(0x3000); // sorts after the quote: quote is currency0 of the coin pool

    function _wait(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    function setUp() public {
        vm.warp(1_750_000_000);
        pm = new MockPoolManager();
        // bridge tick -2000: 1.0001^-2000 quote per ETH, so ETH per quote is tick +2000
        bridge = new MockV3Pool(weth, usd, -2000, 1000 ether, uint64(block.timestamp - 3600));
        key = PoolKey({currency0: usd, currency1: coin, fee: 0x800000, tickSpacing: 200, hooks: address(0xbeef)});
        id = toPoolId(key);
        o = new UniV4BridgedOracle(IExtsload(address(pm)), key, coin, IUniswapV3PoolLike(address(bridge)), weth, 90, 600, 30, 60, address(this));
        o.setKeeper(keeper, true);
        pm.setSlot0(id, uint160(2 ** 96), 0);
        pm.setLiquidity(id, 10 ether);
    }

    function _pokeAt(int24 coinPoolTick) internal {
        pm.setSlot0(id, uint160(2 ** 96), coinPoolTick);
        vm.prank(keeper);
        o.poke();
        _wait(30);
    }

    function test_setup() public view {
        assertEq(o.quote(), usd);
        assertEq(o.coin(), coin);
        assertTrue(o.ethIsToken0());
        assertTrue(o.ethIsCurrency0()); // here: the quote is currency0
        assertEq(o.poolId(), id);
    }

    /// The coin pool prices the coin in the quote at -tick (quote is currency0); the bridge adds ETH per quote.
    function test_combinedPrice() public {
        for (uint256 i; i < 22; ++i) _pokeAt(-100); // coin = 1.0001^100 quote
        (int24 spot, int24 fast, int24 slow,) = o.read();
        assertEq(spot, 2100);
        assertEq(fast, 2100);
        assertEq(slow, 2100);
        bridge.setTick(-2500); // ETH gets cheaper in quote terms: the coin's ETH price rises
        (spot,,,) = o.read();
        assertEq(spot, 2600);
    }

    /// Depth: quote-side reserves valued in ETH (10 quote at sqrt price 1, times 1.0001^2000 ETH per quote).
    function test_depthInEth() public {
        for (uint256 i; i < 22; ++i) _pokeAt(0);
        (,,, uint256 liq) = o.read();
        assertApproxEqRel(liq, 10 ether * 12214 / 10000, 1e14); // 1.0001^2000 = 1.2214
    }

    /// Depth never exceeds the bridge's own ETH side.
    function test_depthCappedByBridge() public {
        bridge.setLiquidity(1 ether); // ETH side = L / sqrt(1.0001^-2000) = 1.105 ETH
        for (uint256 i; i < 22; ++i) _pokeAt(0);
        (,,, uint256 liq) = o.read();
        assertApproxEqRel(liq, 1.10517 ether, 1e14);
    }

    function test_onePushedSampleDoesNotMoveFast() public {
        for (uint256 i; i < 22; ++i) _pokeAt(-100);
        _pokeAt(-5000);
        (, int24 fast,,) = o.read();
        assertEq(fast, 2100);
    }

    function test_rejectsWrongPools() public {
        PoolKey memory other = key;
        other.currency1 = address(0x4000);
        vm.expectRevert(UniV4BridgedOracle.NotCoinPool.selector);
        new UniV4BridgedOracle(IExtsload(address(pm)), other, coin, IUniswapV3PoolLike(address(bridge)), weth, 90, 600, 30, 60, address(this));
        MockV3Pool wrong = new MockV3Pool(weth, address(0x5000), 0, 1 ether, uint64(block.timestamp));
        vm.expectRevert(UniV4BridgedOracle.NotBridgePool.selector);
        new UniV4BridgedOracle(IExtsload(address(pm)), key, coin, IUniswapV3PoolLike(address(wrong)), weth, 90, 600, 30, 60, address(this));
    }

    function test_onlyKeeperPokes() public {
        vm.expectRevert(UniV4SampledOracle.NotKeeper.selector);
        o.poke();
    }
}
