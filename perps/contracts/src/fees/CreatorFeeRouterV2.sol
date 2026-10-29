// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LevPool} from "../LevPool.sol";
import {IPonsLaunchFactory, IPonsFeeEscrow, IPonsBondingCurve, IPonsMemeHook} from "../interfaces/IPons.sol";
import {IBuybackExecutor} from "../interfaces/IBuybackExecutor.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {TickRatio} from "../libraries/TickRatio.sol";

/// @title CreatorFeeRouterV2
/// @notice Creator-fee recipient of the MemeLev platform token on Pons V2. `harvest` pulls the fees out of Pons
///         (sweep the curve or the graduated pool, then `claim` from the FeeEscrow) and splits them: the pool's share
///         is donated to LevPool at once; the buyback and ops shares wait in their own buckets.
///         - Buyback: rules-based buys of the token, capped per call, spaced out and price-guarded on-chain. Bought
///           tokens go to a distributor until a fixed date, and to the burn address after it, forever.
///         - Ops: relayer and keeper gas first (`topUpGas`), the rest to the treasury (`claimOps`).
/// @dev Deployed with the three Pons addresses left zero, the same contract splits any ETH sent to it, for example
///      platform fees from LevExchange's treasury.
///      Books: ETH held = unallocated + buybackBalance + opsBalance, and every wei allocated lands in exactly one of
///      pool, buyback or ops.
///      Anything that could redirect money waits 7 days in a timelock: the split, the treasury, the buyback route,
///      the gas wallets, the Pons fee recipient and stray-token sweeps. Pausing only stops `allocate` and
///      `buyback`; it never moves funds.
///      This contract never calls Pons's `setBuybackEnabled`, so Pons buybacks stay off for as long as it is the
///      recipient (launch with `buybackEnabled = false`).
contract CreatorFeeRouterV2 is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant ONE = 1e18;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant TIMELOCK = 7 days;
    /// @dev A matured proposal must be executed within this window, or proposed again.
    uint256 public constant EXECUTION_WINDOW = 14 days;
    uint256 public constant BUYBACK_DELAY = 24 hours;
    uint256 public constant GAS_PERIOD = 24 hours;

    // Hard limits on the split.
    uint16 public constant PONS_MIN_POOL_BPS = 4000;
    uint16 public constant MAX_BUYBACK_BPS = 4000;
    uint16 public constant MAX_OPS_BPS = 3000;

    // Hard limits on the buyback guards.
    uint256 public constant MAX_PER_CALL_CAP = 1 ether;
    uint32 public constant MIN_INTERVAL_FLOOR = 1 minutes;
    uint32 public constant MIN_INTERVAL_CAP = 1 days;
    uint16 public constant MAX_DEPTH_BPS_CAP = 500;
    uint24 public constant MAX_SPOT_DEV_CAP = 1000;
    uint24 public constant MAX_FAST_ABOVE_SLOW_CAP = 5000;
    uint16 public constant MAX_FEE_AND_SLIP_BPS = 2000;

    // Hard limits on gas top-ups.
    uint256 public constant MAX_GAS_WALLETS = 8;
    uint256 public constant MAX_GAS_TARGET = 1 ether;
    uint256 public constant MAX_GAS_DAILY_CAP = 1 ether;

    enum Action {
        Split,
        Treasury,
        BuybackRoute,
        GasConfig,
        FeeRecipient,
        SweepToken
    }

    struct GasWallet {
        address wallet;
        uint96 target; // topped up to this balance
    }

    struct Totals {
        uint256 claimed; // pulled from the Pons FeeEscrow
        uint256 allocated; // all ETH split, claimed or sent here directly
        uint256 donated; // to LevPool
        uint256 toBuyback; // into the buyback bucket
        uint256 toOps; // into the ops bucket
        uint256 buybackEth; // ETH spent on buybacks
        uint256 tokensToSink; // tokens bought, delivered to the distributor or the burn address
        uint256 opsPaid; // to the treasury
        uint256 gasToppedUp; // to gas wallets
    }

    struct PendingSplit {
        uint16 poolBps;
        uint16 buybackBps;
        uint16 opsBps;
        uint64 eta;
    }

    struct PendingAddress {
        address value;
        uint64 eta;
    }

    struct PendingRoute {
        IBuybackExecutor executor;
        IPriceOracle oracle;
        uint64 eta;
    }

    struct PendingGas {
        GasWallet[] wallets;
        uint256 dailyCap;
        uint64 eta;
    }

    struct PendingSweep {
        address token;
        address to;
        uint256 amount;
        uint64 eta;
    }

    LevPool public immutable pool;
    IPonsLaunchFactory public immutable factory;
    IPonsFeeEscrow public immutable escrow;
    address public immutable ponsHook;
    /// @notice Hard floor for `poolBps`, fixed at deployment.
    uint16 public immutable minPoolBps;
    /// @notice Receives bought tokens until `distributeUntil`. Zero: burn from the start.
    address public immutable distributor;
    uint64 public immutable distributeUntil;

    // Platform token, set once.
    address public token;
    address public curve;
    bytes32 public poolId; // the graduated Uniswap V4 pool
    uint64 public buybackStart;

    uint16 public poolBps = 8000;
    uint16 public buybackBps = 1000;
    uint16 public opsBps = 1000;

    address public treasury;
    address public guardian;
    IBuybackExecutor public executor;
    IPriceOracle public oracle; // price feed of the token's own pool

    bool public allocatePaused;
    bool public buybackPaused;

    uint256 public buybackBalance;
    uint256 public opsBalance;

    // Buyback guards, owner-settable within the hard limits above.
    uint256 public maxPerCall = 0.1 ether;
    uint32 public minInterval = 10 minutes;
    uint16 public maxDepthBps = 100; // of the pool's ETH liquidity
    uint24 public maxSpotDevTicks = 200; // |spot - fast|
    uint24 public maxFastAboveSlowTicks = 1000; // fast - slow: don't buy into a pump
    uint16 public feeAndSlipBps = 800; // 6% Pons fees + 2% for slippage and the live price sitting above the fast average
    uint64 public lastBuybackAt;

    GasWallet[] internal _gasWallets;
    uint256 public gasDailyCap;
    uint64 public gasPeriodStart;
    uint256 public gasSpentInPeriod;

    Totals public totals;

    PendingSplit public pendingSplit;
    PendingAddress public pendingTreasury;
    PendingRoute public pendingRoute;
    PendingGas internal _pendingGas;
    PendingAddress public pendingFeeRecipient;
    PendingSweep public pendingSweep;

    event TokenSet(address indexed token, address curve, bytes32 poolId, uint64 buybackStart);
    event Claimed(uint256 amount);
    event Allocated(uint256 toPool, uint256 toBuyback, uint256 toOps);
    event BoughtBack(uint256 ethSpent, uint256 tokensOut, uint256 minOut, int24 fastTick, address indexed to);
    event OpsClaimed(address indexed to, uint256 amount);
    event GasToppedUp(address indexed wallet, uint256 amount);
    event GasTopUpFailed(address indexed wallet, uint256 amount);
    event PausedSet(bool allocatePaused, bool buybackPaused, address indexed by);
    event GuardianSet(address guardian);
    event BuybackParamsSet(
        uint256 maxPerCall,
        uint32 minInterval,
        uint16 maxDepthBps,
        uint24 maxSpotDevTicks,
        uint24 maxFastAboveSlowTicks,
        uint16 feeAndSlipBps
    );
    event SplitProposed(uint16 poolBps, uint16 buybackBps, uint16 opsBps, uint64 eta);
    event TreasuryProposed(address treasury, uint64 eta);
    event BuybackRouteProposed(address executor, address oracle, uint64 eta);
    event GasConfigProposed(GasWallet[] wallets, uint256 dailyCap, uint64 eta);
    event FeeRecipientProposed(address newRecipient, uint64 eta);
    event SweepProposed(address indexed token, address to, uint256 amount, uint64 eta);
    event ChangeCancelled(Action indexed action, address indexed by);
    event SplitUpdated(uint16 poolBps, uint16 buybackBps, uint16 opsBps);
    event TreasuryUpdated(address treasury);
    event BuybackRouteUpdated(address executor, address oracle);
    event GasConfigUpdated(GasWallet[] wallets, uint256 dailyCap);
    event FeeRecipientTransferred(address indexed token, address newRecipient);
    event TokenSwept(address indexed token, address to, uint256 amount);

    error ZeroAddress();
    error BadPonsConfig();
    error BadSplit();
    error BadValue();
    error AlreadySet();
    error TokenNotSet();
    error UnknownLaunch();
    error NotFeeRecipient();
    error NotGuardian();
    error OnlyOwnerUnpauses();
    error NoPendingChange();
    error TimelockNotElapsed(uint256 eta);
    error ProposalExpired(uint256 expiredAt);
    error ProposalMismatch();
    error PlatformToken();
    error NoPons();
    error AllocationPaused();
    error BuybackPaused();
    error BuybackNotReady();
    error BuybackNotStarted(uint256 startsAt);
    error TooSoon(uint256 nextAt);
    error TooLarge(uint256 cap);
    error PriceUnstable(int256 spotTick, int256 fastTick);
    error PriceTooHigh(int256 fastTick, int256 slowTick);
    error NotEnoughOut(uint256 got, uint256 minOut);
    error TransferFailed();
    error CannotRenounce();

    /// @param pool_ LevPool that receives the pool share through `donate`.
    /// @param factory_ Pons V2 launch factory. Zero (with `escrow_` and `ponsHook_`) for a platform-fee splitter.
    /// @param escrow_ Pons FeeEscrow that holds our creator fees until we `claim` them.
    /// @param ponsHook_ Pons meme hook of graduated pools.
    /// @param minPoolBps_ Hard floor for the pool share: at least 4000 with Pons, any value without.
    /// @param treasury_ Receives ops money through `claimOps`.
    /// @param distributor_ Receives bought tokens until `distributeUntil_`. Zero: burn only.
    /// @param distributeUntil_ After this time bought tokens go to the burn address. It can never be moved.
    constructor(
        LevPool pool_,
        IPonsLaunchFactory factory_,
        IPonsFeeEscrow escrow_,
        address ponsHook_,
        uint16 minPoolBps_,
        address treasury_,
        address distributor_,
        uint64 distributeUntil_,
        address owner_
    ) Ownable(owner_) {
        if (address(pool_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        bool pons = address(factory_) != address(0);
        if ((address(escrow_) != address(0)) != pons || (ponsHook_ != address(0)) != pons) revert BadPonsConfig();
        if (pons && minPoolBps_ < PONS_MIN_POOL_BPS) revert BadSplit();
        pool = pool_;
        factory = factory_;
        escrow = escrow_;
        ponsHook = ponsHook_;
        minPoolBps = minPoolBps_;
        distributor = distributor_;
        distributeUntil = distributeUntil_;
        treasury = treasury_;
        _checkSplit(poolBps, buybackBps, opsBps);
    }

    /// @dev Does nothing, so any payment works, even a 2300-gas `transfer` (the live FeeEscrow pays with a full-gas
    ///      call: test/fork/PonsLaunchFlow.fork.t.sol). ETH that arrives here waits for `allocate`.
    receive() external payable {}

    // ------------------------------------------------------------- set token

    /// @notice Binds the router to the platform token, once. With Pons, the launch must exist and already pay its
    ///         creator fees to this contract. Buybacks unlock 24 hours later.
    function setToken(address token_) external onlyOwner {
        if (token != address(0)) revert AlreadySet();
        if (token_ == address(0)) revert ZeroAddress();
        address curve_;
        bytes32 poolId_;
        if (address(factory) != address(0)) {
            IPonsLaunchFactory.LaunchedToken memory lt = factory.getLaunchedToken(token_);
            if (!lt.exists) revert UnknownLaunch();
            if (lt.creatorFeeRecipient != address(this)) revert NotFeeRecipient();
            curve_ = lt.curve;
            poolId_ = ponsPoolId(token_, lt.pairToken, lt.poolFee, lt.tickSpacing);
        }
        uint64 start = uint64(block.timestamp + BUYBACK_DELAY);
        token = token_;
        curve = curve_;
        poolId = poolId_;
        buybackStart = start;
        emit TokenSet(token_, curve_, poolId_, start);
    }

    // ------------------------------------------------------------- inflows

    /// @notice Anyone can call it. Sweeps pending fees on the curve and on the graduated pool into the escrow,
    ///         claims our escrow balance, then splits everything unallocated (unless allocation is paused).
    /// @dev Each step is best-effort: a sweep that needs the Pons operator (`InternalSwapRequiresOperator`) or a
    ///      claim with nothing to pay is skipped, and the operator's own sweep will credit the escrow later.
    function harvest() external nonReentrant returns (uint256 claimed) {
        claimed = _collect();
        if (!allocatePaused) _allocate();
    }

    /// @notice Splits ETH not yet in a bucket: the pool's share is donated now, the rest goes into the buckets.
    function allocate() external nonReentrant {
        if (allocatePaused) revert AllocationPaused();
        _allocate();
    }

    // ------------------------------------------------------------- buyback

    /// @notice Anyone can call it. Buys the token with `ethIn` from the buyback bucket and sends it to `sink()`.
    /// @dev Guards: at most min(maxPerCall, bucket, maxDepthBps of the pool's ETH liquidity) per call, at least
    ///      `minInterval` apart, live price within `maxSpotDevTicks` of the fast average, fast average at most
    ///      `maxFastAboveSlowTicks` above the slow one, and at least the oracle's fair amount less `feeAndSlipBps`
    ///      out, whatever `minOut` says. ETH the executor sends back returns to the bucket.
    function buyback(uint256 ethIn, uint256 minOut) external nonReentrant returns (uint256 tokensOut) {
        if (buybackPaused) revert BuybackPaused();
        address t = token;
        if (t == address(0)) revert TokenNotSet();
        IBuybackExecutor ex = executor;
        IPriceOracle o = oracle;
        if (address(ex) == address(0) || address(o) == address(0)) revert BuybackNotReady();
        if (block.timestamp < buybackStart) revert BuybackNotStarted(buybackStart);
        if (lastBuybackAt != 0 && block.timestamp < uint256(lastBuybackAt) + minInterval) {
            revert TooSoon(uint256(lastBuybackAt) + minInterval);
        }
        if (ethIn == 0) revert BadValue();

        (int24 spot, int24 fast, int24 slow, uint256 liquidityEth) = o.read();
        uint256 cap = _cap(liquidityEth);
        if (ethIn > cap) revert TooLarge(cap);
        if (_abs(int256(spot) - fast) > maxSpotDevTicks) revert PriceUnstable(spot, fast);
        if (int256(fast) - slow > int256(uint256(maxFastAboveSlowTicks))) revert PriceTooHigh(fast, slow);

        uint256 floor = _floorOut(ethIn, fast);
        uint256 minEff = minOut > floor ? minOut : floor;
        address to = sink();

        buybackBalance -= ethIn;
        lastBuybackAt = uint64(block.timestamp);
        uint256 ethBefore = address(this).balance;
        uint256 tokBefore = IERC20(t).balanceOf(to);
        uint256 reported = ex.buy{value: ethIn}(t, minEff, to);
        tokensOut = IERC20(t).balanceOf(to) - tokBefore;
        if (tokensOut < minEff || reported < minEff) revert NotEnoughOut(tokensOut, minEff);

        // Unspent ETH comes back through receive(); anything beyond ethIn stays unallocated.
        uint256 left = ethBefore - ethIn;
        uint256 ethAfter = address(this).balance;
        uint256 refund = ethAfter > left ? ethAfter - left : 0;
        if (refund > ethIn) refund = ethIn;
        buybackBalance += refund;
        uint256 spent = ethIn - refund;
        totals.buybackEth += spent;
        totals.tokensToSink += tokensOut;
        emit BoughtBack(spent, tokensOut, minEff, fast, to);
    }

    /// @notice Where bought tokens go: the distributor until `distributeUntil`, the burn address after.
    function sink() public view returns (address) {
        if (distributor != address(0) && block.timestamp < distributeUntil) return distributor;
        return BURN;
    }

    // ------------------------------------------------------------------ ops

    /// @notice Pays ops money to the treasury.
    function claimOps(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0 || amount > opsBalance) revert BadValue();
        opsBalance -= amount;
        totals.opsPaid += amount;
        _send(treasury, amount);
        emit OpsClaimed(treasury, amount);
    }

    /// @notice Anyone can call it. Tops each registered gas wallet up to its target from the ops bucket, at most
    ///         `gasDailyCap` per 24-hour period. A wallet that rejects ETH is skipped.
    /// @dev Periods are fixed, not rolling: one starts with the first call after the previous one ended, so two
    ///      calls either side of a period's end can send up to twice the cap within 24 hours.
    function topUpGas() external nonReentrant returns (uint256 sent) {
        if (block.timestamp >= uint256(gasPeriodStart) + GAS_PERIOD) {
            gasPeriodStart = uint64(block.timestamp);
            gasSpentInPeriod = 0;
        }
        uint256 n = _gasWallets.length;
        for (uint256 i; i < n; ++i) {
            uint256 room = gasDailyCap > gasSpentInPeriod ? gasDailyCap - gasSpentInPeriod : 0;
            if (room > opsBalance) room = opsBalance;
            if (room == 0) break;
            GasWallet memory w = _gasWallets[i];
            uint256 bal = w.wallet.balance;
            if (bal >= w.target) continue;
            uint256 amt = w.target - bal;
            if (amt > room) amt = room;
            opsBalance -= amt;
            gasSpentInPeriod += amt;
            (bool ok,) = w.wallet.call{value: amt}("");
            if (!ok) {
                opsBalance += amt;
                gasSpentInPeriod -= amt;
                emit GasTopUpFailed(w.wallet, amt);
                continue;
            }
            totals.gasToppedUp += amt;
            sent += amt;
            emit GasToppedUp(w.wallet, amt);
        }
    }

    // --------------------------------------------------------------- safety

    /// @notice The guardian may only pause; the owner may pause and unpause. Pausing never moves funds.
    function setPaused(bool allocatePaused_, bool buybackPaused_) external {
        if (msg.sender != owner()) {
            if (msg.sender != guardian) revert NotGuardian();
            if ((allocatePaused && !allocatePaused_) || (buybackPaused && !buybackPaused_)) revert OnlyOwnerUnpauses();
        }
        allocatePaused = allocatePaused_;
        buybackPaused = buybackPaused_;
        emit PausedSet(allocatePaused_, buybackPaused_, msg.sender);
    }

    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function setBuybackParams(
        uint256 maxPerCall_,
        uint32 minInterval_,
        uint16 maxDepthBps_,
        uint24 maxSpotDevTicks_,
        uint24 maxFastAboveSlowTicks_,
        uint16 feeAndSlipBps_
    ) external onlyOwner {
        if (
            maxPerCall_ > MAX_PER_CALL_CAP || minInterval_ < MIN_INTERVAL_FLOOR || minInterval_ > MIN_INTERVAL_CAP
                || maxDepthBps_ > MAX_DEPTH_BPS_CAP || maxSpotDevTicks_ > MAX_SPOT_DEV_CAP
                || maxFastAboveSlowTicks_ > MAX_FAST_ABOVE_SLOW_CAP || feeAndSlipBps_ > MAX_FEE_AND_SLIP_BPS
        ) revert BadValue();
        maxPerCall = maxPerCall_;
        minInterval = minInterval_;
        maxDepthBps = maxDepthBps_;
        maxSpotDevTicks = maxSpotDevTicks_;
        maxFastAboveSlowTicks = maxFastAboveSlowTicks_;
        feeAndSlipBps = feeAndSlipBps_;
        emit BuybackParamsSet(
            maxPerCall_, minInterval_, maxDepthBps_, maxSpotDevTicks_, maxFastAboveSlowTicks_, feeAndSlipBps_
        );
    }

    /// @dev Renouncing would strand the ops bucket and freeze every timelocked change, including recipient moves.
    function renounceOwnership() public pure override {
        revert CannotRenounce();
    }

    // ------------------------------------------------------------- timelock

    function proposeSplit(uint16 poolBps_, uint16 buybackBps_, uint16 opsBps_) external onlyOwner {
        _checkSplit(poolBps_, buybackBps_, opsBps_);
        uint64 eta = _eta();
        pendingSplit = PendingSplit(poolBps_, buybackBps_, opsBps_, eta);
        emit SplitProposed(poolBps_, buybackBps_, opsBps_, eta);
    }

    /// @dev ETH that arrived under the old split is allocated under it first (unless allocation is paused).
    function executeSplit() external onlyOwner nonReentrant {
        PendingSplit memory p = pendingSplit;
        _ready(p.eta);
        delete pendingSplit;
        if (!allocatePaused) _allocate();
        poolBps = p.poolBps;
        buybackBps = p.buybackBps;
        opsBps = p.opsBps;
        emit SplitUpdated(p.poolBps, p.buybackBps, p.opsBps);
    }

    function proposeTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        uint64 eta = _eta();
        pendingTreasury = PendingAddress(treasury_, eta);
        emit TreasuryProposed(treasury_, eta);
    }

    function executeTreasury() external onlyOwner {
        PendingAddress memory p = pendingTreasury;
        _ready(p.eta);
        delete pendingTreasury;
        treasury = p.value;
        emit TreasuryUpdated(p.value);
    }

    /// @notice Buyback executor and the price feed of the token's own pool. Zero for either disables buybacks.
    function proposeBuybackRoute(IBuybackExecutor executor_, IPriceOracle oracle_) external onlyOwner {
        uint64 eta = _eta();
        pendingRoute = PendingRoute(executor_, oracle_, eta);
        emit BuybackRouteProposed(address(executor_), address(oracle_), eta);
    }

    function executeBuybackRoute() external onlyOwner {
        PendingRoute memory p = pendingRoute;
        _ready(p.eta);
        delete pendingRoute;
        executor = p.executor;
        oracle = p.oracle;
        emit BuybackRouteUpdated(address(p.executor), address(p.oracle));
    }

    /// @notice Replaces the whole list of gas wallets (relayer, keeper) and the daily cap.
    function proposeGasConfig(GasWallet[] calldata wallets, uint256 dailyCap) external onlyOwner {
        if (wallets.length > MAX_GAS_WALLETS || dailyCap > MAX_GAS_DAILY_CAP) revert BadValue();
        delete _pendingGas;
        for (uint256 i; i < wallets.length; ++i) {
            if (wallets[i].wallet == address(0)) revert ZeroAddress();
            if (wallets[i].target > MAX_GAS_TARGET) revert BadValue();
            _pendingGas.wallets.push(wallets[i]);
        }
        uint64 eta = _eta();
        _pendingGas.dailyCap = dailyCap;
        _pendingGas.eta = eta;
        emit GasConfigProposed(wallets, dailyCap, eta);
    }

    function executeGasConfig() external onlyOwner {
        _ready(_pendingGas.eta);
        delete _gasWallets;
        GasWallet[] storage ws = _pendingGas.wallets;
        for (uint256 i; i < ws.length; ++i) {
            _gasWallets.push(ws[i]);
        }
        gasDailyCap = _pendingGas.dailyCap;
        delete _pendingGas;
        emit GasConfigUpdated(_gasWallets, gasDailyCap);
    }

    /// @notice Moves the Pons creator fee stream to `newRecipient`. The only way this contract ever moves it.
    function proposeFeeRecipient(address newRecipient) external onlyOwner {
        if (address(factory) == address(0)) revert NoPons();
        if (token == address(0)) revert TokenNotSet();
        if (newRecipient == address(0) || newRecipient == address(this)) revert BadValue();
        uint64 eta = _eta();
        pendingFeeRecipient = PendingAddress(newRecipient, eta);
        emit FeeRecipientProposed(newRecipient, eta);
    }

    /// @dev Sweeps and claims what is already ours first, so it can't follow the stream to the new recipient.
    function executeFeeRecipient() external onlyOwner nonReentrant {
        PendingAddress memory p = pendingFeeRecipient;
        _ready(p.eta);
        delete pendingFeeRecipient;
        _collect();
        factory.transferCreatorFeeRecipient(token, p.value);
        emit FeeRecipientTransferred(token, p.value);
    }

    /// @notice Stray ERC-20s only, never the platform token.
    function proposeSweepToken(address token_, address to, uint256 amount) external onlyOwner {
        if (token_ == address(0) || to == address(0)) revert ZeroAddress();
        if (token_ == token) revert PlatformToken();
        uint64 eta = _eta();
        pendingSweep = PendingSweep(token_, to, amount, eta);
        emit SweepProposed(token_, to, amount, eta);
    }

    /// @notice Executes the matching matured `proposeSweepToken`.
    function sweepToken(address token_, address to, uint256 amount) external onlyOwner nonReentrant {
        PendingSweep memory p = pendingSweep;
        _ready(p.eta);
        if (p.token != token_ || p.to != to || p.amount != amount) revert ProposalMismatch();
        // The token may have been set after the proposal.
        if (token_ == token) revert PlatformToken();
        delete pendingSweep;
        IERC20(token_).safeTransfer(to, amount);
        emit TokenSwept(token_, to, amount);
    }

    /// @notice The owner or the guardian can cancel any pending change.
    function cancel(Action action) external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardian();
        uint64 eta;
        if (action == Action.Split) {
            eta = pendingSplit.eta;
            delete pendingSplit;
        } else if (action == Action.Treasury) {
            eta = pendingTreasury.eta;
            delete pendingTreasury;
        } else if (action == Action.BuybackRoute) {
            eta = pendingRoute.eta;
            delete pendingRoute;
        } else if (action == Action.GasConfig) {
            eta = _pendingGas.eta;
            delete _pendingGas;
        } else if (action == Action.FeeRecipient) {
            eta = pendingFeeRecipient.eta;
            delete pendingFeeRecipient;
        } else {
            eta = pendingSweep.eta;
            delete pendingSweep;
        }
        if (eta == 0) revert NoPendingChange();
        emit ChangeCancelled(action, msg.sender);
    }

    // ---------------------------------------------------------------- views

    /// @notice ETH held that is in no bucket yet.
    function unallocated() public view returns (uint256) {
        uint256 held = buybackBalance + opsBalance;
        uint256 bal = address(this).balance;
        return bal > held ? bal - held : 0;
    }

    function buckets() external view returns (uint256 unallocated_, uint256 buyback_, uint256 ops_) {
        return (unallocated(), buybackBalance, opsBalance);
    }

    function split() external view returns (uint16, uint16, uint16) {
        return (poolBps, buybackBps, opsBps);
    }

    function gasWallets() external view returns (GasWallet[] memory) {
        return _gasWallets;
    }

    function pendingGasConfig() external view returns (GasWallet[] memory wallets, uint256 dailyCap, uint64 eta) {
        return (_pendingGas.wallets, _pendingGas.dailyCap, _pendingGas.eta);
    }

    /// @notice Gas still allowed this period (ignores the ops bucket).
    function gasRoom() external view returns (uint256) {
        if (block.timestamp >= uint256(gasPeriodStart) + GAS_PERIOD) return gasDailyCap;
        return gasDailyCap > gasSpentInPeriod ? gasDailyCap - gasSpentInPeriod : 0;
    }

    /// @notice Largest `ethIn` a buyback may use now. Reverts if the price feed does.
    function buybackCap() external view returns (uint256) {
        if (address(oracle) == address(0)) return 0;
        (,,, uint256 liquidityEth) = oracle.read();
        return _cap(liquidityEth);
    }

    /// @notice The fewest tokens a buyback of `ethIn` accepts at the current fast price.
    function floorOut(uint256 ethIn) external view returns (uint256) {
        if (address(oracle) == address(0)) return 0;
        (, int24 fast,,) = oracle.read();
        return _floorOut(ethIn, fast);
    }

    function nextBuybackAt() external view returns (uint256) {
        uint256 next = lastBuybackAt == 0 ? 0 : uint256(lastBuybackAt) + minInterval;
        return next > buybackStart ? next : buybackStart;
    }

    /// @notice Who Pons pays our token's creator fees to right now (the Pons owner can redirect it on its own).
    function currentFeeRecipient() external view returns (address) {
        if (address(factory) == address(0) || token == address(0)) return address(0);
        return factory.getLaunchedToken(token).creatorFeeRecipient;
    }

    /// @notice Id of the graduated Pons pool: keccak256(abi.encode(PoolKey)), currencies sorted, native ETH = 0.
    function ponsPoolId(address token_, address pairToken, uint24 fee, int24 tickSpacing)
        public
        view
        returns (bytes32)
    {
        (address c0, address c1) = pairToken < token_ ? (pairToken, token_) : (token_, pairToken);
        return keccak256(abi.encode(c0, c1, fee, tickSpacing, ponsHook));
    }

    // ------------------------------------------------------------- internal

    function _collect() internal returns (uint256 claimed) {
        address c = curve;
        if (c != address(0)) {
            try IPonsBondingCurve(c).sweepFees(0) {} catch {}
        }
        bytes32 id = poolId;
        if (id != bytes32(0)) {
            try IPonsMemeHook(ponsHook).sweepPoolFees(id, 0, 0) {} catch {}
        }
        if (address(escrow) != address(0)) {
            uint256 before = address(this).balance;
            try escrow.claim() returns (uint256) {} catch {}
            claimed = address(this).balance - before;
            if (claimed != 0) {
                totals.claimed += claimed;
                emit Claimed(claimed);
            }
        }
    }

    function _allocate() internal {
        uint256 amount = unallocated();
        if (amount == 0) return;
        uint256 toBuyback = (amount * buybackBps) / BPS;
        uint256 toOps = (amount * opsBps) / BPS;
        uint256 toPool = amount - toBuyback - toOps; // rounding dust goes to the pool
        buybackBalance += toBuyback;
        opsBalance += toOps;
        totals.allocated += amount;
        totals.toBuyback += toBuyback;
        totals.toOps += toOps;
        totals.donated += toPool;
        if (toPool != 0) pool.donate{value: toPool}();
        emit Allocated(toPool, toBuyback, toOps);
    }

    function _cap(uint256 liquidityEth) internal view returns (uint256 cap) {
        cap = maxPerCall;
        if (buybackBalance < cap) cap = buybackBalance;
        uint256 depth = (liquidityEth * maxDepthBps) / BPS;
        if (depth < cap) cap = depth;
    }

    /// @dev Ticks price the token in ETH, so tokens per ETH = 1.0001^-fast.
    function _floorOut(uint256 ethIn, int24 fast) internal view returns (uint256) {
        uint256 expected = (ethIn * TickRatio.ratio(-int256(fast))) / ONE;
        return (expected * (BPS - feeAndSlipBps)) / BPS;
    }

    function _checkSplit(uint16 p, uint16 b, uint16 o) internal view {
        if (p < minPoolBps || b > MAX_BUYBACK_BPS || o > MAX_OPS_BPS || uint256(p) + b + o != BPS) revert BadSplit();
    }

    function _eta() internal view returns (uint64) {
        return uint64(block.timestamp + TIMELOCK);
    }

    function _ready(uint64 eta) internal view {
        if (eta == 0) revert NoPendingChange();
        if (block.timestamp < eta) revert TimelockNotElapsed(eta);
        if (block.timestamp > uint256(eta) + EXECUTION_WINDOW) revert ProposalExpired(uint256(eta) + EXECUTION_WINDOW);
    }

    function _abs(int256 v) internal pure returns (uint256) {
        return uint256(v < 0 ? -v : v);
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
