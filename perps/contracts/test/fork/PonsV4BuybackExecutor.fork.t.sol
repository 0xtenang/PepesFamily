// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PonsV4BuybackExecutor} from "../../src/fees/PonsV4BuybackExecutor.sol";
import {IPonsLaunchFactory} from "../../src/interfaces/IPons.sol";
import {IPoolManager, PoolKey, toPoolId} from "../../src/interfaces/IUniswapV4Minimal.sol";

/// @dev Read-only views of the live PonsV2MemeHook (public getters in the published source).
interface IPonsMemeHookView {
    function launches(bytes32 poolId)
        external
        view
        returns (
            bool registered,
            bool memecoinIsCurrency0,
            address memecoin,
            address quoteToken,
            address creator,
            address buybackCreatorRecipient,
            address protocolFeeRecipient,
            uint16 creatorTaxBps,
            uint16 protocolFeeShareBps,
            uint16 buybackBurnBps,
            uint16 hookFeeBps,
            uint16 maxInternalPriceImpactBps,
            bool buybackEnabled
        );
    function pendingFees(bytes32 poolId, address currency) external view returns (uint256);
    function pendingCreatorTax(bytes32 poolId, address currency) external view returns (uint256);
    function factory() external view returns (address);
    function poolManager() external view returns (address);
}

/// @dev Factory wiring getters (public immutables in the published source).
interface IPonsFactoryWiring {
    function memeHook() external view returns (address);
    function poolManager() external view returns (address);
}

