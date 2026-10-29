// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LevPool} from "../../src/LevPool.sol";
import {CreatorFeeRouterV2} from "../../src/fees/CreatorFeeRouterV2.sol";
import {PonsV4BuybackExecutor} from "../../src/fees/PonsV4BuybackExecutor.sol";
import {UniV4SampledOracle, IExtsload} from "../../src/oracles/UniV4SampledOracle.sol";
import {IPonsLaunchFactory, IPonsFeeEscrow} from "../../src/interfaces/IPons.sol";
import {IBuybackExecutor} from "../../src/interfaces/IBuybackExecutor.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {
    BalanceDelta,
    IPoolManager,
    IUnlockCallback,
    MAX_SQRT_PRICE,
    MIN_SQRT_PRICE,
    PoolKey,
    SwapParams,
    toPoolId
} from "../../src/interfaces/IUniswapV4Minimal.sol";

// =====================================================================================================================
// The parts of the live Pons V2 contracts this test drives, beyond src/interfaces/IPons.sol. Every selector was found
// in the deployed bytecode on 2026-10-29; the struct layouts follow the published source.
// =====================================================================================================================

struct PonsSocials {
    string twitter;
    string telegram;
    string discord;
    string website;
    string farcaster;
}

struct PonsTokenParams {
    string name;
    string symbol;
    string logo;
    string description;
    PonsSocials socials;
    address creatorFeeRecipient;
    uint16 creatorTaxBps;
    bool buybackEnabled;
    bytes32 expectedEconomics;
    bytes32 salt;
}

struct PonsFeePolicy {
    address protocolFeeRecipient;
    uint16 protocolFeeShareBps;
    uint16 buybackBurnBps;
    uint16 hookFeeBps;
    uint16 maxInternalPriceImpactBps;
}

struct PonsLaunchConfig {
    uint256 supply;
    uint256 curveFeeBps;
    uint256 phantomQuote;
    uint256 graduationThreshold;
    uint24 poolFee;
    int24 tickSpacing;
    bool enabled;
}

interface IPonsFactoryFull {
    function owner() external view returns (address);
    function launchEnabled() external view returns (bool);
    function launchFee() external view returns (uint256);
    function canLaunch(address launcher) external view returns (bool);
    function setLaunchEnabled(bool enabled) external;
    function setWhitelistedLauncher(address launcher, bool enabled) external;
    function getLaunchConfig(uint256 id) external view returns (PonsLaunchConfig memory);
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32);
    function launchToken(
        PonsTokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve);
    function getLaunchFeePolicy(address token) external view returns (PonsFeePolicy memory);
    function graduate(address token) external;
    function createGraduatedPool(address token) external returns (uint256 positionId);
}

interface IPonsCurveFull {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256);
    function sweepFees(uint256 minBuybackTokensOut) external;
    function deployer() external view returns (address);
    function feeBps() external view returns (uint256);
    function creatorTaxBps() external view returns (uint256);
    function protocolFeeShareBps() external view returns (uint16);
    function quoteFeeBalance() external view returns (uint256);
    function creatorTaxBalance() external view returns (uint256);
    function buybackQuoteBalance() external view returns (uint256);
    function trackedQuote() external view returns (uint256);
    function sellableTokens() external view returns (uint256);
    function graduated() external view returns (bool);
    function buybackEnabled() external view returns (bool);
    function snipeTaxExempt(address account) external view returns (bool);
    function snipeTaxStartBps() external view returns (uint256);
    function snipeTaxSeconds() external view returns (uint256);
    function launchedAt() external view returns (uint256);
}

interface IPonsHookFull {
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
    function feeSweepOperator() external view returns (address);
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}

interface IPonsEscrowFull {
    function credit(address recipient) external payable;
    function claim() external returns (uint256);
    function balanceOf(address recipient) external view returns (uint256);
}

// =====================================================================================================================
// Test helpers
// =====================================================================================================================

/// @notice Claims from the escrow and logs how much gas its receive() got, to tell a 2300-gas transfer from a call.
contract EscrowProbe {
    event Paid(address from, uint256 value, uint256 gasLeft);

    IPonsEscrowFull internal immutable escrow;

    constructor(IPonsEscrowFull escrow_) {
        escrow = escrow_;
    }

    function claim() external returns (uint256) {
        return escrow.claim();
    }

    receive() external payable {
        emit Paid(msg.sender, msg.value, gasleft());
    }
}

/// @notice A recipient whose receive() needs more than 2300 gas (a fresh storage write).
contract HeavyReceiver {
    IPonsEscrowFull internal immutable escrow;
    uint256 public received;

    constructor(IPonsEscrowFull escrow_) {
        escrow = escrow_;
    }

    function claim() external returns (uint256) {
        return escrow.claim();
    }

    receive() external payable {
        received += msg.value;
    }
}

