// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {PepesFamily} from "../src/PepesFamily.sol";
import {PepesFamilyRouter, FeeSplit} from "../src/PepesFamilyRouter.sol";
import {PadToken} from "../src/PadToken.sol";
import {PepesFamilyLens} from "../src/PepesFamilyLens.sol";
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

/// @notice PepesFamily v4 against Robinhood Chain mainnet state: the real PoolManager, IMD and V4Quoter.
///   FORK_RPC=https://robinhood.drpc.org forge test --mc ForkTest -vv
contract ForkTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IV4Quoter constant QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant FEE_RECIPIENT = 0x3c8A4d94B3219F6633F2cC94094f4765b30c691C;

    PepesFamily pad;
    PepesFamilyRouter router;
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
                PepesFamily.ImdEthPool(10_000, 100, address(0))
            )
        );
        (bytes32 salt,) = DeployLib.mineSalt(address(this), pad_flags(), initCode, 0);
        address deployed;
        assembly {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        pad = PepesFamily(deployed);
        router = PepesFamilyRouter(payable(pad.router()));
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
        console.log("IMD launch mcap after 100 IMD buy (wei)", PepesFamilyLens(pad.lens()).marketCap(token));

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

    /// v5 split on mainnet state: a custom 1% creator / 1% holders / 1% burn token. Uniswap's deployed V4Quoter
    /// predicts exactly what the router delivers (burn included), and the shares land where they should.
    function test_fork_customSplit() public {
        vm.prank(bob);
        (address token,) = router.launchWithSplit("Fork Split", "FSPL", "{}", IMD, FeeSplit(100, 100, 100), 50e18, 1);
        PadToken t = PadToken(payable(token));
        PoolKey memory key = pad.poolKey(token);
        (,,,, bool quoteIs0) = pad.launches(token);
        (uint256 quoted,) = QUOTER.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key, quoteIs0, 100e18, ""));
        uint256 dead0 = t.balanceOf(0x000000000000000000000000000000000000dEaD);
        uint256 creator0 = pad.pendingCreatorFees(token);
        vm.prank(carol);
        uint256 out = router.buy(token, 100e18, quoted, block.timestamp);
        assertEq(out, quoted, "quoter matches the router, burn included");
        uint256 burned = t.balanceOf(0x000000000000000000000000000000000000dEaD) - dead0;
        assertApproxEqAbs(burned, ((out + burned) * 100) / 10_000, 2, "1% of the tokens burned");
        assertEq(pad.pendingCreatorFees(token) - creator0, 1e18, "1% of 100 IMD to the creator");
        uint256 before = IERC20(IMD).balanceOf(bob);
        pad.collectCreatorFees(token);
        assertEq(IERC20(IMD).balanceOf(bob) - before, 1.5e18, "creator: 1% of the 50 IMD launch buy and of the 100 IMD buy");
    }

    /// Bob launches and never claims; after more than 7 days his rewards go to the protocol address.
    function test_fork_expiredRewardsGoToProtocol() public {
        vm.prank(bob);
        (address token,) = router.launch("Fork Expire", "FEXP", "{}", IMD, 100e18, 1);
        PadToken t = PadToken(payable(token));
        vm.prank(carol);
        router.buy(token, 200e18, 1, block.timestamp);
        uint256 owed = t.withdrawableDividendOf(bob);
        assertGt(owed, 0);
        vm.warp(block.timestamp + 7 days + 1);
        uint256 before = IERC20(IMD).balanceOf(FEE_RECIPIENT);
        assertEq(t.recycle(bob), owed);
        assertEq(IERC20(IMD).balanceOf(FEE_RECIPIENT) - before, owed);
        assertGe(IERC20(IMD).balanceOf(token), t.accountedBalance());
    }
}
