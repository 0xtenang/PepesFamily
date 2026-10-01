// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {PepesFamily} from "../src/PepesFamily.sol";
import {PepesFamilyRouter} from "../src/PepesFamilyRouter.sol";
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

/// @notice Runs against Robinhood Chain mainnet state: FORK_RPC=https://robinhood-rpc.publicnode.com forge test --mc ForkTest
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
                DeployLib.startTickForMarketCap(1.5 ether),
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
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        // Borrow IMD from the PoolManager's balance for testing.
        vm.prank(address(PM));
        IERC20(IMD).transfer(bob, 5_000e18);
        vm.prank(bob);
        IERC20(IMD).approve(address(router), type(uint256).max);
    }

    function pad_flags() internal pure returns (uint160) {
        return uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    }

    function test_fork_ethLaunchTradeClaim() public {
        vm.prank(carol);
        (address token,) = router.launch{value: 0.1 ether}("Fork Frog", "FFROG", "{}", address(0), 0.1 ether, 1);
        PadToken t = PadToken(payable(token));
        console.log("ETH launch mcap after 0.1 ETH buy (wei)", pad.marketCap(token));

        // Uniswap's deployed V4Quoter sees the same price (hook fee included) as our router.
        PoolKey memory key = pad.poolKey(token);
        (uint256 quoted,) = QUOTER.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(key, true, 1 ether, ""));
        vm.prank(bob);
        uint256 out = router.buy{value: 1 ether}(token, 1 ether, quoted, block.timestamp);
        assertEq(out, quoted);
        assertApproxEqAbs(t.withdrawableDividendOf(carol), 0.003 ether + 0.03 ether, 10);

        uint256 before = carol.balance;
        vm.prank(carol);
        t.claim();
        assertApproxEqAbs(carol.balance - before, 0.033 ether, 10);

        uint256 bobTokens = t.balanceOf(bob);
        vm.startPrank(bob);
        t.approve(address(router), bobTokens);
        router.sell(token, bobTokens, 0, block.timestamp);
        vm.stopPrank();

        uint256 feeBefore = FEE_RECIPIENT.balance;
        pad.collectProtocolFees(address(0));
        assertGt(FEE_RECIPIENT.balance - feeBefore, 0.011 ether);
    }

    function test_fork_imdLaunchAndTrade() public {
        vm.prank(bob);
        (address token, uint256 out) = router.launch("Fork Imd", "FIMD", "{}", IMD, 100e18, 1);
        PadToken t = PadToken(payable(token));
        assertEq(t.balanceOf(bob), out);
        assertEq(pad.pendingProtocolFees(IMD), 1e18);
        console.log("IMD launch mcap after 100 IMD buy (wei)", pad.marketCap(token));

        uint256 imdBefore = IERC20(IMD).balanceOf(bob);
        vm.startPrank(bob);
        t.approve(address(router), out);
        uint256 got = router.sell(token, out, 0, block.timestamp);
        vm.stopPrank();
        assertEq(IERC20(IMD).balanceOf(bob) - imdBefore, got);
        assertGt(got, 90e18);

        uint256 feeBefore = IERC20(IMD).balanceOf(FEE_RECIPIENT);
        pad.collectProtocolFees(IMD);
        assertApproxEqAbs(IERC20(IMD).balanceOf(FEE_RECIPIENT) - feeBefore, 1e18 + (got * 100) / 9600, 1e12);
    }
}
