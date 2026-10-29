// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LevExchange} from "../src/LevExchange.sol";
import {LevExchangeAdmin} from "../src/LevExchangeAdmin.sol";
import {LevPool} from "../src/LevPool.sol";
import {LevLens} from "../src/LevLens.sol";
import {LevRouter, ILevExchangeForRouter} from "../src/LevRouter.sol";
import {Config} from "../src/LevTypes.sol";
import {ILevPool, ILevExchange, ILevNav} from "../src/interfaces/ILevPool.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {TickRatio} from "../src/libraries/TickRatio.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

abstract contract Base is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ONE = 1e18;
    int24 internal constant MAX_TICK = type(int24).max;
    int24 internal constant MIN_TICK = type(int24).min;

    // Price moves as ticks: 1.0001^tick.
    int24 internal constant UP_10 = 953; // +10%
    int24 internal constant UP_17_5 = 1613; // +17.5%
    int24 internal constant UP_60 = 4700; // x1.6
    int24 internal constant DOWN_50 = -6932; // -50%

    LevPool internal pool;
    LevExchange internal ex;
    LevExchangeAdmin internal exa; // the same address, typed for the functions LevExchange forwards
    LevLens internal lens;
    LevRouter internal router;
    MockOracle internal o0;
    MockOracle internal o1;
    MockOracle internal o2;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        pool = new LevPool{value: 0.001 ether}(owner);
        ex = new LevExchange(ILevPool(address(pool)), owner, treasury, address(new LevExchangeAdmin()));
        exa = LevExchangeAdmin(payable(address(ex)));
        lens = new LevLens(ex);
        router = new LevRouter(ILevExchangeForRouter(address(ex)), owner);
        vm.startPrank(owner);
        pool.setExchange(ILevExchange(address(ex)));
        pool.setNavSource(ILevNav(address(lens)));
        exa.setRouter(address(router));
        vm.stopPrank();

        o0 = new MockOracle(0, 400 ether);
        o1 = new MockOracle(0, 400 ether);
        o2 = new MockOracle(0, 400 ether);
        vm.startPrank(owner);
        exa.listMarket(o0, 10, 5 ether);
        exa.listMarket(o1, 10, 5 ether);
        exa.listMarket(o2, 10, 5 ether);
        vm.stopPrank();

        // 8 ETH keeps the pool in the +400% max-win tier and leaves 4 ETH of max-win room.
        vm.deal(lp, 100 ether);
        vm.prank(lp);
        pool.deposit{value: 8 ether}();

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.prank(alice);
        ex.deposit{value: 10 ether}();
        vm.prank(bob);
        ex.deposit{value: 10 ether}();
    }

    /// @dev Reads the cheatcode clock: via-IR can cache block.timestamp inside one test function.
    function _wait(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    function _open(address who, uint256 marketId, bool isLong, uint8 lev, uint256 stake) internal returns (uint256) {
        vm.prank(who);
        return ex.open(marketId, isLong, lev, stake, isLong ? MAX_TICK : MIN_TICK);
    }

    /// @dev Closes at any price: no limit.
    function _close(address who, uint256 id) internal {
        bool isLong = lens.getPosition(id).position.isLong;
        vm.prank(who);
        ex.close(id, isLong ? MIN_TICK : MAX_TICK);
    }

    function _ratio(int256 dTick) internal pure returns (uint256) {
        return TickRatio.ratio(dTick);
    }

    /// @dev Expected trader P&L before fees, uncapped.
    function _pnl(uint256 stake, uint8 lev, bool isLong, int24 entry, int24 exit) internal pure returns (int256) {
        int256 move = int256(_ratio(int256(exit) - int256(entry))) - int256(ONE);
        if (!isLong) move = -move;
        return (int256(stake) * move * int256(uint256(lev))) / int256(ONE);
    }

    function _openFee(uint256 stake, uint8 lev) internal pure returns (uint256) {
        uint256 a = stake * 100;
        uint256 b = stake * lev * 25;
        return (a > b ? a : b) / BPS;
    }

    /// @dev Every wei the exchange holds belongs to a trader balance, an open stake or the treasury.
    function _assertSolvent() internal view {
        assertEq(address(pool).balance, pool.cash(), "pool cash");
        uint256 bals = ex.balanceOf(alice) + ex.balanceOf(bob) + ex.balanceOf(keeper) + ex.balanceOf(lp);
        assertEq(address(ex).balance, bals + lens.totalOpenStake() + ex.treasuryBalance(), "exchange books");
    }
}
