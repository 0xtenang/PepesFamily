// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickRatio} from "../src/libraries/TickRatio.sol";
import {UniV3Oracle, IUniswapV3PoolLike} from "../src/oracles/UniV3Oracle.sol";
import {UniV4SampledOracle, IExtsload} from "../src/oracles/UniV4SampledOracle.sol";
import {MockV3Pool} from "../src/mocks/MockV3Pool.sol";
import {MockPoolManager} from "../src/mocks/MockPoolManager.sol";
import {MockERC20, MockWETH} from "../src/mocks/MockERC20.sol";

contract TickRatioTest is Test {
    function test_knownValues() public pure {
        assertEq(TickRatio.ratio(0), 1e18);
        assertEq(TickRatio.ratio(1), 1.0001e18);
        assertApproxEqRel(TickRatio.ratio(6932), 2e18, 1e14); // 1.0001^6932 ~ 2
        assertApproxEqRel(TickRatio.ratio(-6932), 0.5e18, 1e14);
        assertApproxEqRel(TickRatio.ratio(10_000), 2.718145926825e18, 1e10);
        assertApproxEqRel(TickRatio.ratio(-46_054), 0.01e18, 1e13); // -99%
    }

    function test_sqrtRatio() public pure {
        assertEq(TickRatio.sqrtRatio(0), 1e18);
        assertApproxEqRel(TickRatio.sqrtRatio(13_863), 2e18, 1e14); // 1.0001^13863 ~ 4
        uint256 s = TickRatio.sqrtRatio(-184_200);
        assertApproxEqRel((s * s) / 1e18, TickRatio.ratio(-184_200), 1e12);
    }

    function test_saturatesInsteadOfReverting() public pure {
        assertEq(TickRatio.ratio(5_000_000), TickRatio.ratio(400_000));
        assertEq(TickRatio.ratio(-5_000_000), TickRatio.ratio(-400_000));
    }

    function testFuzz_inverse(int24 t) public pure {
        int256 d = int256(t) % 200_000;
        uint256 up = TickRatio.ratio(d);
        uint256 down = TickRatio.ratio(-d);
        assertApproxEqRel((up * down) / 1e18, 1e18, 1e9);
    }
}

