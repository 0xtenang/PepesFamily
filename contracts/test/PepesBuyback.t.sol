// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

import {PepesFamily} from "../src/PepesFamily.sol";
import {PepesFamilyRouter} from "../src/PepesFamilyRouter.sol";
import {PepesBuyback} from "../src/PepesBuyback.sol";
import {PadToken} from "../src/PadToken.sol";
import {DeployLib} from "../script/DeployLib.sol";
import {MockIMD, MockPepes, MockPepesRouter} from "./Mocks.sol";

/// @notice The buyback's price guard against a real priced pool. "$Pepes" is a token launched on launchpad A (same
///         4% hook fee and single-sided curve as the live v1 $Pepes pool); launchpad B's PepesBuyback buys it through
///         A's router, as production buys the live $Pepes through the v1 router (IMD Swarm audit ec4e3ea7, finding 1).
contract PepesBuybackGuardTest is Test {
    uint160 constant FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));

    PoolManager pm;
    MockIMD imd;
    PepesFamily padA;
    PepesFamilyRouter routerA;
    PadToken pepes;
    PepesBuyback buyback;

    address eve = makeAddr("eve");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        pm = new PoolManager(address(this));
        imd = new MockIMD();

        // Launchpad A needs a wired buyback of its own: point it at a plain mock pool.
        MockPepes mp = new MockPepes();
        MockPepesRouter mr = new MockPepesRouter(imd, mp);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        mp.mint(address(this), 10_000e18);
        imd.mint(address(this), 10_000e18);
        mp.approve(address(lp), type(uint256).max);
        imd.approve(address(lp), type(uint256).max);
        (address c0, address c1) = address(mp) < address(imd) ? (address(mp), address(imd)) : (address(imd), address(mp));
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        pm.initialize(k, TickMath.getSqrtPriceAtTick(0));
        lp.modifyLiquidity(k, ModifyLiquidityParams(-887220, 887220, 1_000e18, 0), "");
        mr.setKey(k);

        padA = _deployPad(address(mp), address(mr));
        routerA = PepesFamilyRouter(payable(padA.router()));
        pepes = PadToken(payable(padA.launch("Pepes", "PEPES", "", address(imd))));
        // a $Pepes pool with some depth: bob bought in earlier
        imd.mint(bob, 10_000e18);
        vm.startPrank(bob);
        imd.approve(address(routerA), type(uint256).max);
        routerA.buy(address(pepes), 1_000e18, 0, block.timestamp);
        vm.stopPrank();

        PepesFamily padB = _deployPad(address(pepes), address(routerA));
        buyback = PepesBuyback(padB.buyback());

        imd.mint(eve, 10_000e18);
        vm.startPrank(eve);
        imd.approve(address(routerA), type(uint256).max);
        pepes.approve(address(routerA), type(uint256).max);
        vm.stopPrank();
    }

    function _deployPad(address pepes_, address pepesRouter_) internal returns (PepesFamily) {
        bytes memory initCode = abi.encodePacked(
            type(PepesFamily).creationCode,
            abi.encode(
                pm,
                address(imd),
                address(this),
                address(this),
                DeployLib.startTickForMarketCap(100e18),
                PepesFamily.ImdEthPool(10_000, 100, address(0)),
                pepes_,
                pepesRouter_
            )
        );
        (bytes32 salt, address expected) = DeployLib.mineSalt(address(this), FLAGS, initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(deployed == expected, "hook address");
        return PepesFamily(deployed);
    }

    function _tryBuyback() internal returns (bool ok) {
        try buyback.buybackAndBurnPepes(0, block.timestamp) {
            ok = true;
        } catch {}
    }

    function _depth() internal view returns (uint256) {
        return buyback.maxBuyback() * 100;
    }

    /// Audit ec4e3ea7 finding 1: eve buys 40% of depth, calls the buyback every hour for 8 hours, then sells.
    function test_pumpThenSeriesStalls() public {
        uint256 depth = _depth();
        imd.mint(address(buyback), depth / 5);
        uint256 start = imd.balanceOf(eve);
        vm.startPrank(eve);
        uint256 got = routerA.buy(address(pepes), (depth * 40) / 100, 0, block.timestamp);
        uint256 runs;
        for (uint256 h; h < 8; h++) {
            vm.warp(block.timestamp + 1 hours);
            if (_tryBuyback()) runs++;
        }
        routerA.sell(address(pepes), got, 0, block.timestamp);
        vm.stopPrank();
        assertEq(runs, 0, "no buyback into the pump");
        assertLe(imd.balanceOf(eve), start, "front-running the buyback must not pay");
        assertTrue(_tryBuyback(), "runs again once the price is back");
    }

    /// Audit b803125e finding 1: before every hourly buyback eve buys 1% of depth, for 24 hours, then sells.
    function test_pacedPreBuysDoNotPay() public {
        uint256 depth = _depth();
        imd.mint(address(buyback), (depth * 40) / 100);
        vm.warp(block.timestamp + 1 hours);
        assertTrue(_tryBuyback()); // a fresh reference
        uint256 start = imd.balanceOf(eve);
        uint256 got;
        uint256 runs;
        vm.startPrank(eve);
        for (uint256 h; h < 24; h++) {
            vm.warp(block.timestamp + 1 hours);
            got += routerA.buy(address(pepes), buyback.maxBuyback(), 0, block.timestamp);
            if (_tryBuyback()) runs++;
        }
        routerA.sell(address(pepes), got, 0, block.timestamp);
        vm.stopPrank();
        emit log_named_uint("buybacks that ran", runs);
        emit log_named_decimal_int("eve P&L (IMD)", int256(imd.balanceOf(eve)) - int256(start), 18);
        assertLe(imd.balanceOf(eve), start, "riding the hourly series must not pay");
    }

    /// Audit b803125e finding 2: after 48 idle days a 40%-of-depth pump still stalls the buyback.
    function test_idleTimeDoesNotLoosenTheGuard() public {
        vm.warp(block.timestamp + 48 days);
        uint256 depth = _depth();
        imd.mint(address(buyback), depth / 5);
        uint256 start = imd.balanceOf(eve);
        vm.startPrank(eve);
        uint256 got = routerA.buy(address(pepes), (depth * 40) / 100, 0, block.timestamp);
        uint256 runs;
        for (uint256 h; h < 8; h++) {
            vm.warp(block.timestamp + 1 hours);
            if (_tryBuyback()) runs++;
        }
        routerA.sell(address(pepes), got, 0, block.timestamp);
        vm.stopPrank();
        assertEq(runs, 0);
        assertLe(imd.balanceOf(eve), start);
    }

    /// Audit b803125e finding 5: sell, buyback, rebuy in one transaction no longer pins the reference low.
    function test_dumpBracketDoesNotStall() public {
        vm.warp(block.timestamp + 1 hours);
        uint256 bag = pepes.balanceOf(bob);
        vm.startPrank(bob);
        imd.transfer(address(buyback), 0.1e18);
        pepes.approve(address(routerA), type(uint256).max);
        uint256 out = routerA.sell(address(pepes), bag / 20, 0, block.timestamp);
        buyback.buybackAndBurnPepes(0, block.timestamp);
        routerA.buy(address(pepes), out, 0, block.timestamp);
        vm.stopPrank();
        assertLe(buyback.priceRiseBps(), buyback.MAX_PRICE_RISE_BPS(), "the reference wasn't dragged down");
        imd.mint(address(buyback), 100e18);
        vm.warp(block.timestamp + 1 hours);
        assertTrue(_tryBuyback(), "the next buyback runs on time");
    }

    function test_dustCannotTakeTheSlot() public {
        imd.mint(address(buyback), 0.1e18 - 1);
        vm.expectRevert(PepesBuyback.BadAmount.selector);
        buyback.buybackAndBurnPepes(0, block.timestamp);
    }

    /// Without outside trades the hourly series runs: the reference follows each buyback's own impact.
    function test_hourlySeriesRuns() public {
        imd.mint(address(buyback), 1_000e18);
        for (uint256 h; h < 5; h++) {
            assertTrue(_tryBuyback(), "buyback runs");
            vm.warp(block.timestamp + 1 hours);
        }
    }

    /// An organic rise is followed at 2% a day through pokes (anyone, or every recycle and buyback attempt).
    function test_organicRiseOnlyDelays() public {
        imd.mint(address(buyback), 100e18);
        vm.prank(eve);
        routerA.buy(address(pepes), 100e18, 0, block.timestamp); // ~+20%
        uint256 rise = buyback.priceRiseBps();
        assertGt(rise, 1_000);
        assertFalse(_tryBuyback());
        uint256 days_;
        while (!_tryBuyback()) {
            vm.warp(block.timestamp + 1 days);
            buyback.poke();
            days_++;
            assertLt(days_, 30, "follows the market within weeks");
        }
        emit log_named_uint("days until the buyback resumed", days_);
    }

    /// A falling price never blocks the buyback.
    function test_fallingPriceNeverBlocks() public {
        imd.mint(address(buyback), 10e18);
        uint256 bal = pepes.balanceOf(bob);
        vm.startPrank(bob);
        pepes.approve(address(routerA), bal);
        routerA.sell(address(pepes), bal / 2, 0, block.timestamp);
        vm.stopPrank();
        assertEq(buyback.priceRiseBps(), 0);
        assertTrue(_tryBuyback());
    }

    function test_wiringRecorded() public view {
        assertGt(uint256(buyback.refSqrtPrice()), 0);
        assertEq(buyback.priceRiseBps(), 0, "the reference is the price at deployment");
        assertEq(buyback.imdIsCurrency0(), address(imd) < address(pepes));
    }
}