/// @notice PonsV4BuybackExecutor against the live Pons V2 pools on Robinhood Chain (4663).
/// @dev Runs only with FORK_URL set (FORK_BLOCK pins a block, default latest); otherwise every test skips.
///      The tokens below were found on 2026-10-29 from the hook's HookFeeCollected logs, then checked with
///      hook.launches(poolId) and factory.getLaunchedToken (phase PoolCreated, ETH pair, fee 0, tick spacing 200).
contract PonsV4BuybackExecutorForkTest is Test {
    address internal constant FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address internal constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    address internal constant QSTRAT = 0xF05bCf94C8C020E43de8927B491c6BE8B96777E3; // 5% creator tax, like ours
    address internal constant RUNE = 0x437d083c57BB31573Aa383f9602ec5a86519b9d4; // 2% creator tax
    address internal constant OWNERLESS = 0x742Af99ef5e528ee85fB04fF76c44b22eF08611A; // no creator tax
    address internal constant PLTR_PAIRED = 0x3bA500F1AbabbCF0F0247D06D1c56Fd7E6C4c09D; // graduated, quote is an ERC-20

    bytes32 internal constant HOOK_FEE_COLLECTED = keccak256("HookFeeCollected(bytes32,address,uint256,uint256)");
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant ETH_IN = 0.001 ether;

    struct Fee {
        bool found;
        address currency;
        uint256 fee;
        uint256 tax;
    }

    bool internal forked;
    PonsV4BuybackExecutor internal ex;
    IPonsMemeHookView internal hook = IPonsMemeHookView(HOOK);
    address internal sink = makeAddr("sink");

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @dev Robinhood Chain is an Arbitrum Orbit chain: inside the EVM `block.number` is the parent-chain block,
    ///      so the L2 block the fork is pinned to is read over RPC and logged separately. The public drpc endpoint
    ///      only keeps about the last 900 blocks (~100 s) of state, so FORK_BLOCK must be recent there.
    function setUp() public {
        string memory url = vm.envOr("FORK_URL", string(""));
        if (bytes(url).length == 0) return;
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) blk = _toUint(vm.rpc(url, "eth_blockNumber", "[]"));
        vm.createSelectFork(url, blk);
        forked = true;
        console2.log("fork L2 block", blk, "timestamp", block.timestamp);
        console2.log("  (block.number in the EVM, parent chain)", block.number);

        ex = new PonsV4BuybackExecutor(IPoolManager(POOL_MANAGER), IPonsLaunchFactory(FACTORY), HOOK, address(this));
        vm.deal(address(this), 10 ether);
    }

    /// @dev Refunds from the executor land here.
    receive() external payable {}

    // ------------------------------------------------------------------ pool keys

    function test_poolKeyMatchesHookRegistry() public onlyFork {
        assertEq(IPonsFactoryWiring(FACTORY).memeHook(), HOOK, "factory hook");
        assertEq(IPonsFactoryWiring(FACTORY).poolManager(), POOL_MANAGER, "factory pool manager");
        assertEq(hook.factory(), FACTORY, "hook factory");
        assertEq(hook.poolManager(), POOL_MANAGER, "hook pool manager");
        address[3] memory tokens = [QSTRAT, RUNE, OWNERLESS];
        for (uint256 i; i < tokens.length; ++i) {
            address t = tokens[i];
            PoolKey memory key = ex.poolKey(t);
            bytes32 id = toPoolId(key);
            IPonsLaunchFactory.LaunchedToken memory rec = IPonsLaunchFactory(FACTORY).getLaunchedToken(t);
            (bool registered, bool memeIs0, address memecoin, address quote,,,, uint16 taxBps,,, uint16 feeBps,,) =
                hook.launches(id);
            assertTrue(registered, "pool not registered in hook");
            assertFalse(memeIs0, "ETH must be currency0");
            assertEq(memecoin, t);
            assertEq(quote, address(0));
            assertEq(taxBps, rec.creatorTaxBps, "tax snapshot differs from factory");
            assertEq(key.fee, 0);
            assertEq(key.tickSpacing, 200);
            (uint160 sqrtP, uint128 liq) = _pool(id);
            assertGt(sqrtP, 0, "pool not initialized");
            console2.log("token", t);
            console2.logBytes32(id);
            console2.log("  creatorTaxBps", taxBps, "hookFeeBps", feeBps);
            console2.log("  ETH depth (wei)", (uint256(liq) * Q96) / sqrtP);
        }
    }

    function test_poolKeyRejectsUnknownAndNonEthPairs() public onlyFork {
        vm.expectRevert(abi.encodeWithSelector(PonsV4BuybackExecutor.NotGraduated.selector, address(0xBEEF)));
        ex.poolKey(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(PonsV4BuybackExecutor.NotEthPair.selector, PLTR_PAIRED));
        ex.poolKey(PLTR_PAIRED);
    }

    // ------------------------------------------------------------------ exact input (buy)

    function test_buy_QSTRAT_deliversTokensNetOfFeeAndTax() public onlyFork {
        _checkExactIn(QSTRAT);
    }

    function test_buy_RUNE_deliversTokensNetOfFeeAndTax() public onlyFork {
        _checkExactIn(RUNE);
    }

    function test_buy_OWNERLESS_deliversTokensNetOfFee() public onlyFork {
        _checkExactIn(OWNERLESS);
    }

    function test_buy_enforcesMinOut() public onlyFork {
        uint256 snap = vm.snapshotState();
        uint256 out = ex.buy{value: ETH_IN}(QSTRAT, 1, sink);
        vm.revertToState(snap);

        vm.expectRevert(abi.encodeWithSelector(PonsV4BuybackExecutor.InsufficientOutput.selector, out, out + 1));
        ex.buy{value: ETH_IN}(QSTRAT, out + 1, sink);
        assertEq(IERC20(QSTRAT).balanceOf(sink), 0);

        assertEq(ex.buy{value: ETH_IN}(QSTRAT, out, sink), out, "exact minOut must pass");
        assertEq(IERC20(QSTRAT).balanceOf(sink), out);
    }

    function test_buy_guards() public onlyFork {
        vm.deal(address(0xA11CE), 1 ether);
        vm.prank(address(0xA11CE));
        vm.expectRevert(PonsV4BuybackExecutor.NotCaller.selector);
        ex.buy{value: ETH_IN}(QSTRAT, 1, sink);

        vm.expectRevert(PonsV4BuybackExecutor.MinOutRequired.selector);
        ex.buy{value: ETH_IN}(QSTRAT, 0, sink);

        vm.expectRevert(PonsV4BuybackExecutor.ZeroAddress.selector);
        ex.buy{value: ETH_IN}(QSTRAT, 1, address(0));

        vm.expectRevert(PonsV4BuybackExecutor.BadAmount.selector);
        ex.buy(QSTRAT, 1, sink);

        vm.expectRevert(abi.encodeWithSelector(PonsV4BuybackExecutor.NotEthPair.selector, PLTR_PAIRED));
        ex.buy{value: ETH_IN}(PLTR_PAIRED, 1, sink);

        vm.expectRevert(PonsV4BuybackExecutor.NotPoolManager.selector);
        ex.unlockCallback("");

        vm.prank(address(0xA11CE));
        vm.expectRevert(PonsV4BuybackExecutor.NotCaller.selector);
        ex.buyExactOut{value: ETH_IN}(QSTRAT, 1e18, sink);
    }

    // ------------------------------------------------------------------ exact output

    /// @notice Does an exact-output buy make the hook charge in ETH? Compares both modes from the same state.
    function test_exactOut_QSTRAT_hookChargesEth() public onlyFork {
        _compareModes(QSTRAT);
    }

    function test_exactOut_RUNE_hookChargesEth() public onlyFork {
        _compareModes(RUNE);
    }

    function test_exactOut_OWNERLESS_hookChargesEth() public onlyFork {
        _compareModes(OWNERLESS);
    }

    function test_buyExactOut_boundsInput() public onlyFork {
        uint256 amountOut = 300_000 ether; // about 0.001 ETH of QSTRAT
        uint256 snap = vm.snapshotState();
        uint256 spent = ex.buyExactOut{value: 1 ether}(QSTRAT, amountOut, sink);
        vm.revertToState(snap);

        vm.expectRevert(abi.encodeWithSelector(PonsV4BuybackExecutor.ExcessiveInput.selector, spent, spent - 1));
        ex.buyExactOut{value: spent - 1}(QSTRAT, amountOut, sink);

        uint256 bal = address(this).balance;
        assertEq(ex.buyExactOut{value: spent}(QSTRAT, amountOut, sink), spent);
        assertEq(address(this).balance, bal - spent, "exact budget, no refund");
        assertEq(IERC20(QSTRAT).balanceOf(sink), amountOut);
    }

    // ------------------------------------------------------------------ helpers

    function _checkExactIn(address token) internal {
        bytes32 id = toPoolId(ex.poolKey(token));
        (,,,,,,, uint16 taxBps,,, uint16 feeBps,,) = hook.launches(id);
        (uint160 sqrtP0, uint128 liq0) = _pool(id);
        uint256 pendingFee0 = hook.pendingFees(id, token);
        uint256 pendingTax0 = hook.pendingCreatorTax(id, token);
        uint256 bal0 = address(this).balance;

        vm.recordLogs();
        uint256 g = gasleft();
        uint256 out = ex.buy{value: ETH_IN}(token, 1, sink);
        g -= gasleft();
        Fee memory f = _hookFee(vm.getRecordedLogs(), id);

        // Delivery and ETH accounting.
        assertGt(out, 0);
        assertEq(IERC20(token).balanceOf(sink), out, "tokens not at `to`");
        assertEq(IERC20(token).balanceOf(address(ex)), 0, "executor kept tokens");
        assertEq(address(ex).balance, 0, "executor kept ETH");
        assertEq(address(this).balance, bal0 - ETH_IN, "all ETH spent, nothing refunded");

        // The hook charged base fee + creator tax in the token, out of the pool's output.
        assertTrue(f.found, "no HookFeeCollected");
        assertEq(f.currency, token, "exact-in fee should be in the token");
        uint256 gross = out + f.fee + f.tax;
        assertEq(f.fee, (gross * feeBps) / BPS, "base fee");
        assertEq(f.tax, (gross * taxBps) / BPS, "creator tax");
        assertEq(hook.pendingFees(id, token) - pendingFee0, f.fee);
        assertEq(hook.pendingCreatorTax(id, token) - pendingTax0, f.tax);

        // Independent check of the gross output from pool math: with no tick crossed, out = L * dSqrtP / 2^96.
        (uint160 sqrtP1, uint128 liq1) = _pool(id);
        bool exactMath = liq1 == liq0;
        if (exactMath) assertEq(gross, (uint256(liq0) * (sqrtP0 - sqrtP1)) / Q96, "gross != pool math");
        uint256 spotOut = (ETH_IN * (uint256(sqrtP0) * sqrtP0 / Q96)) / Q96;
        assertLe(gross, spotOut);
        assertApproxEqRel(gross, spotOut, 0.005e18, "gross far from spot");

        console2.log("== exact-in", token);
        console2.log("  ETH in", ETH_IN, "gas", g);
        console2.log("  pool output (gross)", gross, exactMath ? "(= L * dSqrtP / 2^96, checked)" : "(tick crossed)");
        console2.log("  hook fee (token)", f.fee, "creator tax (token)", f.tax);
        console2.log("  received", out);
        console2.log("  taken bps of gross x100", ((gross - out) * BPS * 100) / gross, "expected bps", feeBps + taxBps);
        console2.log("  received vs spot-price value, bps", (out * BPS) / spotOut);
    }

    function _compareModes(address token) internal {
        bytes32 id = toPoolId(ex.poolKey(token));
        (,,,,,,, uint16 taxBps,,, uint16 feeBps,,) = hook.launches(id);
        uint256 snap = vm.snapshotState();

        // A: exact input, 0.001 ETH.
        vm.recordLogs();
        uint256 outA = ex.buy{value: ETH_IN}(token, 1, sink);
        Fee memory fa = _hookFee(vm.getRecordedLogs(), id);
        assertEq(fa.currency, token);
        vm.revertToState(snap);

        // B: exact output of the same token amount, with a generous budget.
        uint256 pendingEthFee0 = hook.pendingFees(id, address(0));
        uint256 pendingEthTax0 = hook.pendingCreatorTax(id, address(0));
        uint256 pendingTokFee0 = hook.pendingFees(id, token);
        uint256 bal0 = address(this).balance;
        vm.recordLogs();
        uint256 g = gasleft();
        uint256 ethB = ex.buyExactOut{value: 2 * ETH_IN}(token, outA, sink);
        g -= gasleft();
        Fee memory fb = _hookFee(vm.getRecordedLogs(), id);

        assertEq(IERC20(token).balanceOf(sink), outA, "exact amount out");
        assertEq(address(this).balance, bal0 - ethB, "unspent ETH refunded");
        assertEq(address(ex).balance, 0);
        assertTrue(fb.found, "no HookFeeCollected");
        assertEq(fb.currency, address(0), "exact-out fee should be in ETH");
        uint256 poolIn = ethB - fb.fee - fb.tax; // ETH that went into the pool's own swap
        assertEq(fb.fee, (poolIn * feeBps) / BPS, "base fee on ETH input");
        assertEq(fb.tax, (poolIn * taxBps) / BPS, "creator tax on ETH input");
        assertEq(hook.pendingFees(id, address(0)) - pendingEthFee0, fb.fee);
        assertEq(hook.pendingCreatorTax(id, address(0)) - pendingEthTax0, fb.tax);
        assertEq(hook.pendingFees(id, token), pendingTokFee0, "no token fee on exact-out");
        if (feeBps + taxBps > 0) assertLt(ethB, ETH_IN, "exact-out should cost less for the same tokens");

        console2.log("== exact-in vs exact-out", token);
        console2.log("  tokens bought (both)", outA);
        console2.log("  A exact-in : ETH paid", ETH_IN);
        console2.log("    fee in token", fa.fee, "tax in token", fa.tax);
        console2.log("  B exact-out: ETH paid", ethB, "gas", g);
        console2.log("    ETH into pool", poolIn);
        console2.log("    fee in ETH", fb.fee, "tax in ETH", fb.tax);
        console2.log("  B saves, bps x100", ((ETH_IN - ethB) * BPS * 100) / ETH_IN);
    }

    function _hookFee(Vm.Log[] memory logs, bytes32 id) internal pure returns (Fee memory f) {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter == HOOK && l.topics.length == 2 && l.topics[0] == HOOK_FEE_COLLECTED && l.topics[1] == id) {
                require(!f.found, "two fee events");
                f.found = true;
                (f.currency, f.fee, f.tax) = abi.decode(l.data, (address, uint256, uint256));
            }
        }
    }

    /// @dev vm.rpc returns a JSON quantity as its big-endian bytes.
    function _toUint(bytes memory b) internal pure returns (uint256 v) {
        require(b.length <= 32, "quantity too long");
        for (uint256 i; i < b.length; ++i) {
            v = (v << 8) | uint8(b[i]);
        }
    }

    /// @dev PoolManager storage, as v4-core's StateLibrary reads it (pools mapping at slot 6, liquidity at +3).
    function _pool(bytes32 id) internal view returns (uint160 sqrtP, uint128 liq) {
        bytes32 slot = keccak256(abi.encodePacked(id, POOLS_SLOT));
        sqrtP = uint160(uint256(IPoolManager(POOL_MANAGER).extsload(slot)));
        liq = uint128(uint256(IPoolManager(POOL_MANAGER).extsload(bytes32(uint256(slot) + 3))));
    }
}