contract UniV3OracleTest is Test {
    MockWETH weth;

    function _wait(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    MockERC20 coin;

    function setUp() public {
        vm.warp(1_750_000_000);
        weth = new MockWETH();
        coin = new MockERC20("Coin", "COIN");
    }

    function test_coinAsToken0() public {
        MockV3Pool p = new MockV3Pool(address(coin), address(weth), 100, 1e21, uint64(block.timestamp - 1 days));
        p.increaseObservationCardinalityNext(1801);
        weth.mint(address(p), 1e30); // so the WETH-balance cap doesn't bind
        weth.mint(address(p), 42 ether);
        UniV3Oracle o = new UniV3Oracle(IUniswapV3PoolLike(address(p)), IERC20(address(weth)), 60, 1800);
        _wait(10);
        p.setTick(400);
        _wait(30);
        (int24 spot, int24 fast, int24 slow, uint256 liq) = o.read();
        assertEq(spot, 400);
        // last 60s: 30s at 100, 30s at 400
        assertEq(fast, 250);
        // last 1800s: 1770s at 100, 30s at 400
        assertEq(slow, int24((int256(100) * 1770 + 400 * 30) / 1800));
        // ETH depth comes from time-weighted in-range liquidity, not the pool's WETH balance.
        assertApproxEqRel(liq, (1e21 * TickRatio.sqrtRatio(slow)) / 1e18, 1e12);
    }

    function test_coinAsToken1DepthUsesInverseSqrtPrice() public {
        MockV3Pool p = new MockV3Pool(address(weth), address(coin), 200, 1e21, uint64(block.timestamp - 1 days));
        p.increaseObservationCardinalityNext(1801);
        weth.mint(address(p), 1e30); // so the WETH-balance cap doesn't bind
        UniV3Oracle o = new UniV3Oracle(IUniswapV3PoolLike(address(p)), IERC20(address(weth)), 60, 1800);
        (,,, uint256 liq) = o.read();
        assertApproxEqRel(liq, (1e21 * 1e18) / TickRatio.sqrtRatio(200), 1e12);
    }

    /// Regression: liquidity added for a moment (or WETH parked in the pool) can't unlock leverage.
    function test_liquiditySpikeBarelyMovesDepth() public {
        MockV3Pool p = new MockV3Pool(address(coin), address(weth), 0, 1e20, uint64(block.timestamp - 1 days));
        p.increaseObservationCardinalityNext(1801);
        weth.mint(address(p), 1e30); // so the WETH-balance cap doesn't bind
        UniV3Oracle o = new UniV3Oracle(IUniswapV3PoolLike(address(p)), IERC20(address(weth)), 60, 1800);
        (,,, uint256 before) = o.read();
        weth.mint(address(p), 1000 ether);
        p.setLiquidity(1e23); // 1000x deeper, for one second
        _wait(1);
        p.setLiquidity(1e20);
        (,,, uint256 afterSpike) = o.read();
        assertApproxEqRel(afterSpike, before, 0.001e18);
    }

    function test_sustainedLiquidityCounts() public {
        MockV3Pool p = new MockV3Pool(address(coin), address(weth), 0, 1e20, uint64(block.timestamp - 1 days));
        p.increaseObservationCardinalityNext(1801);
        weth.mint(address(p), 1e30); // so the WETH-balance cap doesn't bind
        UniV3Oracle o = new UniV3Oracle(IUniswapV3PoolLike(address(p)), IERC20(address(weth)), 60, 1800);
        p.setLiquidity(4e20);
        _wait(1800);
        (,,, uint256 liq) = o.read();
        assertApproxEqRel(liq, 4e20, 1e12);
    }

    function test_coinAsToken1FlipsSign() public {
        MockV3Pool p = new MockV3Pool(address(weth), address(coin), 500, 1e20, uint64(block.timestamp - 1 days));
        p.increaseObservationCardinalityNext(1801);
        weth.mint(address(p), 1e30); // so the WETH-balance cap doesn't bind
        UniV3Oracle o = new UniV3Oracle(IUniswapV3PoolLike(address(p)), IERC20(address(weth)), 60, 1800);
        (int24 spot, int24 fast, int24 slow,) = o.read();
        assertEq(spot, -500);
        assertEq(fast, -500);
        assertEq(slow, -500);
    }

    function test_negativeMeanRoundsDown() public {
        MockV3Pool p = new MockV3Pool(address(coin), address(weth), -1, 1e20, uint64(block.timestamp - 1 days));
        p.increaseObservationCardinalityNext(1801);
        weth.mint(address(p), 1e30); // so the WETH-balance cap doesn't bind
        UniV3Oracle o = new UniV3Oracle(IUniswapV3PoolLike(address(p)), IERC20(address(weth)), 60, 1800);
        _wait(1);
        p.setTick(0);
        _wait(59);
        (, int24 fast,,) = o.read();
        assertEq(fast, -1); // -1/60 rounds toward negative infinity, like Uniswap's OracleLibrary
    }

    /// Regression (F3): the feed refuses to report until the pool keeps a full slow window of observations,
    /// so nobody can run the history short later to force the stale fallback.
    function test_needsEnoughObservationSlots() public {
        MockV3Pool p = new MockV3Pool(address(coin), address(weth), 0, 1e20, uint64(block.timestamp - 1 days));
        weth.mint(address(p), 1e30);
        UniV3Oracle o = new UniV3Oracle(IUniswapV3PoolLike(address(p)), IERC20(address(weth)), 60, 1800);
        vm.expectRevert(UniV3Oracle.HistoryTooShort.selector);
        o.read();
        o.prepare(1800);
        vm.expectRevert(UniV3Oracle.HistoryTooShort.selector);
        o.read();
        o.prepare(1801);
        o.read();
    }

    /// Regression (F12): depth is never more than the WETH the pool really holds.
    function test_depthCappedByWethHeld() public {
        MockV3Pool p = new MockV3Pool(address(coin), address(weth), 0, 1e24, uint64(block.timestamp - 1 days));
        p.increaseObservationCardinalityNext(1801);
        weth.mint(address(p), 3 ether); // a narrow position: huge virtual liquidity, little WETH
        UniV3Oracle o = new UniV3Oracle(IUniswapV3PoolLike(address(p)), IERC20(address(weth)), 60, 1800);
        (,,, uint256 liq) = o.read();
        assertEq(liq, 3 ether);
    }

    function test_rejectsNonWethPool() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        MockV3Pool p = new MockV3Pool(address(coin), address(other), 0, 1e20, uint64(block.timestamp));
        p.increaseObservationCardinalityNext(1801);
        vm.expectRevert(UniV3Oracle.NotWethPool.selector);
        new UniV3Oracle(IUniswapV3PoolLike(address(p)), IERC20(address(weth)), 60, 1800);
    }

    function test_revertsWithoutHistory() public {
        MockV3Pool p = new MockV3Pool(address(coin), address(weth), 0, 1e20, uint64(block.timestamp));
        p.increaseObservationCardinalityNext(1801);
        weth.mint(address(p), 1e30); // so the WETH-balance cap doesn't bind
        UniV3Oracle o = new UniV3Oracle(IUniswapV3PoolLike(address(p)), IERC20(address(weth)), 60, 1800);
        vm.expectRevert(bytes("OLD"));
        o.read();
    }
}

