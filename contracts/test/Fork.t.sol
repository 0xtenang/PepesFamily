// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {PepesFamily} from "../src/PepesFamily.sol";
import {PepesFamilyRouter} from "../src/PepesFamilyRouter.sol";
import {PepesBuyback} from "../src/PepesBuyback.sol";
import {PadToken} from "../src/PadToken.sol";
import {DeployLib} from "../script/DeployLib.sol";

interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @notice PepesFamily v4 against Robinhood Chain mainnet state: the real PoolManager, IMD, V4Quoter, and the real
///         $Pepes token and PepesFamily v1 router for the buyback-and-burn.
///   FORK_RPC=https://robinhood.drpc.org forge test --mc ForkTest -vv
contract ForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IV4Quoter constant QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant PEPES = 0xE2C46c7068566740A33A4C93f5445B07BCfE5644;
    address constant V1_ROUTER = 0xA73604EA3C393B47573986ff9Ce5A9EAb61883dC;
    address constant FEE_RECIPIENT = 0x3c8A4d94B3219F6633F2cC94094f4765b30c691C;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    PepesFamily pad;
    PepesFamilyRouter router;
    PepesBuyback buyback;
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        bytes memory initCode = abi.encodePacked(
            type(PepesFamily).creationCode,
            abi.encode(
                PM,
                IMD,
                address(this),
                FEE_RECIPIENT,
                DeployLib.startTickForMarketCap(635e18),
                PepesFamily.ImdEthPool(10_000, 100, address(0)),
                PEPES,
                V1_ROUTER
            )
        );
        (bytes32 salt,) = DeployLib.mineSalt(address(this), pad_flags(), initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        pad = PepesFamily(deployed);
        router = PepesFamilyRouter(payable(pad.router()));
        buyback = PepesBuyback(pad.buyback());
        address[2] memory users = [bob, carol];
        for (uint256 i; i < users.length; i++) {
            // Borrow IMD from the PoolManager's balance for testing.
            vm.prank(address(PM));
            IERC20(IMD).transfer(users[i], 2_500e18);
            vm.prank(users[i]);
            IERC20(IMD).approve(address(router), type(uint256).max);
        }
    }

    function pad_flags() internal pure returns (uint160) {
        return uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    }

    function test_fork_launchTradeClaim() public {
        vm.prank(bob);
        (address token, uint256 out) = router.launch("Fork Imd", "FIMD", "{}", IMD, 100e18, 1);
        PadToken t = PadToken(payable(token));
        assertEq(t.balanceOf(bob), out);
        assertEq(pad.pendingProtocolFees(IMD), 1e18);
        console.log("IMD launch mcap after 100 IMD buy (wei)", pad.marketCap(token));

        // Uniswap's deployed V4Quoter sees the same price (hook fee included) as our router.
        PoolKey memory key = pad.poolKey(token);
        (,,,, bool quoteIs0) = pad.launches(token);
        (uint256 quoted,) = QUOTER.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key, quoteIs0, 50e18, ""));
        vm.prank(carol);
        assertEq(router.buy(token, 50e18, quoted, block.timestamp), quoted);
        assertApproxEqAbs(t.withdrawableDividendOf(bob), 3e18 + 1.5e18, 10, "bob's own launch-buy fee + carol's");

        uint256 imdBefore = IERC20(IMD).balanceOf(bob);
        vm.startPrank(bob);
        t.claim();
        t.approve(address(router), out);
        uint256 got = router.sell(token, out, 0, block.timestamp);
        vm.stopPrank();
        assertGt(IERC20(IMD).balanceOf(bob) - imdBefore, got);

        uint256 feeBefore = IERC20(IMD).balanceOf(FEE_RECIPIENT);
        pad.collectProtocolFees(IMD);
        assertGt(IERC20(IMD).balanceOf(FEE_RECIPIENT) - feeBefore, 1.5e18);
    }

    /// Bob launches and never claims; after more than 7 days his rewards buy real $Pepes, which are burned.
    function test_fork_expiredRewardsBurnPepes() public {
        vm.prank(bob);
        (address token,) = router.launch("Fork Burn", "FBURN", "{}", IMD, 100e18, 1);
        PadToken t = PadToken(payable(token));
        vm.prank(carol);
        router.buy(token, 200e18, 1, block.timestamp);
        uint256 owed = t.withdrawableDividendOf(bob);
        assertGt(owed, 0);

        vm.warp(block.timestamp + 7 days + 1);
        uint256 expired = t.recycle(bob);
        assertEq(expired, owed);
        assertEq(IERC20(IMD).balanceOf(address(buyback)), expired);

        uint256 cap = buyback.maxBuyback();
        console.log("buyback cap per hour (IMD wei)", cap);
        assertGt(cap, 0, "reads the real $Pepes pool depth");
        uint256 deadBefore = IERC20(PEPES).balanceOf(DEAD);
        uint256 burned = buyback.buybackAndBurnPepes(1, block.timestamp);
        assertGt(burned, 0);
        assertEq(IERC20(PEPES).balanceOf(DEAD) - deadBefore, burned, "all bought $Pepes burned");
        assertEq(IERC20(PEPES).balanceOf(address(buyback)), 0);
        assertEq(IERC20(IMD).balanceOf(address(buyback)), expired > cap ? expired - cap : 0);
        console.log("$Pepes burned", burned);
    }
}

interface IV1Router {
    function buy(address token, uint256 amountIn, uint256 minTokensOut, uint256 deadline) external payable returns (uint256);
    function sell(address token, uint256 tokenAmount, uint256 minQuoteOut, uint256 deadline) external returns (uint256);
}

/// @notice Sandwiching the v4 buyback on the real $Pepes pool: buy $Pepes, trigger the buyback, sell. With the cap
///         (1% of the pool's IMD depth) and the $Pepes pool's 4% fee each way, the attacker loses.
contract BuybackSandwichForkTest is ForkTest {
    function test_fork_buybackSandwichDoesNotPay() public {
        // a large reserve (as if many holders' rewards expired)
        vm.prank(address(PM));
        IERC20(IMD).transfer(address(buyback), 5_000e18);
        address eve = makeAddr("eve");
        vm.prank(address(PM));
        IERC20(IMD).transfer(eve, 3_000e18);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 imd0 = IERC20(IMD).balanceOf(eve);
        vm.startPrank(eve);
        IERC20(IMD).approve(V1_ROUTER, type(uint256).max);
        uint256 bought = IV1Router(V1_ROUTER).buy(PEPES, 3_000e18, 0, deadline);
        uint256 burned = buyback.buybackAndBurnPepes(0, deadline);
        IERC20(PEPES).approve(V1_ROUTER, bought);
        IV1Router(V1_ROUTER).sell(PEPES, bought, 0, deadline);
        vm.stopPrank();
        assertGt(burned, 0);
        uint256 imd1 = IERC20(IMD).balanceOf(eve);
        emit log_named_decimal_uint("attacker IMD lost", imd0 > imd1 ? imd0 - imd1 : 0, 18);
        assertLt(imd1, imd0, "sandwiching the buyback must lose money");
    }
}
