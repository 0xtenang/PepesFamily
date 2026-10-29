// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {LevExchange} from "../../src/LevExchange.sol";
import {LevExchangeAdmin} from "../../src/LevExchangeAdmin.sol";
import {LevPool} from "../../src/LevPool.sol";
import {LevLens} from "../../src/LevLens.sol";
import {ILevPool, ILevExchange, ILevNav} from "../../src/interfaces/ILevPool.sol";
import {UniV4BridgedOracle} from "../../src/oracles/UniV4BridgedOracle.sol";
import {IExtsload} from "../../src/oracles/UniV4SampledOracle.sol";
import {IUniswapV3PoolLike} from "../../src/oracles/UniV3Oracle.sol";
import {PoolKey, toPoolId} from "../../src/interfaces/IUniswapV4Minimal.sol";

/// @notice UBIK, PepesFamily's first long/short market, priced from the live UBIK/USDG Uniswap V4 pool and the
///         WETH/USDG Uniswap V3 pool on Robinhood Chain (4663).
/// @dev Runs only with FORK_URL set (FORK_BLOCK pins a block, default latest); otherwise every test skips.
///      The pool key is from the PoolManager's Initialize log for pool 0x4aaa…d2a7 (tx 0x0b034ea9…8d20).
contract UbikMarketForkTest is Test {
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant UBIK = 0x812486EAea648819853F8E372dc9f1516C7868Bd;
    address internal constant UBIK_HOOK = 0x08E52564Bad99E05a694b4809F397edcA417A080;
    address internal constant WETH_USDG_V3 = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // 0.01%, the deepest
    bytes32 internal constant UBIK_POOL_ID = 0x4aaa4f57bec2b6e67dac42909c8c4f9a6ddaf02bb63f8dcbbafb35316731d2a7;

    bool internal forked;
    UniV4BridgedOracle internal oracle;
    address internal keeper = makeAddr("keeper");

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory url = vm.envOr("FORK_URL", string(""));
        if (bytes(url).length == 0) return;
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) blk = vm.parseUint(vm.toString(vm.rpc(url, "eth_blockNumber", "[]")));
        vm.createSelectFork(url, blk);
        forked = true;
        oracle = new UniV4BridgedOracle(
            IExtsload(POOL_MANAGER), ubikKey(), UBIK, IUniswapV3PoolLike(WETH_USDG_V3), WETH, 120, 1800, 30, 60, address(this)
        );
        oracle.setKeeper(keeper, true);
    }

    function ubikKey() internal pure returns (PoolKey memory) {
        return PoolKey({currency0: USDG, currency1: UBIK, fee: 0x800000, tickSpacing: 200, hooks: UBIK_HOOK});
    }

    function _wait(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    /// Fills the slow window with samples (the fork's pools don't move, so every sample is today's price).
    function _warmUp() internal {
        for (uint256 i; i < 62; ++i) {
            vm.prank(keeper);
            oracle.poke();
            _wait(30);
        }
    }

    function test_keyMatchesPoolId() public onlyFork {
        assertEq(toPoolId(ubikKey()), UBIK_POOL_ID);
        assertEq(oracle.poolId(), UBIK_POOL_ID);
        assertTrue(oracle.ethIsToken0());
    }

    /// UBIK traded at about 2.63e-6 ETH (~$0.0062) when this was written: tick ln(2.63e-6)/ln(1.0001) = -128,490.
    /// A wide band, so the test still holds after normal price moves.
    function test_readsUbikPriceInEth() public onlyFork {
        _warmUp();
        (int24 spot, int24 fast, int24 slow, uint256 liq) = oracle.read();
        console2.log("UBIK spot tick", spot);
        console2.log("UBIK fast tick", fast);
        console2.log("UBIK slow tick", slow);
        console2.log("UBIK pool depth (ETH wei)", liq);
        assertGt(spot, -150_000, "price far below expected");
        assertLt(spot, -110_000, "price far above expected");
        assertEq(fast, spot);
        assertEq(slow, spot);
        assertGt(liq, 1 ether, "depth too small");
    }

    /// The whole stack on live state: list UBIK, fund the pool, open a long and a short, close both.
    function test_tradeUbikEndToEnd() public onlyFork {
        address owner = makeAddr("owner");
        address treasury = makeAddr("treasury");
        LevPool pool = new LevPool{value: 0.001 ether}(owner);
        LevExchange ex = new LevExchange(ILevPool(address(pool)), owner, treasury, address(new LevExchangeAdmin()));
        LevExchangeAdmin exa = LevExchangeAdmin(payable(address(ex)));
        LevLens lens = new LevLens(ex);
        vm.startPrank(owner);
        pool.setExchange(ILevExchange(address(ex)));
        pool.setNavSource(ILevNav(address(lens)));
        vm.stopPrank();

        _warmUp();
        vm.prank(owner);
        uint256 id = exa.listMarket(oracle, 5, 0.5 ether);

        address lp = makeAddr("lp");
        address alice = makeAddr("alice");
        vm.deal(lp, 20 ether);
        vm.deal(alice, 2 ether);
        vm.prank(lp);
        pool.deposit{value: 10 ether}();
        vm.prank(alice);
        ex.deposit{value: 1 ether}();

        vm.startPrank(alice);
        uint256 longId = ex.open(id, true, 2, 0.05 ether, type(int24).max);
        uint256 shortId = ex.open(id, false, 2, 0.05 ether, type(int24).min);
        vm.stopPrank();

        _wait(30);
        vm.prank(keeper);
        oracle.poke();

        vm.startPrank(alice);
        ex.close(longId, type(int24).min);
        ex.close(shortId, type(int24).max);
        uint256 bal = ex.balanceOf(alice);
        ex.withdraw(bal);
        vm.stopPrank();
        console2.log("alice back after a long and a short (wei)", alice.balance);
        // flat price: only the fees are lost (2 x open + close at max(1% stake, 0.25% size))
        assertGt(alice.balance, 1.99 ether);
        assertLt(alice.balance, 2 ether);
    }
}