contract UniV4SampledOracleTest is Test {
    MockPoolManager pm;
    UniV4SampledOracle o;
    bytes32 constant POOL_ID = keccak256("coin/eth");
    address keeper = makeAddr("keeper");

    function _wait(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    function setUp() public {
        vm.warp(1_750_000_000);
        pm = new MockPoolManager();
        // ETH is currency0 (native ETH sorts first), so the coin's ETH price is 1.0001^-tick.
        o = new UniV4SampledOracle(IExtsload(address(pm)), POOL_ID, true, 90, 600, 30, 60, address(this));
        o.setKeeper(keeper, true);
        pm.setSlot0(POOL_ID, uint160(2 ** 96), 0);
        pm.setLiquidity(POOL_ID, 10 ether);
    }

    function _pokeAt(int24 tick) internal {
        pm.setSlot0(POOL_ID, uint160(2 ** 96), tick);
        vm.prank(keeper);
        o.poke();
        _wait(30);
    }

    function test_onlyKeeperPokes() public {
        vm.expectRevert(UniV4SampledOracle.NotKeeper.selector);
        o.poke();
    }

    function test_pokeSpacing() public {
        vm.startPrank(keeper);
        o.poke();
        vm.expectRevert(UniV4SampledOracle.TooSoon.selector);
        o.poke();
        vm.stopPrank();
    }

    function test_averagesFromSamples() public {
        for (uint256 i; i < 20; ++i) _pokeAt(-100); // coin price tick +100
        _pokeAt(-400);
        _pokeAt(-400);
        (int24 spot, int24 fast, int24 slow, uint256 liq) = o.read();
        assertEq(spot, 400);
        assertEq(fast, 400); // last 60s are both +400 samples
        assertEq(slow, int24((int256(100) * 540 + 400 * 60) / 600));
        assertEq(liq, 10 ether); // sqrtPrice 1: ETH side equals liquidity
    }

    /// Regression: a burst of liquidity right before a read can't raise the reported depth.
    function test_depthIsSmallestSample() public {
        for (uint256 i; i < 22; ++i) _pokeAt(0);
        pm.setLiquidity(POOL_ID, 1000 ether);
        (,,, uint256 liq) = o.read();
        assertEq(liq, 10 ether);
        pm.setLiquidity(POOL_ID, 2 ether); // a real drop shows at once
        (,,, liq) = o.read();
        assertEq(liq, 2 ether);
    }

    /// Regression (F11): one pushed sample can't move the fast price; it's the median of the last three.
    function test_onePushedSampleDoesNotMoveFast() public {
        for (uint256 i; i < 22; ++i) _pokeAt(-100);
        _pokeAt(-5000); // spot pushed for the moment of one poke
        (, int24 fast,,) = o.read();
        assertEq(fast, 100);
    }

    function test_rejectsSparseSampling() public {
        vm.expectRevert(UniV4SampledOracle.BadWindows.selector);
        new UniV4SampledOracle(IExtsload(address(pm)), POOL_ID, true, 60, 600, 30, 60, address(this)); // fast < 3 samples
        vm.expectRevert(UniV4SampledOracle.BadWindows.selector);
        new UniV4SampledOracle(IExtsload(address(pm)), POOL_ID, true, 90, 600, 30, 300, address(this)); // maxAge too long
    }

    function test_needsHistory() public {
        _pokeAt(0);
        vm.expectRevert(UniV4SampledOracle.NotEnoughHistory.selector);
        o.read();
    }

    function test_staleWithoutPokes() public {
        for (uint256 i; i < 21; ++i) _pokeAt(0);
        o.read();
        _wait(301);
        vm.expectRevert(UniV4SampledOracle.Stale.selector);
        o.read();
    }
}