/// @notice Minimal Uniswap V4 swapper for test traders: exact input or exact output, either direction, on one pool.
contract V4Swapper is IUnlockCallback {
    struct Call {
        address user;
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
    }

    IPoolManager internal immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    /// @dev Send ETH for an ETH-in swap; what is not spent comes back. Approve this contract for a token-in swap.
    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        external
        payable
        returns (int128 d0, int128 d1)
    {
        (d0, d1) = abi.decode(
            pm.unlock(abi.encode(Call(msg.sender, key, zeroForOne, amountSpecified))), (int128, int128)
        );
        uint256 left = address(this).balance;
        if (left != 0) {
            (bool ok,) = msg.sender.call{value: left}("");
            require(ok, "refund failed");
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pool manager");
        Call memory c = abi.decode(data, (Call));
        BalanceDelta d = pm.swap(
            c.key,
            SwapParams({
                zeroForOne: c.zeroForOne,
                amountSpecified: c.amountSpecified,
                sqrtPriceLimitX96: c.zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 d0 = d.amount0();
        int128 d1 = d.amount1();
        if (d0 < 0) {
            pm.sync(address(0));
            pm.settle{value: uint256(uint128(-d0))}();
        }
        if (d1 < 0) {
            pm.sync(c.key.currency1);
            require(IERC20(c.key.currency1).transferFrom(c.user, address(pm), uint256(uint128(-d1))), "pay");
            pm.settle();
        }
        if (d0 > 0) pm.take(address(0), c.user, uint256(uint128(d0)));
        if (d1 > 0) pm.take(c.key.currency1, c.user, uint256(uint128(d1)));
        return abi.encode(d0, d1);
    }

    receive() external payable {}
}

// =====================================================================================================================

/// @notice End-to-end proof of the platform-token fee path on a Robinhood Chain (4663) mainnet fork: our own LevPool and
///         CreatorFeeRouterV2, a real Pons V2 launch (5% creator tax, router as recipient, Pons buybacks off, no
///         snipe-tax exemptions), curve trading, sweeps, the router's harvest into LevPool, graduation to the V4 pool,
///         the hook sweep, and a buyback through PonsV4BuybackExecutor priced by a UniV4SampledOracle on the new pool.
/// @dev Runs only with FORK_URL set (FORK_BLOCK pins a block, default latest); otherwise every test skips. The public
///      drpc endpoint keeps only about the last 900 blocks (~100 s) of state, so FORK_BLOCK must be recent there.
///      Pons roles are impersonated: the factory owner (to whitelist our launcher) and the hook's fee-sweep operator
///      (for sweeps that need an internal swap).
contract PonsLaunchFlowForkTest is Test {
    address internal constant FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address internal constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address internal constant ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant SEED = 0.001 ether;
    uint16 internal constant TAX_BPS = 500;
    uint256 internal constant LAUNCH_CONFIG = 0;

    bool internal forked;

    IPonsFactoryFull internal factory = IPonsFactoryFull(FACTORY);
    IPonsHookFull internal hook = IPonsHookFull(HOOK);
    IPonsEscrowFull internal escrow = IPonsEscrowFull(ESCROW);

    LevPool internal pool;
    CreatorFeeRouterV2 internal router;
    address internal token;
    IPonsCurveFull internal curve;
    address internal factoryOwner;
    bool internal gateWasOpen;

    address internal owner = makeAddr("multisig");
    address internal treasury = makeAddr("treasury");
    address internal launcher = makeAddr("launcher");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal whale = makeAddr("whale");
    address internal keeper = makeAddr("keeper");

    // Quote-leg volume traded, measured from the traders' side (curve) or the PoolManager's ETH balance (V4).
    uint256 internal curveVolume;
    uint256 internal v4Volume;
    uint256 internal curveTrades;

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
        if (blk == 0) blk = _toUint(vm.rpc(url, "eth_blockNumber", "[]"));
        vm.createSelectFork(url, blk);
        forked = true;
        console2.log("fork L2 block", blk, "timestamp", block.timestamp);

        vm.deal(address(this), 1 ether);
        pool = new LevPool{value: SEED}(owner);
        router = new CreatorFeeRouterV2(
            pool,
            IPonsLaunchFactory(FACTORY),
            IPonsFeeEscrow(ESCROW),
            HOOK,
            4000,
            treasury,
            address(0), // no distributor: bought tokens are burned
            0,
            owner
        );
        _launch();
        vm.prank(owner);
        router.setToken(token);

        address[6] memory traders = [alice, bob, carol, dave, whale, keeper];
        for (uint256 i; i < traders.length; ++i) {
            vm.deal(traders[i], 20 ether);
        }
    }

    // ================================================================== the whole path

    /// @notice Launch -> curve trading -> sweeps -> harvest into LevPool -> graduation -> V4 trading -> hook sweeps ->
    ///         buyback into the burn address.
    function test_launchFlow_curveThenV4_endToEnd() public onlyFork {
        _checkLaunchRecord();
        assertEq(router.curve(), address(curve), "router curve");
        assertEq(router.currentFeeRecipient(), address(router), "recipient");

        // Past the launch-window snipe tax (at most 60 s by the factory's own cap).
        _skip(61);

        // ---- 1. curve trading from a few wallets
        _curveBuy(alice, 0.5 ether);
        _curveBuy(bob, 0.3 ether);
        _curveSell(alice, IERC20(token).balanceOf(alice) / 3);
        _curveBuy(carol, 0.2 ether);
        _curveSell(bob, IERC20(token).balanceOf(bob) / 2);

        // The launch's deployer is not the curve's fee recipient, so it cannot sweep; only the recipient (the
        // router) and the Pons operator can.
        vm.prank(launcher);
        vm.expectRevert(bytes4(keccak256("NotFeeSweepOperator()")));
        curve.sweepFees(0);

        // ---- 2. sweep by the Pons operator, then our harvest claims it
        uint256 owed = _curveCreatorShare();
        vm.prank(hook.feeSweepOperator());
        curve.sweepFees(0);
        assertEq(escrow.balanceOf(address(router)), owed, "escrow credited to router");
        assertEq(address(router).balance, 0);
        uint256 vol1 = curveVolume;
        uint256 c1 = _harvest(owed, "harvest 1 (operator swept)");
        console2.log("  curve volume so far", vol1, "claimed bps of volume x100", (c1 * BPS * 100) / vol1);

        // ---- 3. more trading, then the router sweeps the curve itself inside harvest
        _curveBuy(dave, 0.4 ether);
        _curveSell(carol, IERC20(token).balanceOf(carol));
        _curveBuy(alice, 0.25 ether);
        owed = _curveCreatorShare();
        vm.expectCall(address(curve), abi.encodeCall(IPonsCurveFull.sweepFees, (0)));
        uint256 c2 = _harvest(owed, "harvest 2 (router swept the curve)");
        assertEq(curve.quoteFeeBalance(), 0, "curve fees left");
        assertEq(curve.creatorTaxBalance(), 0, "curve tax left");

        (uint256 claimed,,,,,,,,) = router.totals();
        assertEq(claimed, c1 + c2);
        _logShare("curve phase", claimed, curveVolume);
        // 5% tax + 70% of the 1% base fee = 5.70% of volume, less floor rounding per trade and per sweep.
        assertApproxEqAbs((claimed * 1e6) / curveVolume, 57_000, 2, "creator share of curve volume");
        _checkPoolBooks();

        // ---- 4. buy out the curve: graduation sweeps once more, then the V4 pool is created
        uint256 sellable = curve.sellableTokens();
        console2.log("sellable tokens before graduation", sellable);
        _curveBuy(whale, 10 ether); // clamped to what is left, the rest refunded
        _graduate();
        assertEq(curve.sellableTokens(), 0);
        owed = escrow.balanceOf(address(router));
        assertGt(owed, 0, "graduation sweep paid nothing");
        assertApproxEqAbs((owed * 1e6) / (curveVolume - _volumeBeforeWhale), 57_000, 2, "graduation sweep share");
        _harvest(owed, "harvest 3 (graduation sweep)");
        (claimed,,,,,,,,) = router.totals();
        _logShare("whole curve", claimed, curveVolume);

        // ---- 5. the V4 pool: router's pool id matches the hook's registry
        PonsV4BuybackExecutor ex =
            new PonsV4BuybackExecutor(IPoolManager(POOL_MANAGER), IPonsLaunchFactory(FACTORY), HOOK, address(router));
        PoolKey memory key = ex.poolKey(token);
        bytes32 id = toPoolId(key);
        assertEq(router.poolId(), id, "router pool id");
        _checkHookRecord(id);

        // ---- 6. V4 trades that pay the hook in ETH (exact-in sells, exact-out buys): the router can sweep them
        V4Swapper sw = new V4Swapper(IPoolManager(POOL_MANAGER));
        _v4Sell(sw, key, alice, IERC20(token).balanceOf(alice) / 10);
        _v4Sell(sw, key, whale, IERC20(token).balanceOf(whale) / 50);
        _v4BuyExactOut(sw, key, carol, IERC20(token).balanceOf(whale) / 100);
        _v4Sell(sw, key, dave, IERC20(token).balanceOf(dave) / 4);
        assertEq(hook.pendingFees(id, token), 0, "no token-denominated fees yet");
        uint256 hookOwed = _hookCreatorShare(id);
        vm.expectCall(HOOK, abi.encodeCall(IPonsHookFull.sweepPoolFees, (id, 0, 0)));
        uint256 c4 = _harvest(hookOwed, "harvest 4 (router swept the V4 hook)");
        _logShare("V4 phase (ETH-side fees)", c4, v4Volume);
        assertApproxEqAbs((c4 * 1e6) / v4Volume, 57_000, 2, "creator share of V4 volume");

        // ---- 7. an exact-in buy pays the hook in our token: the router's own sweep is refused, the operator's works
        uint256 ethIn = 0.05 ether;
        _v4BuyExactIn(sw, key, bob, ethIn);
        uint256 tokFee = hook.pendingFees(id, token) + hook.pendingCreatorTax(id, token);
        assertGt(tokFee, 0, "exact-in buy should leave token fees");
        assertEq(router.harvest(), 0, "router cannot convert token fees");
        assertEq(hook.pendingFees(id, token) + hook.pendingCreatorTax(id, token), tokFee, "fees untouched");
        vm.prank(hook.feeSweepOperator());
        hook.sweepPoolFees(id, 1, 0);
        owed = escrow.balanceOf(address(router));
        assertGt(owed, 0, "operator sweep credited nothing");
        _harvest(owed, "harvest 5 (operator converted token fees)");
        console2.log("  token fees converted back to ETH; creator got bps of the buy x100", (owed * BPS * 100) / ethIn);

        // ---- 8. buyback through the executor, priced by a sampled oracle on the new pool
        _buyback(ex, id);

        // ---- 9. final books
        _checkPoolBooks();
        _logTotals();
    }

    // ================================================================== focused checks

    /// @notice How the real FeeEscrow pays a contract: gas given to receive(), heavy receivers, and empty claims.
    function test_escrowPaysContractRecipients() public onlyFork {
        EscrowProbe probe = new EscrowProbe(escrow);
        escrow.credit{value: 0.01 ether}(address(probe));
        assertEq(escrow.balanceOf(address(probe)), 0.01 ether, "credit is permissionless");

        vm.recordLogs();
        uint256 got = probe.claim();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 gasLeft;
        bool paid;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(probe) && logs[i].topics[0] == EscrowProbe.Paid.selector) {
                (address from, uint256 value, uint256 g) = abi.decode(logs[i].data, (address, uint256, uint256));
                assertEq(from, ESCROW);
                assertEq(value, 0.01 ether);
                gasLeft = g;
                paid = true;
            }
        }
        assertTrue(paid, "probe was not paid");
        assertEq(got, 0.01 ether, "claim() returns the amount");
        assertEq(address(probe).balance, 0.01 ether);
        assertEq(escrow.balanceOf(address(probe)), 0);
        console2.log("escrow claim(): receive() of a contract got gas", gasLeft);
        console2.log(gasLeft < 2300 ? "  => paid with a 2300-gas transfer/send" : "  => paid with a call forwarding gas");

        // A recipient that needs a storage write in receive().
        HeavyReceiver heavy = new HeavyReceiver(escrow);
        escrow.credit{value: 0.002 ether}(address(heavy));
        (bool ok,) = address(heavy).call(abi.encodeCall(HeavyReceiver.claim, ()));
        console2.log("  heavy receiver (SSTORE in receive) can claim:", ok);
        if (gasLeft >= 2300) assertTrue(ok, "a call-paying escrow must pay a heavy receiver");

        // Claiming with nothing owed.
        (ok,) = address(probe).call(abi.encodeCall(EscrowProbe.claim, ()));
        console2.log("  claim() with a zero balance succeeds:", ok);
    }

    /// @notice The router moves the Pons fee stream after its 7-day timelock, collecting what it is owed first.
    function test_feeRecipientMove_collectsFirstThenTransfers() public onlyFork {
        _skip(61);
        _curveBuy(alice, 0.3 ether);
        address next = makeAddr("nextRecipient");
        vm.prank(owner);
        router.proposeFeeRecipient(next);
        _skip(7 days);
        _curveBuy(bob, 0.2 ether);
        _curveSell(alice, IERC20(token).balanceOf(alice) / 2);
        uint256 owed = _curveCreatorShare();

        vm.expectEmit(true, true, true, false, FACTORY);
        emit IPonsFactoryEvents.CreatorFeeRecipientUpdated(token, address(router), next);
        vm.prank(owner);
        router.executeFeeRecipient();

        IPonsLaunchFactory.LaunchedToken memory lt = IPonsLaunchFactory(FACTORY).getLaunchedToken(token);
        assertEq(lt.creatorFeeRecipient, next, "factory record");
        assertEq(curve.deployer(), next, "curve recipient");
        assertEq(router.currentFeeRecipient(), next);
        (uint256 claimed,,,,,,,,) = router.totals();
        assertEq(claimed, owed, "router collected before moving");
        assertEq(router.unallocated(), owed, "collected ETH waits for allocate");

        // New fees now belong to the new recipient, and the router can no longer sweep.
        _curveBuy(carol, 0.2 ether);
        uint256 nextOwed = _curveCreatorShare();
        assertEq(router.harvest(), 0, "router has nothing to claim");
        vm.prank(next);
        curve.sweepFees(0);
        assertEq(escrow.balanceOf(next), nextOwed, "new recipient credited");
        console2.log("fee stream moved; router collected", owed, "before the move");
    }

    /// @notice Who keeps the launch-window snipe tax? Compares a non-exempt buy in the launch second with an exempt one.
    /// @dev The published curve source has no snipe tax, but the deployed curve has `exemptFromSnipeTax`,
    ///      `snipeTaxExempt`, `snipeTaxStartBps`, `snipeTaxSeconds` and `launchedAt`: the bytecode differs from it.
    function test_snipeTax_whereItGoes() public onlyFork {
        console2.log("snipe tax start bps", curve.snipeTaxStartBps(), "seconds", curve.snipeTaxSeconds());
        console2.log("launchedAt", curve.launchedAt(), "now", vm.getBlockTimestamp());
        assertTrue(curve.snipeTaxExempt(launcher), "launcher exempt");
        assertTrue(curve.snipeTaxExempt(address(router)), "recipient exempt");
        assertFalse(curve.snipeTaxExempt(alice), "no other exemptions");

        uint256 eth = 0.1 ether;
        uint256 snap = vm.snapshotState();
        vm.deal(launcher, eth);
        vm.prank(launcher);
        uint256 exemptOut = curve.buy{value: eth}(eth, 1, launcher);
        vm.revertToState(snap);

        (uint256 fee0, uint256 tax0, uint256 tq0) = (curve.quoteFeeBalance(), curve.creatorTaxBalance(), curve.trackedQuote());
        uint256 bal0 = alice.balance;
        vm.startStateDiffRecording();
        vm.prank(alice);
        uint256 snipedOut = curve.buy{value: eth}(eth, 1, alice);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        uint256 spent = bal0 - alice.balance;
        uint256 dFee = curve.quoteFeeBalance() - fee0;
        uint256 dTax = curve.creatorTaxBalance() - tax0;
        uint256 dTracked = curve.trackedQuote() - tq0;

        console2.log("same-second buy of", eth);
        console2.log("  exempt tokens out", exemptOut, "sniper tokens out", snipedOut);
        console2.log("  sniper paid", spent, "refunded", eth - spent);
        console2.log("  curve fee balance +", dFee, "creator tax balance +", dTax);
        console2.log("  curve tracked quote +", dTracked);
        for (uint256 i; i < acc.length; ++i) {
            if (acc[i].value != 0 && acc[i].accessor != alice) {
                console2.log("  ETH moved", acc[i].accessor, "->", acc[i].account);
                console2.log("    amount", acc[i].value);
            }
        }
        console2.log("  router escrow balance", escrow.balanceOf(address(router)));
        assertLt(snipedOut, exemptOut, "snipe tax did not apply");

        // The sweep splits the base-fee bucket (snipe tax included) 30/70 between Pons and the creator.
        uint256 owed = _curveCreatorShare();
        uint256 protocolCut = curve.quoteFeeBalance() - (owed - curve.creatorTaxBalance());
        uint256 c = router.harvest();
        assertEq(c, owed, "router claimed its share of the snipe tax");
        console2.log("  router claimed", c, "Pons kept", protocolCut);
        console2.log("  router's share of the sniper's ETH, bps", (c * BPS) / spent);
        console2.log("  creator tax as bps of the buy", (dTax * BPS) / spent, "base fee bps", (dFee * BPS) / spent);
    }

    // ================================================================== launch

    uint256 internal _volumeBeforeWhale;

    /// @dev Launches from a fresh launcher with the founder's parameters. The public gate is closed first (it was open
    ///      on 2026-10-29) so the launch goes through the whitelist, as it must whenever Pons closes the gate.
    function _launch() internal {
        factoryOwner = factory.owner();
        gateWasOpen = factory.launchEnabled();
        vm.startPrank(factoryOwner);
        if (gateWasOpen) factory.setLaunchEnabled(false);
        factory.setWhitelistedLauncher(launcher, true);
        vm.stopPrank();
        assertTrue(factory.canLaunch(launcher), "launcher whitelisted");
        assertFalse(factory.canLaunch(alice), "gate closed");

        PonsTokenParams memory p = PonsTokenParams({
            name: "MemeLev Fork Test",
            symbol: "MLEVX",
            logo: "",
            description: "fork test of the MemeLev platform token launch",
            socials: PonsSocials("", "", "", "", ""),
            creatorFeeRecipient: address(router),
            creatorTaxBps: TAX_BPS,
            buybackEnabled: false,
            expectedEconomics: factory.previewLaunchEconomics(LAUNCH_CONFIG, address(0)),
            salt: keccak256("memelev-fork-test")
        });
        uint256 fee = factory.launchFee();
        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("NotWhitelisted()")));
        factory.launchToken{value: fee}(p, LAUNCH_CONFIG, address(0), new address[](0));

        vm.deal(launcher, fee);
        vm.prank(launcher);
        (address t, address c) = factory.launchToken{value: fee}(p, LAUNCH_CONFIG, address(0), new address[](0));
        token = t;
        curve = IPonsCurveFull(c);
        assertEq(launcher.balance, 0, "launch fee");
        console2.log("launched", t, "curve", c);
        console2.log("  public gate was open:", gateWasOpen, "launch fee", fee);
    }

    function _checkLaunchRecord() internal view {
        IPonsLaunchFactory.LaunchedToken memory lt = IPonsLaunchFactory(FACTORY).getLaunchedToken(token);
        PonsLaunchConfig memory cfg = factory.getLaunchConfig(LAUNCH_CONFIG);
        assertTrue(lt.exists);
        assertEq(lt.token, token);
        assertEq(lt.curve, address(curve));
        assertEq(lt.deployer, launcher);
        assertEq(lt.creatorFeeRecipient, address(router));
        assertEq(lt.pairToken, address(0), "native ETH pair");
        assertEq(lt.creatorTaxBps, TAX_BPS, "creator tax");
        assertFalse(lt.buybackEnabled, "Pons buyback off");
        assertEq(uint256(lt.phase), uint256(IPonsLaunchFactory.GraduationPhase.NotGraduated));
        assertEq(lt.poolFee, cfg.poolFee);
        assertEq(lt.tickSpacing, cfg.tickSpacing);
        assertEq(lt.graduationThreshold, cfg.graduationThreshold);

        // The fee terms the launch snapshotted, and the curve's own copy of them.
        PonsFeePolicy memory pol = factory.getLaunchFeePolicy(token);
        assertEq(pol.protocolFeeShareBps, 3000, "protocol share of the base fee");
        assertEq(pol.hookFeeBps, 100, "V4 base fee");
        assertEq(curve.feeBps(), cfg.curveFeeBps);
        assertEq(curve.feeBps(), 100, "curve base fee");
        assertEq(curve.creatorTaxBps(), TAX_BPS, "curve creator tax");
        assertEq(curve.protocolFeeShareBps(), pol.protocolFeeShareBps);
        assertEq(curve.deployer(), address(router), "curve pays creator fees to the router");
        assertFalse(curve.buybackEnabled());
        assertTrue(curve.snipeTaxExempt(launcher));
        assertTrue(curve.snipeTaxExempt(address(router)));
        assertFalse(curve.snipeTaxExempt(alice), "empty exemption list");

        console2.log("launch record: tax bps", lt.creatorTaxBps, "threshold", lt.graduationThreshold);
        console2.log("  poolFee", lt.poolFee, "curve fee bps", curve.feeBps());
        console2.log("  fee policy: protocol share bps", pol.protocolFeeShareBps, "hook fee bps", pol.hookFeeBps);
        console2.log("  protocol fee recipient", pol.protocolFeeRecipient);
    }

    // ================================================================== curve trading

    function _curveBuy(address who, uint256 eth) internal returns (uint256 out) {
        (uint256 fee0, uint256 tax0) = (curve.quoteFeeBalance(), curve.creatorTaxBalance());
        uint256 bal0 = who.balance;
        vm.prank(who);
        out = curve.buy{value: eth}(eth, 1, who);
        uint256 spent = bal0 - who.balance;
        uint256 fee = curve.quoteFeeBalance() - fee0;
        uint256 tax = curve.creatorTaxBalance() - tax0;
        // A graduating buy also sweeps, which zeroes the balances: then the deltas can't be read here.
        if (!curve.graduated()) {
            assertEq(fee, (spent * 100) / BPS, "buy: base fee");
            assertEq(tax, (spent * TAX_BPS) / BPS, "buy: creator tax");
        }
        assertGe(IERC20(token).balanceOf(who), out);
        if (who == whale) _volumeBeforeWhale = curveVolume;
        curveVolume += spent;
        ++curveTrades;
    }

    function _curveSell(address who, uint256 tokens) internal returns (uint256 out) {
        (uint256 fee0, uint256 tax0) = (curve.quoteFeeBalance(), curve.creatorTaxBalance());
        uint256 bal0 = who.balance;
        vm.startPrank(who);
        IERC20(token).approve(address(curve), tokens);
        out = curve.sell(tokens, 1, who);
        vm.stopPrank();
        assertEq(who.balance - bal0, out, "sell: paid");
        uint256 fee = curve.quoteFeeBalance() - fee0;
        uint256 tax = curve.creatorTaxBalance() - tax0;
        uint256 gross = out + fee + tax;
        assertEq(fee, (gross * 100) / BPS, "sell: base fee");
        assertEq(tax, (gross * TAX_BPS) / BPS, "sell: creator tax");
        curveVolume += gross;
        ++curveTrades;
    }

    /// @dev What a sweep of the curve owes the creator right now: 70% of the base fee plus all the tax.
    function _curveCreatorShare() internal view returns (uint256) {
        uint256 fee = curve.quoteFeeBalance();
        return fee - (fee * curve.protocolFeeShareBps()) / BPS + curve.creatorTaxBalance();
    }

    function _graduate() internal {
        IPonsLaunchFactory.LaunchedToken memory lt = IPonsLaunchFactory(FACTORY).getLaunchedToken(token);
        if (lt.phase == IPonsLaunchFactory.GraduationPhase.NotGraduated) {
            console2.log("auto-graduation did not run; calling graduate()");
            factory.graduate(token);
        }
        lt = IPonsLaunchFactory(FACTORY).getLaunchedToken(token);
        if (lt.phase == IPonsLaunchFactory.GraduationPhase.Swept) {
            console2.log("curve swept at graduation: quote", lt.sweptQuote, "tokens", lt.sweptTokens);
            factory.createGraduatedPool(token);
        }
        lt = IPonsLaunchFactory(FACTORY).getLaunchedToken(token);
        assertEq(uint256(lt.phase), uint256(IPonsLaunchFactory.GraduationPhase.PoolCreated), "pool created");
        assertTrue(curve.graduated());
    }

    // ================================================================== V4 trading

    function _checkHookRecord(bytes32 id) internal view {
        (
            bool registered,
            bool memeIs0,
            address memecoin,
            address quote,
            address creator,
            ,
            ,
            uint16 taxBps,
            uint16 shareBps,
            ,
            uint16 feeBps,
            ,
            bool buybackOn
        ) = hook.launches(id);
        assertTrue(registered, "hook registered");
        assertFalse(memeIs0, "ETH is currency0");
        assertEq(memecoin, token);
        assertEq(quote, address(0));
        assertEq(creator, address(router), "hook pays the router");
        assertEq(taxBps, TAX_BPS, "hook creator tax");
        assertEq(shareBps, 3000);
        assertEq(feeBps, 100, "hook base fee");
        assertFalse(buybackOn);
        (uint160 sqrtP, uint128 liq) = _pool(id);
        console2.log("V4 pool id:");
        console2.logBytes32(id);
        console2.log("  ETH depth (wei)", (uint256(liq) * 2 ** 96) / sqrtP);
    }

    function _v4Sell(V4Swapper sw, PoolKey memory key, address who, uint256 tokens) internal {
        uint256 pm0 = POOL_MANAGER.balance;
        uint256 bal0 = who.balance;
        vm.startPrank(who);
        IERC20(token).approve(address(sw), tokens);
        (int128 d0, int128 d1) = sw.swap(key, false, -int256(tokens));
        vm.stopPrank();
        assertEq(uint256(uint128(-d1)), tokens);
        assertEq(who.balance - bal0, uint256(uint128(d0)));
        uint256 poolOut = pm0 - POOL_MANAGER.balance; // ETH the pool paid out: the trader's share plus the hook's cut
        v4Volume += poolOut;
        assertApproxEqAbs(poolOut - uint256(uint128(d0)), (poolOut * 600) / BPS, 2, "sell: 6% taken in ETH");
    }

    function _v4BuyExactOut(V4Swapper sw, PoolKey memory key, address who, uint256 tokens) internal {
        uint256 pm0 = POOL_MANAGER.balance;
        uint256 bal0 = who.balance;
        vm.prank(who);
        (int128 d0,) = sw.swap{value: 1 ether}(key, true, int256(tokens));
        assertEq(bal0 - who.balance, uint256(uint128(-d0)));
        uint256 poolIn = POOL_MANAGER.balance - pm0; // ETH that stayed in the pool: the trader paid this plus 6%
        v4Volume += poolIn;
        assertApproxEqAbs(uint256(uint128(-d0)) - poolIn, (poolIn * 600) / BPS, 2, "exact-out buy: 6% on top in ETH");
    }

    function _v4BuyExactIn(V4Swapper sw, PoolKey memory key, address who, uint256 eth) internal {
        vm.prank(who);
        sw.swap{value: eth}(key, true, -int256(eth));
    }

    function _hookCreatorShare(bytes32 id) internal view returns (uint256) {
        uint256 fee = hook.pendingFees(id, address(0));
        return fee - (fee * 3000) / BPS + hook.pendingCreatorTax(id, address(0));
    }

    // ================================================================== router

    /// @dev Harvests and checks the claim and the 80/10/10 split of it, landing in LevPool as house shares.
    function _harvest(uint256 expected, string memory label) internal returns (uint256 claimed) {
        assertEq(router.unallocated(), 0);
        uint256 cash0 = pool.cash();
        uint256 dead0 = pool.balanceOf(DEAD);
        uint256 bb0 = router.buybackBalance();
        uint256 ops0 = router.opsBalance();
        vm.expectCall(ESCROW, abi.encodeCall(IPonsEscrowFull.claim, ()));
        uint256 g = gasleft();
        claimed = router.harvest();
        g -= gasleft();
        assertEq(claimed, expected, label);
        assertEq(escrow.balanceOf(address(router)), 0, "escrow balance left");
        uint256 toB = (claimed * 1000) / BPS;
        uint256 toO = (claimed * 1000) / BPS;
        uint256 toP = claimed - toB - toO;
        assertEq(router.buybackBalance() - bb0, toB, "buyback bucket");
        assertEq(router.opsBalance() - ops0, toO, "ops bucket");
        assertEq(pool.cash() - cash0, toP, "donated to LevPool");
        // No LP has joined, so each donation mints house shares to DEAD at the current price (1:1 from the seed).
        assertEq(pool.balanceOf(DEAD) - dead0, toP, "house shares");
        assertEq(pool.totalSupply(), pool.balanceOf(DEAD), "only house shares");
        assertEq(router.unallocated(), 0);
        assertEq(address(router).balance, router.buybackBalance() + router.opsBalance(), "router books");
        console2.log(label, "gas", g);
        console2.log("  claimed", claimed, "to LevPool", toP);
        console2.log("  to buyback", toB, "to ops", toO);
    }

    function _checkPoolBooks() internal view {
        (,, uint256 donated, uint256 toBuyback, uint256 toOps,,,,) = router.totals();
        assertEq(pool.cash(), SEED + donated, "pool cash");
        assertEq(pool.totalDonated(), donated);
        assertEq(pool.totalSupply(), pool.cash(), "share price still 1:1");
        assertEq(pool.balanceOf(DEAD), pool.totalSupply());
        assertApproxEqAbs((donated * BPS) / (donated + toBuyback + toOps), 8000, 1, "80% to the pool");
    }

    /// @dev Sampled oracle on the graduated pool, the buyback route through the 7-day timelock, then one buyback
    ///      sized and quoted the way the keeper does it.
    function _buyback(PonsV4BuybackExecutor ex, bytes32 id) internal {
        UniV4SampledOracle oracle =
            new UniV4SampledOracle(IExtsload(POOL_MANAGER), id, true, 90, 1800, 30, 60, owner);
        vm.prank(owner);
        oracle.setKeeper(keeper, true);
        vm.prank(owner);
        router.proposeBuybackRoute(IBuybackExecutor(address(ex)), IPriceOracle(address(oracle)));
        _skip(7 days);
        for (uint256 i; i < 62; ++i) {
            vm.prank(keeper);
            oracle.poke();
            _skip(30);
        }
        vm.prank(owner);
        router.executeBuybackRoute();

        (int24 spot, int24 fast, int24 slow, uint256 liq) = oracle.read();
        uint256 cap = router.buybackCap();
        uint256 ethIn = cap;
        uint256 floor = router.floorOut(ethIn);
        assertGt(ethIn, 0);
        console2.log("buyback: bucket", router.buybackBalance(), "cap", cap);
        console2.log("  oracle depth (wei)", liq, "floor out", floor);
        console2.logInt(spot);
        console2.logInt(fast);
        console2.logInt(slow);

        // Keeper-style quote: simulate with minOut 0, then require 99.5% of it.
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        uint256 quote = router.buyback(ethIn, 0);
        vm.revertToState(snap);
        uint256 minOut = (quote * 995) / 1000;

        uint256 burn0 = IERC20(token).balanceOf(DEAD);
        uint256 bb0 = router.buybackBalance();
        vm.prank(keeper);
        uint256 g = gasleft();
        uint256 out = router.buyback(ethIn, minOut);
        g -= gasleft();
        assertEq(out, quote, "same state, same output");
        assertGe(out, floor, "router floor");
        assertEq(IERC20(token).balanceOf(DEAD) - burn0, out, "tokens reached the burn address");
        assertEq(router.sink(), DEAD);
        assertEq(bb0 - router.buybackBalance(), ethIn, "bucket spent");
        assertEq(IERC20(token).balanceOf(address(ex)), 0);
        assertEq(address(ex).balance, 0);
        (,,,,, uint256 buybackEth, uint256 tokensToSink,,) = router.totals();
        assertEq(buybackEth, ethIn);
        assertEq(tokensToSink, out);
        // Exact input pays the 6% in tokens, plus price impact under 1% of depth.
        uint256 fair = (floor * BPS) / (BPS - router.feeAndSlipBps());
        console2.log("  bought", out, "for", ethIn);
        console2.log("  buyback gas", g);
        console2.log("  vs oracle fair value, bps", (out * BPS) / fair);

        // Spacing guard: a second buy right away is refused.
        vm.prank(keeper);
        vm.expectRevert();
        router.buyback(1, 0);
    }

    // ================================================================== logs and utils

    function _logShare(string memory label, uint256 claimed, uint256 volume) internal pure {
        console2.log(label);
        console2.log("  volume", volume, "creator fees claimed", claimed);
        console2.log("  claimed per million of volume", (claimed * 1e6) / volume);
    }

    function _logTotals() internal view {
        (
            uint256 claimed,
            uint256 allocated,
            uint256 donated,
            uint256 toBuyback,
            uint256 toOps,
            uint256 buybackEth,
            uint256 tokensToSink,,
        ) = router.totals();
        console2.log("== totals after", curveTrades, "curve trades");
        console2.log("  curve volume", curveVolume, "V4 volume", v4Volume);
        console2.log("  claimed", claimed, "allocated", allocated);
        console2.log("  donated", donated, "to buyback", toBuyback);
        console2.log("  to ops", toOps, "buyback ETH spent", buybackEth);
        console2.log("  tokens burned", tokensToSink);
        console2.log("  LevPool cash", pool.cash(), "house shares", pool.balanceOf(DEAD));
    }

    /// @dev Moves time forward. Reads the time through the cheatcode: under via_ir, `block.timestamp` can be read
    ///      once per function, so `vm.warp(block.timestamp + x)` in a loop would not advance.
    function _skip(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    /// @dev PoolManager storage, as v4-core's StateLibrary reads it (pools mapping at slot 6, liquidity at +3).
    function _pool(bytes32 id) internal view returns (uint160 sqrtP, uint128 liq) {
        bytes32 slot = keccak256(abi.encodePacked(id, bytes32(uint256(6))));
        sqrtP = uint160(uint256(IPoolManager(POOL_MANAGER).extsload(slot)));
        liq = uint128(uint256(IPoolManager(POOL_MANAGER).extsload(bytes32(uint256(slot) + 3))));
    }

    /// @dev vm.rpc returns a JSON quantity as its big-endian bytes.
    function _toUint(bytes memory b) internal pure returns (uint256 v) {
        require(b.length <= 32, "quantity too long");
        for (uint256 i; i < b.length; ++i) {
            v = (v << 8) | uint8(b[i]);
        }
    }

    receive() external payable {}
}

/// @dev For vm.expectEmit on the factory's event.
interface IPonsFactoryEvents {
    event CreatorFeeRecipientUpdated(
        address indexed token, address indexed previousRecipient, address indexed newRecipient
    );
}
