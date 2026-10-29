// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CreatorFeeRouterV2} from "../../src/fees/CreatorFeeRouterV2.sol";
import {LevPool} from "../../src/LevPool.sol";
import {IPonsLaunchFactory, IPonsFeeEscrow, IPonsBondingCurve, IPonsMemeHook} from "../../src/interfaces/IPons.sol";
import {IBuybackExecutor} from "../../src/interfaces/IBuybackExecutor.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {TickRatio} from "../../src/libraries/TickRatio.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockOracle} from "../../src/mocks/MockOracle.sol";

// =====================================================================================================================
// Mocks of the Pons V2 parts the router touches. They follow the published source's access rules: only the creator
// fee recipient (or the Pons operator) may sweep, and a sweep that would need an internal swap is operator-only.
// =====================================================================================================================

/// @notice Uniswap V4 PoolKey layout, for computing pool ids independently of the router.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice Pull-based fee ledger. `claim` pays msg.sender either with a full call or with a 2300-gas `transfer`.
contract MockFeeEscrow is IPonsFeeEscrow {
    enum PayMode {
        Call,
        Transfer,
        Revert
    }

    PayMode public mode;
    mapping(address => uint256) public override balanceOf;
    mapping(address => uint256) public paidTo;

    error NothingToClaim();

    function setMode(PayMode m) external {
        mode = m;
    }

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
    }

    function claim() external returns (uint256 amount) {
        if (mode == PayMode.Revert) revert("escrow down");
        amount = balanceOf[msg.sender];
        if (amount == 0) revert NothingToClaim();
        balanceOf[msg.sender] = 0;
        paidTo[msg.sender] += amount;
        if (mode == PayMode.Transfer) {
            payable(msg.sender).transfer(amount);
        } else {
            (bool ok,) = msg.sender.call{value: amount}("");
            require(ok, "send failed");
        }
    }
}

contract MockBondingCurve is IPonsBondingCurve {
    error NotFeeSweepOperator();
    error InternalSwapRequiresOperator();
    error AlreadyGraduated();
    error OnlyFactory();

    MockFeeEscrow public immutable escrow;
    address public immutable factory;
    address public immutable operator;
    address public deployer; // the creator fee recipient
    bool public override graduated;
    bool public needsOperator;
    uint256 public pendingCreatorFees;

    constructor(MockFeeEscrow escrow_, address factory_, address operator_) {
        escrow = escrow_;
        factory = factory_;
        operator = operator_;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    function setDeployer(address d) external onlyFactory {
        deployer = d;
    }

    function setNeedsOperator(bool v) external {
        needsOperator = v;
    }

    /// @dev Stand-in for trading on the curve: the creator's share of fees waits here until swept.
    function accrue() external payable {
        if (graduated) revert AlreadyGraduated();
        pendingCreatorFees += msg.value;
    }

    function sweepFees(uint256) external {
        if (graduated) revert AlreadyGraduated();
        bool isOperator = msg.sender == operator;
        if (!isOperator && msg.sender != deployer) revert NotFeeSweepOperator();
        if (!isOperator && needsOperator) revert InternalSwapRequiresOperator();
        _sweep();
    }

    function graduate() external onlyFactory {
        _sweep();
        graduated = true;
    }

    function _sweep() internal {
        uint256 a = pendingCreatorFees;
        pendingCreatorFees = 0;
        if (a != 0) escrow.credit{value: a}(deployer);
    }
}

contract MockMemeHook is IPonsMemeHook {
    error UnknownPool();
    error NotFeeSweepOperator();
    error InternalSwapRequiresOperator();
    error OnlyFactory();

    MockFeeEscrow public immutable escrow;
    address public immutable operator;
    address public factory;
    bool public needsOperator;
    mapping(bytes32 => bool) public registered;
    mapping(bytes32 => address) public creator;
    mapping(bytes32 => uint256) public pending;

    constructor(MockFeeEscrow escrow_, address operator_) {
        escrow = escrow_;
        operator = operator_;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    function setFactory(address f) external {
        require(factory == address(0), "set");
        factory = f;
    }

    function setNeedsOperator(bool v) external {
        needsOperator = v;
    }

    function register(bytes32 id, address creator_) external onlyFactory {
        registered[id] = true;
        creator[id] = creator_;
    }

    function setCreator(bytes32 id, address creator_) external onlyFactory {
        creator[id] = creator_;
    }

    function accrue(bytes32 id) external payable {
        pending[id] += msg.value;
    }

    function sweepPoolFees(bytes32 id, uint256, uint256) external {
        if (!registered[id]) revert UnknownPool();
        bool isOperator = msg.sender == operator;
        if (!isOperator && msg.sender != creator[id]) revert NotFeeSweepOperator();
        if (!isOperator && needsOperator) revert InternalSwapRequiresOperator();
        uint256 a = pending[id];
        pending[id] = 0;
        if (a != 0) escrow.credit{value: a}(creator[id]);
    }
}

contract MockLaunchFactory is IPonsLaunchFactory {
    error TokenNotFound();
    error NotCreatorFeeRecipient();
    error ZeroAddress();

    MockMemeHook public immutable hook;
    mapping(address => LaunchedToken) internal _launches;

    constructor(MockMemeHook hook_) {
        hook = hook_;
    }

    function launch(address token, MockBondingCurve curve, address recipient, uint16 creatorTaxBps) external {
        LaunchedToken storage l = _launches[token];
        l.token = token;
        l.curve = address(curve);
        l.deployer = msg.sender;
        l.creatorFeeRecipient = recipient;
        l.pairToken = address(0);
        l.graduationThreshold = 4.2 ether;
        l.poolFee = 0;
        l.tickSpacing = 200;
        l.creatorTaxBps = creatorTaxBps;
        l.exists = true;
        curve.setDeployer(recipient);
    }

    function graduate(address token) external {
        LaunchedToken storage l = _launches[token];
        MockBondingCurve(l.curve).graduate();
        l.phase = GraduationPhase.PoolCreated;
        hook.register(poolIdOf(token), l.creatorFeeRecipient);
    }

    function poolIdOf(address token) public view returns (bytes32) {
        LaunchedToken storage l = _launches[token];
        return keccak256(abi.encode(PoolKey(address(0), token, l.poolFee, l.tickSpacing, address(hook))));
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory) {
        return _launches[token];
    }

    function transferCreatorFeeRecipient(address token, address newRecipient) external {
        LaunchedToken storage l = _launches[token];
        if (!l.exists) revert TokenNotFound();
        if (msg.sender != l.creatorFeeRecipient) revert NotCreatorFeeRecipient();
        if (newRecipient == address(0)) revert ZeroAddress();
        l.creatorFeeRecipient = newRecipient;
        if (l.phase == GraduationPhase.PoolCreated) hook.setCreator(poolIdOf(token), newRecipient);
        else MockBondingCurve(l.curve).setDeployer(newRecipient);
    }
}

/// @notice Mints `msg.value * rate * deliverBps` tokens to `to` and sends back the part of `msg.value` it does not
///         spend. Modes cover a misbehaving executor.
contract MockBuybackExecutor is IBuybackExecutor {
    enum Mode {
        Honest, // reverts below minOut, like a real executor
        IgnoreMin, // delivers less than minOut without reverting
        Lie, // delivers less but reports minOut
        Reenter // calls back into the router first
    }

    Mode public mode;
    uint256 public rate; // tokens per ETH, 18 decimals
    uint16 public deliverBps = 9400; // 6% Pons fees
    uint16 public spendBps = 10_000;
    uint256 public lastMinOut;
    address public lastTo;
    address public reenterTarget;
    bytes public reenterData;

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setRate(uint256 v) external {
        rate = v;
    }

    function setDeliverBps(uint16 v) external {
        deliverBps = v;
    }

    function setSpendBps(uint16 v) external {
        spendBps = v;
    }

    function setReenter(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function buy(address token, uint256 minOut, address to) external payable returns (uint256 out) {
        if (mode == Mode.Reenter) {
            (bool ok, bytes memory ret) = reenterTarget.call(reenterData);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        lastMinOut = minOut;
        lastTo = to;
        out = (((msg.value * rate) / 1e18) * deliverBps) / 10_000;
        if (mode == Mode.Honest && out < minOut) revert("min out");
        MockERC20(token).mint(to, out);
        uint256 refund = msg.value - (msg.value * spendBps) / 10_000;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "refund failed");
        }
        if (mode == Mode.Lie) return minOut;
    }
}

/// @notice Its receive() writes storage, so a 2300-gas transfer to it must fail. Proves the escrow mock's
///         transfer mode really caps gas.
contract StorageWritingReceiver {
    uint256 public hits;

    receive() external payable {
        hits++;
    }

    function claimFrom(MockFeeEscrow e) external {
        e.claim();
    }
}

contract RejectingWallet {
    receive() external payable {
        revert("no");
    }
}

// =====================================================================================================================
// Shared setup
// =====================================================================================================================

abstract contract RouterFixture is Test {
    uint256 internal constant BPS = 10_000;
    int24 internal constant TICK = -69_082; // about 0.001 ETH per token
    uint256 internal constant LIQ = 100 ether;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LevPool internal pool;
    MockERC20 internal token;
    MockFeeEscrow internal escrow;
    MockMemeHook internal hook;
    MockLaunchFactory internal factory;
    MockBondingCurve internal curve;
    MockOracle internal oracle;
    MockBuybackExecutor internal executor;
    CreatorFeeRouterV2 internal router;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal guardian = makeAddr("guardian");
    address internal distributor = makeAddr("distributor");
    address internal ponsOperator = makeAddr("ponsOperator");
    address internal relayer = makeAddr("relayer");
    address internal keeperWallet = makeAddr("keeperWallet");
    address internal alice = makeAddr("alice");
    uint64 internal distributeUntil;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        // A bare pool with only the dead seed: donations become house shares.
        pool = new LevPool{value: 0.001 ether}(owner);
        token = new MockERC20("MemeLev", "MLEV");
        escrow = new MockFeeEscrow();
        hook = new MockMemeHook(escrow, ponsOperator);
        factory = new MockLaunchFactory(hook);
        hook.setFactory(address(factory));
        curve = new MockBondingCurve(escrow, address(factory), ponsOperator);
        distributeUntil = uint64(block.timestamp + 90 days);
        router = _newRouter(distributor);
        factory.launch(address(token), curve, address(router), 500);
        vm.startPrank(owner);
        router.setToken(address(token));
        router.setGuardian(guardian);
        vm.stopPrank();

        oracle = new MockOracle(TICK, LIQ);
        executor = new MockBuybackExecutor(TickRatio.ratio(-int256(TICK)));
        vm.deal(address(this), 1_000_000 ether);
    }

    receive() external payable {}

    function _newRouter(address distributor_) internal returns (CreatorFeeRouterV2) {
        return new CreatorFeeRouterV2(
            pool, factory, escrow, address(hook), 4000, treasury, distributor_, distributeUntil, owner
        );
    }

    /// @dev Reads the cheatcode clock: via-IR can cache block.timestamp inside one test function.
    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _wait(uint256 secs) internal {
        vm.warp(_now() + secs);
    }

    function _creditEscrow(uint256 amount) internal {
        escrow.credit{value: amount}(address(router));
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "send");
    }

    function _setRoute(CreatorFeeRouterV2 r) internal {
        vm.prank(owner);
        r.proposeBuybackRoute(executor, oracle);
        _wait(7 days);
        vm.prank(owner);
        r.executeBuybackRoute();
    }

    function _setGas(CreatorFeeRouterV2 r, uint96 relayerTarget, uint96 keeperTarget, uint256 cap) internal {
        CreatorFeeRouterV2.GasWallet[] memory ws = new CreatorFeeRouterV2.GasWallet[](2);
        ws[0] = CreatorFeeRouterV2.GasWallet(relayer, relayerTarget);
        ws[1] = CreatorFeeRouterV2.GasWallet(keeperWallet, keeperTarget);
        vm.prank(owner);
        r.proposeGasConfig(ws, cap);
        _wait(7 days);
        vm.prank(owner);
        r.executeGasConfig();
    }

    /// @dev 10 ETH claimed: 8 to the pool, 1 to buyback, 1 to ops; then the buyback route is set.
    function _readyBuyback() internal {
        _creditEscrow(10 ether);
        router.harvest();
        _setRoute(router);
    }

    function _totals() internal view returns (CreatorFeeRouterV2.Totals memory t) {
        (
            t.claimed,
            t.allocated,
            t.donated,
            t.toBuyback,
            t.toOps,
            t.buybackEth,
            t.tokensToSink,
            t.opsPaid,
            t.gasToppedUp
        ) = router.totals();
    }

    function _fair(uint256 ethIn) internal pure returns (uint256) {
        return (ethIn * TickRatio.ratio(-int256(TICK))) / 1e18;
    }

    function _assertBooks() internal view {
        CreatorFeeRouterV2.Totals memory t = _totals();
        assertGe(address(router).balance, router.buybackBalance() + router.opsBalance(), "solvent");
        assertEq(address(router).balance, router.unallocated() + router.buybackBalance() + router.opsBalance(), "books");
        assertEq(t.allocated, t.donated + t.toBuyback + t.toOps, "split");
        assertEq(t.toBuyback, router.buybackBalance() + t.buybackEth, "buyback bucket");
        assertEq(t.toOps, router.opsBalance() + t.opsPaid + t.gasToppedUp, "ops bucket");
        assertEq(t.claimed, escrow.paidTo(address(router)), "claimed");
    }
}

// =====================================================================================================================
// Unit tests
// =====================================================================================================================

contract CreatorFeeRouterV2Test is RouterFixture {
    // ------------------------------------------------------------ deployment

    function test_constructor_defaults() public view {
        (uint16 p, uint16 b, uint16 o) = router.split();
        assertEq(p, 8000);
        assertEq(b, 1000);
        assertEq(o, 1000);
        assertEq(address(router.pool()), address(pool));
        assertEq(address(router.factory()), address(factory));
        assertEq(address(router.escrow()), address(escrow));
        assertEq(router.ponsHook(), address(hook));
        assertEq(router.minPoolBps(), 4000);
        assertEq(router.treasury(), treasury);
        assertEq(router.distributor(), distributor);
        assertEq(router.distributeUntil(), distributeUntil);
        assertEq(router.owner(), owner);
        assertEq(router.maxPerCall(), 0.1 ether);
        assertEq(router.minInterval(), 10 minutes);
        assertEq(router.maxDepthBps(), 100);
        assertEq(router.maxSpotDevTicks(), 200);
        assertEq(router.maxFastAboveSlowTicks(), 1000);
        assertEq(router.feeAndSlipBps(), 800);
        assertEq(router.sink(), distributor);
        assertFalse(router.allocatePaused());
        assertFalse(router.buybackPaused());
    }

    function test_constructor_reverts() public {
        vm.expectRevert(CreatorFeeRouterV2.ZeroAddress.selector);
        new CreatorFeeRouterV2(LevPool(payable(address(0))), factory, escrow, address(hook), 4000, treasury, address(0), 0, owner);
        vm.expectRevert(CreatorFeeRouterV2.ZeroAddress.selector);
        new CreatorFeeRouterV2(pool, factory, escrow, address(hook), 4000, address(0), address(0), 0, owner);
        // Pons addresses are all set or all zero.
        vm.expectRevert(CreatorFeeRouterV2.BadPonsConfig.selector);
        new CreatorFeeRouterV2(pool, factory, IPonsFeeEscrow(address(0)), address(hook), 4000, treasury, address(0), 0, owner);
        vm.expectRevert(CreatorFeeRouterV2.BadPonsConfig.selector);
        new CreatorFeeRouterV2(pool, factory, escrow, address(0), 4000, treasury, address(0), 0, owner);
        vm.expectRevert(CreatorFeeRouterV2.BadPonsConfig.selector);
        new CreatorFeeRouterV2(
            pool, IPonsLaunchFactory(address(0)), escrow, address(0), 0, treasury, address(0), 0, owner
        );
        // With Pons the pool floor is at least 40%.
        vm.expectRevert(CreatorFeeRouterV2.BadSplit.selector);
        new CreatorFeeRouterV2(pool, factory, escrow, address(hook), 3999, treasury, address(0), 0, owner);
        // A floor above the initial 80% pool share can't hold.
        vm.expectRevert(CreatorFeeRouterV2.BadSplit.selector);
        new CreatorFeeRouterV2(
            pool, IPonsLaunchFactory(address(0)), IPonsFeeEscrow(address(0)), address(0), 8001, treasury, address(0), 0, owner
        );
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CreatorFeeRouterV2(pool, factory, escrow, address(hook), 4000, treasury, address(0), 0, address(0));
    }

    function test_platformFeeInstance_splitsAnyEth() public {
        CreatorFeeRouterV2 r = new CreatorFeeRouterV2(
            pool, IPonsLaunchFactory(address(0)), IPonsFeeEscrow(address(0)), address(0), 0, treasury, address(0), 0, owner
        );
        // Platform fees arrive like LevExchange.claimTreasury pays: a plain call.
        _send(address(r), 2 ether);
        assertEq(r.harvest(), 0);
        assertEq(pool.totalDonated(), 1.6 ether);
        assertEq(r.buybackBalance(), 0.2 ether);
        assertEq(r.opsBalance(), 0.2 ether);
        // No factory: setToken just records the token, and the split may go below 40% for the pool.
        vm.startPrank(owner);
        r.setToken(address(token));
        assertEq(r.curve(), address(0));
        assertEq(r.poolId(), bytes32(0));
        vm.expectRevert(CreatorFeeRouterV2.NoPons.selector);
        r.proposeFeeRecipient(alice);
        vm.stopPrank();
    }

    function test_platformFeeInstance_lowPoolSplit() public {
        CreatorFeeRouterV2 r = new CreatorFeeRouterV2(
            pool, IPonsLaunchFactory(address(0)), IPonsFeeEscrow(address(0)), address(0), 0, treasury, address(0), 0, owner
        );
        vm.prank(owner);
        vm.expectRevert(CreatorFeeRouterV2.BadSplit.selector); // ops above 30%
        r.proposeSplit(0, 4000, 6000);
        vm.prank(owner);
        r.proposeSplit(3000, 4000, 3000);
        _wait(7 days);
        vm.prank(owner);
        r.executeSplit();
        _send(address(r), 1 ether);
        r.allocate();
        assertEq(r.buybackBalance(), 0.4 ether);
        assertEq(r.opsBalance(), 0.3 ether);
    }

    function test_renounceOwnership_disabled() public {
        vm.prank(owner);
        vm.expectRevert(CreatorFeeRouterV2.CannotRenounce.selector);
        router.renounceOwnership();
    }

    // ------------------------------------------------------------- setToken

    function test_setToken_storesLaunch() public view {
        assertEq(router.token(), address(token));
        assertEq(router.curve(), address(curve));
        assertEq(router.poolId(), factory.poolIdOf(address(token)));
        assertEq(router.buybackStart(), 1_800_000_000 + 24 hours);
        assertEq(router.currentFeeRecipient(), address(router));
    }

    function test_poolId_isKeccakOfPoolKey() public view {
        bytes32 expected = keccak256(abi.encode(PoolKey(address(0), address(token), 0, 200, address(hook))));
        assertEq(router.poolId(), expected);
        assertEq(router.ponsPoolId(address(token), address(0), 0, 200), expected);
        // Negative tick spacing is sign-extended like in PoolKey memory.
        assertEq(
            router.ponsPoolId(address(token), address(0), 3000, -60),
            keccak256(abi.encode(PoolKey(address(0), address(token), 3000, -60, address(hook))))
        );
    }

    function test_setToken_onlyOnceAndOnlyOwner() public {
        vm.prank(owner);
        vm.expectRevert(CreatorFeeRouterV2.AlreadySet.selector);
        router.setToken(address(token));

        CreatorFeeRouterV2 r = _newRouter(address(0));
        factory.launch(address(0xBEEF), curve, address(r), 500);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        r.setToken(address(0xBEEF));
        vm.prank(owner);
        vm.expectRevert(CreatorFeeRouterV2.ZeroAddress.selector);
        r.setToken(address(0));
    }

    function test_setToken_requiresLaunchPayingThisRouter() public {
        CreatorFeeRouterV2 r = _newRouter(address(0));
        vm.prank(owner);
        vm.expectRevert(CreatorFeeRouterV2.UnknownLaunch.selector);
        r.setToken(address(0xBEEF));

        MockBondingCurve c2 = new MockBondingCurve(escrow, address(factory), ponsOperator);
        factory.launch(address(0xBEEF), c2, alice, 500);
        vm.prank(owner);
        vm.expectRevert(CreatorFeeRouterV2.NotFeeRecipient.selector);
        r.setToken(address(0xBEEF));
    }

    // -------------------------------------------------------------- receive

    function test_receive_accepts2300GasTransfer() public {
        payable(address(router)).transfer(1 ether);
        assertEq(router.unallocated(), 1 ether);
    }

    function test_mockEscrowTransfer_reallyCapsGas() public {
        StorageWritingReceiver r = new StorageWritingReceiver();
        escrow.credit{value: 1 ether}(address(r));
        escrow.setMode(MockFeeEscrow.PayMode.Transfer);
        vm.expectRevert();
        r.claimFrom(escrow);
        escrow.setMode(MockFeeEscrow.PayMode.Call);
        r.claimFrom(escrow);
        assertEq(r.hits(), 1);
    }

    // -------------------------------------------------------------- harvest

    function test_harvest_curveFees_fullCall() public {
        curve.accrue{value: 10 ether}();
        vm.expectEmit(address(router));
        emit CreatorFeeRouterV2.Claimed(10 ether);
        vm.expectEmit(address(router));
        emit CreatorFeeRouterV2.Allocated(8 ether, 1 ether, 1 ether);
        vm.prank(alice); // permissionless
        assertEq(router.harvest(), 10 ether);

        assertEq(curve.pendingCreatorFees(), 0);
        assertEq(escrow.balanceOf(address(router)), 0);
        assertEq(pool.totalDonated(), 8 ether);
        assertEq(pool.cash(), 8.001 ether);
        assertEq(router.buybackBalance(), 1 ether);
        assertEq(router.opsBalance(), 1 ether);
        assertEq(router.unallocated(), 0);
        CreatorFeeRouterV2.Totals memory t = _totals();
        assertEq(t.claimed, 10 ether);
        assertEq(t.allocated, 10 ether);
        assertEq(t.donated, 8 ether);
        _assertBooks();
    }

    function test_harvest_escrowPaysWith2300GasTransfer() public {
        escrow.setMode(MockFeeEscrow.PayMode.Transfer);
        curve.accrue{value: 5 ether}();
        assertEq(router.harvest(), 5 ether);
        assertEq(pool.totalDonated(), 4 ether);
        assertEq(router.buybackBalance(), 0.5 ether);
        assertEq(router.opsBalance(), 0.5 ether);
        _assertBooks();
    }

    function test_harvest_graduatedPool() public {
        curve.accrue{value: 1 ether}();
        factory.graduate(address(token)); // the curve's last fees are swept into the escrow at graduation
        hook.accrue{value: 3 ether}(router.poolId());
        // The curve sweep now reverts (graduated) and is skipped; the hook sweep and the claim go through.
        assertEq(router.harvest(), 4 ether);
        assertEq(hook.pending(router.poolId()), 0);
        assertEq(pool.totalDonated(), 3.2 ether);
        _assertBooks();
    }

    function test_harvest_skipsOperatorOnlySweeps() public {
        curve.accrue{value: 1 ether}();
        curve.setNeedsOperator(true);
        assertEq(router.harvest(), 0);
        assertEq(curve.pendingCreatorFees(), 1 ether);
        // The Pons operator sweeps on its own schedule; the next harvest claims it.
        vm.prank(ponsOperator);
        curve.sweepFees(1);
        assertEq(router.harvest(), 1 ether);

        factory.graduate(address(token));
        bytes32 id = router.poolId();
        hook.setNeedsOperator(true);
        hook.accrue{value: 2 ether}(id);
        assertEq(router.harvest(), 0);
        vm.prank(ponsOperator);
        hook.sweepPoolFees(id, 1, 1);
        assertEq(router.harvest(), 2 ether);
        _assertBooks();
    }

    function test_harvest_escrowDown_stillAllocatesDirectEth() public {
        escrow.setMode(MockFeeEscrow.PayMode.Revert);
        curve.accrue{value: 1 ether}();
        _send(address(router), 1 ether);
        assertEq(router.harvest(), 0);
        assertEq(escrow.balanceOf(address(router)), 1 ether); // swept but not claimed: still ours in the escrow
        assertEq(pool.totalDonated(), 0.8 ether);
        _assertBooks();
    }

    function test_harvest_nothingToClaim_isFine() public {
        assertEq(router.harvest(), 0);
        assertEq(_totals().allocated, 0);
    }

    function test_harvest_whileAllocationPaused_claimsButHolds() public {
        vm.prank(guardian);
        router.setPaused(true, false);
        curve.accrue{value: 2 ether}();
        assertEq(router.harvest(), 2 ether);
        assertEq(router.unallocated(), 2 ether);
        assertEq(router.buybackBalance(), 0);
        assertEq(pool.totalDonated(), 0);
        vm.prank(owner);
        router.setPaused(false, false);
        router.allocate();
        assertEq(pool.totalDonated(), 1.6 ether);
        _assertBooks();
    }

    function test_harvest_beforeSetToken_claimsEscrow() public {
        CreatorFeeRouterV2 r = _newRouter(address(0));
        escrow.credit{value: 1 ether}(address(r));
        assertEq(r.harvest(), 1 ether);
        assertEq(r.buybackBalance(), 0.1 ether);
    }

    // ------------------------------------------------------------- allocate

    function test_allocate_onlySplitsUnallocated() public {
        _creditEscrow(10 ether);
        router.harvest();
        _send(address(router), 1 ether);
        assertEq(router.unallocated(), 1 ether);
        router.allocate();
        assertEq(router.buybackBalance(), 1.1 ether);
        assertEq(router.opsBalance(), 1.1 ether);
        assertEq(pool.totalDonated(), 8.8 ether);
        // Calling again finds nothing new.
        router.allocate();
        assertEq(router.buybackBalance(), 1.1 ether);
        _assertBooks();
    }

    function test_allocate_roundingDustGoesToPool() public {
        _send(address(router), 9);
        router.allocate();
        assertEq(router.buybackBalance(), 0);
        assertEq(router.opsBalance(), 0);
        assertEq(pool.totalDonated(), 9);
        _send(address(router), 19);
        router.allocate();
        assertEq(router.buybackBalance(), 1);
        assertEq(router.opsBalance(), 1);
        assertEq(pool.totalDonated(), 9 + 17);
        _assertBooks();
    }

    function test_allocate_paused() public {
        vm.prank(owner);
        router.setPaused(true, false);
        vm.expectRevert(CreatorFeeRouterV2.AllocationPaused.selector);
        router.allocate();
    }

    function test_allocate_beforeAnyLp_becomesHouseShares() public {
        uint256 deadBefore = pool.balanceOf(DEAD);
        _creditEscrow(10 ether);
        router.harvest();
        assertGt(pool.balanceOf(DEAD), deadBefore);
        assertEq(pool.balanceOf(DEAD), pool.totalSupply());
        assertEq(pool.cash(), 8.001 ether);
    }

    function testFuzz_allocate_conservesEveryWei(uint256 amount, uint16 buybackBps, uint16 opsBps) public {
        amount = bound(amount, 0, 100_000 ether);
        buybackBps = uint16(bound(buybackBps, 0, 4000));
        // The pool keeps at least its 40% floor.
        opsBps = uint16(bound(opsBps, 0, buybackBps > 3000 ? 6000 - buybackBps : 3000));
        uint16 poolBps = uint16(BPS - buybackBps - opsBps);
        vm.prank(owner);
        router.proposeSplit(poolBps, buybackBps, opsBps);
        _wait(7 days);
        vm.prank(owner);
        router.executeSplit();

        _creditEscrow(amount + 1);
        router.harvest();
        uint256 total = amount + 1;
        assertEq(router.buybackBalance(), (total * buybackBps) / BPS);
        assertEq(router.opsBalance(), (total * opsBps) / BPS);
        assertEq(pool.totalDonated() + router.buybackBalance() + router.opsBalance(), total);
        assertEq(router.unallocated(), 0);
        _assertBooks();
    }

    // ---------------------------------------------------------- split change

    function test_split_timelock() public {
        vm.expectEmit(address(router));
        emit CreatorFeeRouterV2.SplitProposed(6000, 2000, 2000, uint64(_now() + 7 days));
        vm.prank(owner);
        router.proposeSplit(6000, 2000, 2000);
        (uint16 p, uint16 b, uint16 o, uint64 eta) = router.pendingSplit();
        assertEq(p, 6000);
        assertEq(b, 2000);
        assertEq(o, 2000);
        assertEq(eta, _now() + 7 days);

        _wait(7 days - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CreatorFeeRouterV2.TimelockNotElapsed.selector, eta));
        router.executeSplit();

        // ETH that came in under the old split is split the old way.
        _send(address(router), 1 ether);
        _wait(1);
        vm.prank(owner);
        router.executeSplit();
        assertEq(router.buybackBalance(), 0.1 ether);
        (p, b, o) = router.split();
        assertEq(p, 6000);
        (,,, eta) = router.pendingSplit();
        assertEq(eta, 0);

        _send(address(router), 1 ether);
        router.allocate();
        assertEq(router.buybackBalance(), 0.3 ether);
        assertEq(router.opsBalance(), 0.3 ether);
        _assertBooks();
    }

    function test_split_hardLimits() public {
        vm.startPrank(owner);
        vm.expectRevert(CreatorFeeRouterV2.BadSplit.selector); // pool below the 40% floor
        router.proposeSplit(3999, 3001, 3000);
        vm.expectRevert(CreatorFeeRouterV2.BadSplit.selector); // buyback above 40%
        router.proposeSplit(5000, 4001, 999);
        vm.expectRevert(CreatorFeeRouterV2.BadSplit.selector); // ops above 30%
        router.proposeSplit(5000, 1999, 3001);
        vm.expectRevert(CreatorFeeRouterV2.BadSplit.selector); // doesn't sum to 100%
        router.proposeSplit(8000, 1000, 999);
        router.proposeSplit(4000, 3000, 3000); // the edge is fine
        router.proposeSplit(10_000, 0, 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        router.proposeSplit(8000, 1000, 1000);
    }

    function test_timelock_expires() public {
        vm.prank(owner);
        router.proposeSplit(6000, 2000, 2000);
        uint256 eta = _now() + 7 days;
        _wait(7 days + 14 days + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CreatorFeeRouterV2.ProposalExpired.selector, eta + 14 days));
        router.executeSplit();
    }

    function test_timelock_executeOnlyOwner() public {
        vm.prank(owner);
        router.proposeSplit(6000, 2000, 2000);
        _wait(7 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        router.executeSplit();
    }

    function test_cancel_byOwnerOrGuardian() public {
        vm.prank(owner);
        router.proposeSplit(6000, 2000, 2000);
        vm.prank(alice);
        vm.expectRevert(CreatorFeeRouterV2.NotGuardian.selector);
        router.cancel(CreatorFeeRouterV2.Action.Split);

        vm.expectEmit(address(router));
        emit CreatorFeeRouterV2.ChangeCancelled(CreatorFeeRouterV2.Action.Split, guardian);
        vm.prank(guardian);
        router.cancel(CreatorFeeRouterV2.Action.Split);
        _wait(7 days);
        vm.prank(owner);
        vm.expectRevert(CreatorFeeRouterV2.NoPendingChange.selector);
        router.executeSplit();
        vm.prank(owner);
        vm.expectRevert(CreatorFeeRouterV2.NoPendingChange.selector);
        router.cancel(CreatorFeeRouterV2.Action.Split);

        // Every kind can be cancelled.
        CreatorFeeRouterV2.GasWallet[] memory ws = new CreatorFeeRouterV2.GasWallet[](1);
        ws[0] = CreatorFeeRouterV2.GasWallet(relayer, 0.1 ether);
        MockERC20 stray = new MockERC20("Stray", "S");
        vm.startPrank(owner);
        router.proposeTreasury(alice);
        router.proposeBuybackRoute(executor, oracle);
        router.proposeGasConfig(ws, 0.1 ether);
        router.proposeFeeRecipient(alice);
        router.proposeSweepToken(address(stray), alice, 1);
        router.cancel(CreatorFeeRouterV2.Action.Treasury);
        router.cancel(CreatorFeeRouterV2.Action.BuybackRoute);
        router.cancel(CreatorFeeRouterV2.Action.GasConfig);
        router.cancel(CreatorFeeRouterV2.Action.FeeRecipient);
        router.cancel(CreatorFeeRouterV2.Action.SweepToken);
        vm.stopPrank();
        (, uint64 e1) = router.pendingTreasury();
        (,, uint64 e2) = router.pendingRoute();
        (CreatorFeeRouterV2.GasWallet[] memory pw,, uint64 e3) = router.pendingGasConfig();
        (, uint64 e4) = router.pendingFeeRecipient();
        (,,, uint64 e5) = router.pendingSweep();
        assertEq(uint256(e1) + e2 + e3 + e4 + e5, 0);
        assertEq(pw.length, 0);
    }

    function test_newProposalReplacesOld() public {
        vm.prank(owner);
        router.proposeSplit(6000, 2000, 2000);
        _wait(5 days);
        vm.prank(owner);
        router.proposeSplit(7000, 1500, 1500);
        _wait(3 days); // 8 days after the first, 3 after the second
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CreatorFeeRouterV2.TimelockNotElapsed.selector, _now() + 4 days));
        router.executeSplit();
        _wait(4 days);
        vm.prank(owner);
        router.executeSplit();
        (uint16 p,,) = router.split();
        assertEq(p, 7000);
    }

    // ---------------------------------------------------------- treasury, ops

    function test_claimOps_andTreasuryTimelock() public {
        _creditEscrow(10 ether);
        router.harvest();
        vm.expectEmit(address(router));
        emit CreatorFeeRouterV2.OpsClaimed(treasury, 0.4 ether);
        vm.prank(owner);
        router.claimOps(0.4 ether);
        assertEq(treasury.balance, 0.4 ether);
        assertEq(router.opsBalance(), 0.6 ether);

        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        router.proposeTreasury(newTreasury);
        vm.prank(owner);
        router.claimOps(0.1 ether); // still the old treasury
        assertEq(treasury.balance, 0.5 ether);
        _wait(7 days);
        vm.prank(owner);
        router.executeTreasury();
        assertEq(router.treasury(), newTreasury);
        vm.prank(owner);
        router.claimOps(0.5 ether);
        assertEq(newTreasury.balance, 0.5 ether);
        assertEq(_totals().opsPaid, 1 ether);
        _assertBooks();
    }

    function test_claimOps_limits() public {
        _creditEscrow(10 ether);
        router.harvest();
        vm.startPrank(owner);
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.claimOps(0);
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.claimOps(1 ether + 1);
        vm.expectRevert(CreatorFeeRouterV2.ZeroAddress.selector);
        router.proposeTreasury(address(0));
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        router.claimOps(1);
    }

    // ------------------------------------------------------------------ gas

    function test_topUpGas_toTargets() public {
        _creditEscrow(10 ether); // 1 ETH of ops
        router.harvest();
        _setGas(router, 0.5 ether, 0.2 ether, 1 ether);
        vm.deal(relayer, 0.1 ether);
        vm.expectEmit(address(router));
        emit CreatorFeeRouterV2.GasToppedUp(relayer, 0.4 ether);
        vm.expectEmit(address(router));
        emit CreatorFeeRouterV2.GasToppedUp(keeperWallet, 0.2 ether);
        vm.prank(alice); // anyone
        assertEq(router.topUpGas(), 0.6 ether);
        assertEq(relayer.balance, 0.5 ether);
        assertEq(keeperWallet.balance, 0.2 ether);
        assertEq(router.opsBalance(), 0.4 ether);
        assertEq(_totals().gasToppedUp, 0.6 ether);
        // Already full: nothing more.
        assertEq(router.topUpGas(), 0);
        _assertBooks();
    }

    function test_topUpGas_dailyCap() public {
        _creditEscrow(10 ether);
        router.harvest();
        _setGas(router, 0.5 ether, 0.2 ether, 0.3 ether);
        assertEq(router.topUpGas(), 0.3 ether);
        assertEq(relayer.balance, 0.3 ether);
        assertEq(keeperWallet.balance, 0);
        assertEq(router.gasRoom(), 0);
        vm.deal(relayer, 0);
        assertEq(router.topUpGas(), 0); // same period
        _wait(24 hours);
        assertEq(router.gasRoom(), 0.3 ether);
        assertEq(router.topUpGas(), 0.3 ether);
        assertEq(relayer.balance, 0.3 ether);
        _wait(24 hours);
        assertEq(router.topUpGas(), 0.3 ether); // 0.2 to the relayer, 0.1 to the keeper
        assertEq(relayer.balance, 0.5 ether);
        assertEq(keeperWallet.balance, 0.1 ether);
        _assertBooks();
    }

    function test_topUpGas_limitedByOpsBucket() public {
        _creditEscrow(1 ether); // 0.1 ETH of ops
        router.harvest();
        _setGas(router, 0.5 ether, 0.2 ether, 1 ether);
        assertEq(router.topUpGas(), 0.1 ether);
        assertEq(relayer.balance, 0.1 ether);
        assertEq(router.opsBalance(), 0);
        // ETH waiting outside the ops bucket is never used.
        _send(address(router), 5 ether);
        assertEq(router.topUpGas(), 0);
        assertEq(router.unallocated(), 5 ether);
        _assertBooks();
    }

    function test_topUpGas_skipsWalletThatRejects() public {
        _creditEscrow(10 ether);
        router.harvest();
        RejectingWallet bad = new RejectingWallet();
        CreatorFeeRouterV2.GasWallet[] memory ws = new CreatorFeeRouterV2.GasWallet[](2);
        ws[0] = CreatorFeeRouterV2.GasWallet(address(bad), 0.5 ether);
        ws[1] = CreatorFeeRouterV2.GasWallet(keeperWallet, 0.2 ether);
        vm.prank(owner);
        router.proposeGasConfig(ws, 1 ether);
        _wait(7 days);
        vm.prank(owner);
        router.executeGasConfig();
        vm.expectEmit(address(router));
        emit CreatorFeeRouterV2.GasTopUpFailed(address(bad), 0.5 ether);
        assertEq(router.topUpGas(), 0.2 ether);
        assertEq(keeperWallet.balance, 0.2 ether);
        assertEq(router.opsBalance(), 0.8 ether);
        assertEq(router.gasRoom(), 0.8 ether);
        _assertBooks();
    }

    function test_gasConfig_timelockedAndLimited() public {
        _creditEscrow(10 ether);
        router.harvest();
        CreatorFeeRouterV2.GasWallet[] memory ws = new CreatorFeeRouterV2.GasWallet[](1);
        ws[0] = CreatorFeeRouterV2.GasWallet(relayer, 0.5 ether);
        vm.prank(owner);
        router.proposeGasConfig(ws, 0.5 ether);
        (CreatorFeeRouterV2.GasWallet[] memory pw, uint256 cap, uint64 eta) = router.pendingGasConfig();
        assertEq(pw.length, 1);
        assertEq(pw[0].wallet, relayer);
        assertEq(cap, 0.5 ether);
        assertEq(eta, _now() + 7 days);
        assertEq(router.topUpGas(), 0); // not live yet
        _wait(7 days);
        vm.prank(owner);
        router.executeGasConfig();
        assertEq(router.gasWallets().length, 1);
        assertEq(router.gasDailyCap(), 0.5 ether);
        assertEq(router.topUpGas(), 0.5 ether);

        vm.startPrank(owner);
        CreatorFeeRouterV2.GasWallet[] memory nine = new CreatorFeeRouterV2.GasWallet[](9);
        for (uint256 i; i < 9; ++i) {
            nine[i] = CreatorFeeRouterV2.GasWallet(address(uint160(i + 1)), 0.1 ether);
        }
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.proposeGasConfig(nine, 0.1 ether);
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.proposeGasConfig(ws, 1 ether + 1);
        ws[0].target = 1 ether + 1;
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.proposeGasConfig(ws, 0.1 ether);
        ws[0] = CreatorFeeRouterV2.GasWallet(address(0), 0.1 ether);
        vm.expectRevert(CreatorFeeRouterV2.ZeroAddress.selector);
        router.proposeGasConfig(ws, 0.1 ether);
        // An empty list switches top-ups off.
        router.proposeGasConfig(new CreatorFeeRouterV2.GasWallet[](0), 0);
        _wait(7 days);
        router.executeGasConfig();
        vm.stopPrank();
        assertEq(router.gasWallets().length, 0);
    }

    // ------------------------------------------------------- fee recipient

    function test_feeRecipient_migration() public {
        address next = makeAddr("nextRouter");
        vm.prank(owner);
        router.proposeFeeRecipient(next);
        (address v, uint64 eta) = router.pendingFeeRecipient();
        assertEq(v, next);
        assertEq(eta, _now() + 7 days);

        _wait(7 days);
        curve.accrue{value: 1 ether}(); // accrued while we were the recipient
        vm.expectEmit(address(router));
        emit CreatorFeeRouterV2.FeeRecipientTransferred(address(token), next);
        vm.prank(owner);
        router.executeFeeRecipient();

        // What was ours was swept and claimed first.
        assertEq(_totals().claimed, 1 ether);
        assertEq(router.unallocated(), 1 ether);
        assertEq(router.currentFeeRecipient(), next);
        assertEq(curve.deployer(), next);

        // From now on the stream belongs to `next`; our harvest does nothing with it and never reverts.
        curve.accrue{value: 2 ether}();
        assertEq(router.harvest(), 0);
        assertEq(curve.pendingCreatorFees(), 2 ether);
        vm.prank(next);
        curve.sweepFees(0);
        assertEq(escrow.balanceOf(next), 2 ether);
        _assertBooks();
    }

    function test_feeRecipient_migrationAfterGraduation() public {
        factory.graduate(address(token));
        vm.prank(owner);
        router.proposeFeeRecipient(alice);
        _wait(7 days);
        vm.prank(owner);
        router.executeFeeRecipient();
        assertEq(hook.creator(router.poolId()), alice);
    }

    function test_feeRecipient_guards() public {
        vm.startPrank(owner);
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.proposeFeeRecipient(address(0));
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.proposeFeeRecipient(address(router));
        vm.expectRevert(CreatorFeeRouterV2.NoPendingChange.selector);
        router.executeFeeRecipient();
        vm.stopPrank();

        CreatorFeeRouterV2 r = _newRouter(address(0));
        vm.prank(owner);
        vm.expectRevert(CreatorFeeRouterV2.TokenNotSet.selector);
        r.proposeFeeRecipient(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        router.proposeFeeRecipient(alice);
    }

    // ------------------------------------------------------------ sweepToken

    function test_sweepToken_timelocked() public {
        MockERC20 stray = new MockERC20("Stray", "S");
        stray.mint(address(router), 100);
        vm.prank(owner);
        router.proposeSweepToken(address(stray), alice, 60);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CreatorFeeRouterV2.TimelockNotElapsed.selector, _now() + 7 days));
        router.sweepToken(address(stray), alice, 60);
        _wait(7 days);
        vm.startPrank(owner);
        vm.expectRevert(CreatorFeeRouterV2.ProposalMismatch.selector);
        router.sweepToken(address(stray), alice, 61);
        vm.expectRevert(CreatorFeeRouterV2.ProposalMismatch.selector);
        router.sweepToken(address(stray), owner, 60);
        router.sweepToken(address(stray), alice, 60);
        vm.stopPrank();
        assertEq(stray.balanceOf(alice), 60);
        assertEq(stray.balanceOf(address(router)), 40);
        vm.prank(owner);
        vm.expectRevert(CreatorFeeRouterV2.NoPendingChange.selector);
        router.sweepToken(address(stray), alice, 60);
    }

    function test_sweepToken_neverThePlatformToken() public {
        vm.prank(owner);
        vm.expectRevert(CreatorFeeRouterV2.PlatformToken.selector);
        router.proposeSweepToken(address(token), alice, 1);
    }

    function test_sweepToken_rechecksIfTokenSetAfterProposal() public {
        CreatorFeeRouterV2 r = _newRouter(address(0));
        MockERC20 later = new MockERC20("Later", "L");
        later.mint(address(r), 1);
        vm.prank(owner);
        r.proposeSweepToken(address(later), alice, 1);
        factory.launch(address(later), new MockBondingCurve(escrow, address(factory), ponsOperator), address(r), 500);
        vm.prank(owner);
        r.setToken(address(later));
        _wait(7 days);
        vm.prank(owner);
        vm.expectRevert(CreatorFeeRouterV2.PlatformToken.selector);
        r.sweepToken(address(later), alice, 1);
    }

    // -------------------------------------------------------------- buyback

    function test_buyback_happyPath_toDistributor() public {
        _readyBuyback();
        uint256 ethIn = 0.1 ether;
        uint256 out = (_fair(ethIn) * 9400) / BPS;
        uint256 floor = (_fair(ethIn) * 9200) / BPS;
        assertEq(router.floorOut(ethIn), floor);
        assertEq(router.buybackCap(), 0.1 ether);

        vm.expectEmit(address(router));
        emit CreatorFeeRouterV2.BoughtBack(ethIn, out, floor, TICK, distributor);
        vm.prank(alice); // anyone
        assertEq(router.buyback(ethIn, 0), out);

        assertEq(token.balanceOf(distributor), out);
        assertEq(executor.lastMinOut(), floor); // the floor overrides minOut = 0
        assertEq(executor.lastTo(), distributor);
        assertEq(router.buybackBalance(), 0.9 ether);
        assertEq(address(executor).balance, ethIn);
        assertEq(router.lastBuybackAt(), _now());
        CreatorFeeRouterV2.Totals memory t = _totals();
        assertEq(t.buybackEth, ethIn);
        assertEq(t.tokensToSink, out);
        _assertBooks();
    }

    function test_buyback_burnsAfterDistributeUntil() public {
        _readyBuyback();
        vm.warp(distributeUntil);
        assertEq(router.sink(), DEAD);
        router.buyback(0.1 ether, 0);
        assertEq(token.balanceOf(DEAD), (_fair(0.1 ether) * 9400) / BPS);
        assertEq(token.balanceOf(distributor), 0);
    }

    function test_buyback_burnOnlyWithoutDistributor() public {
        CreatorFeeRouterV2 r = _newRouter(address(0));
        assertEq(r.sink(), DEAD);
    }

    function test_buyback_notBeforeStart() public {
        // Route set before the token, so only the 24-hour start delay is left.
        CreatorFeeRouterV2 r = _newRouter(address(0));
        MockERC20 t2 = new MockERC20("T2", "T2");
        factory.launch(address(t2), new MockBondingCurve(escrow, address(factory), ponsOperator), address(r), 500);
        _setRoute(r);
        escrow.credit{value: 10 ether}(address(r));
        r.harvest();
        vm.prank(owner);
        r.setToken(address(t2));
        uint256 start = _now() + 24 hours;
        assertEq(r.nextBuybackAt(), start);
        vm.expectRevert(abi.encodeWithSelector(CreatorFeeRouterV2.BuybackNotStarted.selector, start));
        r.buyback(0.1 ether, 0);
        _wait(24 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(CreatorFeeRouterV2.BuybackNotStarted.selector, start));
        r.buyback(0.1 ether, 0);
        _wait(1);
        r.buyback(0.1 ether, 0);
        assertEq(t2.balanceOf(DEAD), (_fair(0.1 ether) * 9400) / BPS);
    }

    function test_buyback_needsTokenAndRoute() public {
        _creditEscrow(10 ether);
        router.harvest();
        _wait(24 hours);
        vm.expectRevert(CreatorFeeRouterV2.BuybackNotReady.selector);
        router.buyback(0.1 ether, 0);
        // Proposed but not yet executed: still not ready.
        vm.prank(owner);
        router.proposeBuybackRoute(executor, oracle);
        vm.expectRevert(CreatorFeeRouterV2.BuybackNotReady.selector);
        router.buyback(0.1 ether, 0);

        CreatorFeeRouterV2 r = _newRouter(address(0));
        vm.expectRevert(CreatorFeeRouterV2.TokenNotSet.selector);
        r.buyback(0.1 ether, 0);
    }

    function test_buyback_paused() public {
        _readyBuyback();
        vm.prank(guardian);
        router.setPaused(false, true);
        vm.expectRevert(CreatorFeeRouterV2.BuybackPaused.selector);
        router.buyback(0.1 ether, 0);
        // Allocation keeps running.
        _creditEscrow(1 ether);
        assertEq(router.harvest(), 1 ether);
        assertEq(router.buybackBalance(), 1.1 ether);
    }

    function test_buyback_spacing() public {
        _readyBuyback();
        router.buyback(0.1 ether, 0);
        uint256 next = _now() + 10 minutes;
        assertEq(router.nextBuybackAt(), next);
        _wait(10 minutes - 1);
        vm.expectRevert(abi.encodeWithSelector(CreatorFeeRouterV2.TooSoon.selector, next));
        router.buyback(0.1 ether, 0);
        _wait(1);
        router.buyback(0.1 ether, 0);
        assertEq(router.buybackBalance(), 0.8 ether);
    }

    function test_buyback_sizeCaps() public {
        _readyBuyback();
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.buyback(0, 0);
        // maxPerCall
        vm.expectRevert(abi.encodeWithSelector(CreatorFeeRouterV2.TooLarge.selector, 0.1 ether));
        router.buyback(0.1 ether + 1, 0);
        // 1% of the pool's ETH depth
        vm.prank(owner);
        router.setBuybackParams(1 ether, 10 minutes, 100, 200, 1000, 700);
        oracle.setLiquidity(5 ether);
        assertEq(router.buybackCap(), 0.05 ether);
        vm.expectRevert(abi.encodeWithSelector(CreatorFeeRouterV2.TooLarge.selector, 0.05 ether));
        router.buyback(0.05 ether + 1, 0);
        // the bucket
        oracle.setLiquidity(1000 ether);
        assertEq(router.buybackCap(), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(CreatorFeeRouterV2.TooLarge.selector, 1 ether));
        router.buyback(1 ether + 1, 0);
        // no depth at all
        oracle.setLiquidity(0);
        vm.expectRevert(abi.encodeWithSelector(CreatorFeeRouterV2.TooLarge.selector, 0));
        router.buyback(1, 0);
        oracle.setLiquidity(1000 ether);
        router.buyback(1 ether, 0);
        assertEq(router.buybackBalance(), 0);
        _assertBooks();
    }

    function test_buyback_priceGuards() public {
        _readyBuyback();
        // Live price 201 ticks off the fast average.
        oracle.set(TICK + 201, TICK, TICK);
        vm.expectRevert(abi.encodeWithSelector(CreatorFeeRouterV2.PriceUnstable.selector, int256(TICK + 201), int256(TICK)));
        router.buyback(0.01 ether, 0);
        oracle.set(TICK - 201, TICK, TICK);
        vm.expectRevert(abi.encodeWithSelector(CreatorFeeRouterV2.PriceUnstable.selector, int256(TICK - 201), int256(TICK)));
        router.buyback(0.01 ether, 0);
        // Fast average pumped 1001 ticks above the slow one.
        oracle.set(TICK + 1001, TICK + 1001, TICK);
        vm.expectRevert(
            abi.encodeWithSelector(CreatorFeeRouterV2.PriceTooHigh.selector, int256(TICK + 1001), int256(TICK))
        );
        router.buyback(0.01 ether, 0);
        // Right at the limits it goes through.
        oracle.set(TICK + 1000 + 200, TICK + 1000, TICK);
        executor.setRate(TickRatio.ratio(-int256(TICK + 1000)));
        router.buyback(0.01 ether, 0);
        // Buying after a dump (fast far below slow) is allowed.
        _wait(10 minutes);
        oracle.set(TICK - 5000, TICK - 5000, TICK);
        executor.setRate(TickRatio.ratio(-int256(TICK - 5000)));
        router.buyback(0.01 ether, 0);
        _assertBooks();
    }

    function test_buyback_floorFromFastPrice() public {
        _readyBuyback();
        // An executor that ignores minOut and delivers 91.99% of fair: below the 92% floor.
        executor.setMode(MockBuybackExecutor.Mode.IgnoreMin);
        executor.setDeliverBps(9199);
        uint256 floor = (_fair(0.1 ether) * 9200) / BPS;
        vm.expectRevert(
            abi.encodeWithSelector(CreatorFeeRouterV2.NotEnoughOut.selector, (_fair(0.1 ether) * 9199) / BPS, floor)
        );
        router.buyback(0.1 ether, 0);
        executor.setDeliverBps(9200);
        router.buyback(0.1 ether, 0);
        _assertBooks();
    }

    function test_buyback_callerMinOutAboveFloor() public {
        _readyBuyback();
        uint256 out = (_fair(0.1 ether) * 9400) / BPS;
        vm.expectRevert("min out");
        router.buyback(0.1 ether, out + 1);
        router.buyback(0.1 ether, out);
        assertEq(executor.lastMinOut(), out);
    }

    function test_buyback_distrustsExecutorReport() public {
        _readyBuyback();
        executor.setMode(MockBuybackExecutor.Mode.Lie);
        executor.setDeliverBps(5000); // delivers half but reports the floor
        uint256 floor = (_fair(0.1 ether) * 9200) / BPS;
        vm.expectRevert(
            abi.encodeWithSelector(CreatorFeeRouterV2.NotEnoughOut.selector, (_fair(0.1 ether) * 5000) / BPS, floor)
        );
        router.buyback(0.1 ether, 0);
    }

    function test_buyback_refundReturnsToBucket() public {
        _readyBuyback();
        executor.setSpendBps(6000); // a better fill: 40% of the ETH comes back
        router.buyback(0.1 ether, 0);
        assertEq(router.buybackBalance(), 1 ether - 0.06 ether);
        assertEq(_totals().buybackEth, 0.06 ether);
        assertEq(router.unallocated(), 0);
        _assertBooks();
    }

    function test_buyback_reentryBlocked() public {
        _readyBuyback();
        executor.setMode(MockBuybackExecutor.Mode.Reenter);
        executor.setReenter(address(router), abi.encodeCall(CreatorFeeRouterV2.harvest, ()));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        router.buyback(0.1 ether, 0);
        executor.setReenter(address(router), abi.encodeCall(CreatorFeeRouterV2.buyback, (0.1 ether, 0)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        router.buyback(0.1 ether, 0);
        executor.setReenter(address(router), abi.encodeCall(CreatorFeeRouterV2.topUpGas, ()));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        router.buyback(0.1 ether, 0);
    }

    function test_buyback_oracleDown() public {
        _readyBuyback();
        oracle.setFailing(true);
        vm.expectRevert("feed down");
        router.buyback(0.1 ether, 0);
    }

    function test_buybackParams_hardLimits() public {
        vm.startPrank(owner);
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.setBuybackParams(1 ether + 1, 10 minutes, 100, 200, 1000, 700);
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.setBuybackParams(1 ether, 59, 100, 200, 1000, 700);
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.setBuybackParams(1 ether, 1 days + 1, 100, 200, 1000, 700);
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.setBuybackParams(1 ether, 10 minutes, 501, 200, 1000, 700);
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.setBuybackParams(1 ether, 10 minutes, 100, 1001, 1000, 700);
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.setBuybackParams(1 ether, 10 minutes, 100, 200, 5001, 700);
        vm.expectRevert(CreatorFeeRouterV2.BadValue.selector);
        router.setBuybackParams(1 ether, 10 minutes, 100, 200, 1000, 2001);
        router.setBuybackParams(1 ether, 1 minutes, 500, 1000, 5000, 2000);
        vm.stopPrank();
        assertEq(router.maxPerCall(), 1 ether);
        assertEq(router.minInterval(), 1 minutes);
        assertEq(router.maxDepthBps(), 500);
        assertEq(router.feeAndSlipBps(), 2000);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        router.setBuybackParams(0.1 ether, 10 minutes, 100, 200, 1000, 700);
    }

    function test_buybackRoute_canBeSwitchedOff() public {
        _readyBuyback();
        vm.prank(owner);
        router.proposeBuybackRoute(IBuybackExecutor(address(0)), IPriceOracle(address(0)));
        _wait(7 days);
        vm.prank(owner);
        router.executeBuybackRoute();
        vm.expectRevert(CreatorFeeRouterV2.BuybackNotReady.selector);
        router.buyback(0.1 ether, 0);
        assertEq(router.buybackCap(), 0);
        assertEq(router.floorOut(1 ether), 0);
    }

    // --------------------------------------------------------------- pausing

    function test_pause_roles() public {
        vm.prank(alice);
        vm.expectRevert(CreatorFeeRouterV2.NotGuardian.selector);
        router.setPaused(true, true);

        vm.prank(guardian);
        router.setPaused(true, true);
        assertTrue(router.allocatePaused());
        assertTrue(router.buybackPaused());
        vm.prank(guardian);
        vm.expectRevert(CreatorFeeRouterV2.OnlyOwnerUnpauses.selector);
        router.setPaused(false, true);
        vm.prank(guardian);
        router.setPaused(true, true); // no-op is fine

        vm.prank(owner);
        router.setPaused(false, false);
        assertFalse(router.allocatePaused());
        assertFalse(router.buybackPaused());

        vm.prank(owner);
        router.setGuardian(alice);
        vm.prank(guardian);
        vm.expectRevert(CreatorFeeRouterV2.NotGuardian.selector);
        router.setPaused(true, true);
    }

    function test_pause_neverMovesFunds() public {
        _creditEscrow(10 ether);
        router.harvest();
        _send(address(router), 1 ether);
        uint256 bal = address(router).balance;
        uint256 poolCash = pool.cash();
        vm.prank(guardian);
        router.setPaused(true, true);
        assertEq(address(router).balance, bal);
        assertEq(pool.cash(), poolCash);
        assertEq(router.buybackBalance(), 1 ether);
        assertEq(router.opsBalance(), 1 ether);
        assertEq(router.unallocated(), 1 ether);
        // Ops keep working while paused.
        _setGas(router, 0.1 ether, 0, 1 ether);
        assertEq(router.topUpGas(), 0.1 ether);
        vm.prank(owner);
        router.claimOps(0.1 ether);
        _assertBooks();
    }

    // ----------------------------------------------------------------- views

    function test_views_forDashboard() public {
        _creditEscrow(10 ether);
        router.harvest();
        _send(address(router), 0.5 ether);
        (uint256 u, uint256 b, uint256 o) = router.buckets();
        assertEq(u, 0.5 ether);
        assertEq(b, 1 ether);
        assertEq(o, 1 ether);
        assertEq(router.gasRoom(), 0);
        assertEq(router.nextBuybackAt(), router.buybackStart());
        assertEq(router.currentFeeRecipient(), address(router));
        assertEq(router.TIMELOCK(), 7 days);
        assertEq(router.BURN(), DEAD);

        CreatorFeeRouterV2 r = _newRouter(address(0));
        assertEq(r.currentFeeRecipient(), address(0));
        assertEq(r.nextBuybackAt(), 0);
    }
}

// =====================================================================================================================
// Invariant: the router's ETH always covers its buckets, and every wei that came in is in exactly one place.
// =====================================================================================================================

contract RouterHandler is Test {
    CreatorFeeRouterV2 internal router;
    MockFeeEscrow internal escrow;
    MockBondingCurve internal curve;
    MockMemeHook internal hook;
    MockLaunchFactory internal factory;
    MockBuybackExecutor internal executor;
    address internal owner;
    address internal token;
    address[2] internal wallets;

    uint256 public ghostDirect;
    uint256 public ghostGas;
    uint256 public calls;
    uint256 public buybacks;
    uint256 public topUps;

    constructor(
        CreatorFeeRouterV2 router_,
        MockFeeEscrow escrow_,
        MockBondingCurve curve_,
        MockMemeHook hook_,
        MockLaunchFactory factory_,
        MockBuybackExecutor executor_,
        address owner_,
        address token_,
        address[2] memory wallets_
    ) {
        router = router_;
        escrow = escrow_;
        curve = curve_;
        hook = hook_;
        factory = factory_;
        executor = executor_;
        owner = owner_;
        token = token_;
        wallets = wallets_;
        vm.deal(address(this), 1e30);
    }

    function accrueFees(uint256 amount) external {
        amount = bound(amount, 0, 50 ether);
        if (curve.graduated()) hook.accrue{value: amount}(router.poolId());
        else curve.accrue{value: amount}();
        calls++;
    }

    function creditEscrow(uint256 amount) external {
        escrow.credit{value: bound(amount, 0, 50 ether)}(address(router));
        calls++;
    }

    function sendDirect(uint256 amount) external {
        amount = bound(amount, 0, 10 ether);
        (bool ok,) = address(router).call{value: amount}("");
        require(ok);
        ghostDirect += amount;
        calls++;
    }

    function setEscrowMode(uint8 mode) external {
        escrow.setMode(MockFeeEscrow.PayMode(bound(mode, 0, 2)));
    }

    function graduate() external {
        if (!curve.graduated()) factory.graduate(token);
    }

    function harvest() external {
        router.harvest();
        calls++;
    }

    function allocate() external {
        if (router.allocatePaused()) return;
        router.allocate();
        calls++;
    }

    function buyback(uint256 ethIn, uint16 spendBps) external {
        if (router.buybackPaused()) return;
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256 cap = router.buybackCap();
        if (cap == 0) return;
        executor.setSpendBps(uint16(bound(spendBps, 1, 10_000)));
        router.buyback(bound(ethIn, 1, cap), 0);
        buybacks++;
        calls++;
    }

    function spendGas(uint256 seed) external {
        address w = wallets[seed % 2];
        vm.deal(w, w.balance / 2);
    }

    function topUpGas() external {
        uint256 before = wallets[0].balance + wallets[1].balance;
        if (router.topUpGas() != 0) topUps++;
        ghostGas += wallets[0].balance + wallets[1].balance - before;
        calls++;
    }

    function claimOps(uint256 amount) external {
        uint256 ops = router.opsBalance();
        if (ops == 0) return;
        vm.prank(owner);
        router.claimOps(bound(amount, 1, ops));
        calls++;
    }

    /// @dev Pauses one time in eight, otherwise unpauses, so most of a run has live buybacks.
    function setPaused(uint8 seed) external {
        vm.prank(owner);
        if (seed % 8 == 0) router.setPaused(seed & 16 != 0, seed & 32 != 0);
        else router.setPaused(false, false);
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 3 days));
    }
}

contract CreatorFeeRouterV2InvariantTest is RouterFixture {
    RouterHandler internal handler;
    uint256 internal donatedBefore;

    function setUp() public override {
        super.setUp();
        _setRoute(router);
        _setGas(router, 0.3 ether, 0.1 ether, 0.25 ether);
        handler = new RouterHandler(
            router, escrow, curve, hook, factory, executor, owner, address(token), [relayer, keeperWallet]
        );
        donatedBefore = pool.totalDonated();
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_routerBooks() public view {
        CreatorFeeRouterV2.Totals memory t = _totals();
        uint256 bal = address(router).balance;
        uint256 bb = router.buybackBalance();
        uint256 ops = router.opsBalance();
        // The ETH held always covers both buckets.
        assertGe(bal, bb + ops, "solvent");
        assertEq(bal, router.unallocated() + bb + ops, "held = unallocated + buckets");
        // Every wei allocated went to exactly one of pool, buyback or ops...
        assertEq(t.allocated, t.donated + t.toBuyback + t.toOps, "split");
        // ...and stays in its bucket until it is spent from that bucket.
        assertEq(t.toBuyback, bb + t.buybackEth, "buyback bucket");
        assertEq(t.toOps, ops + t.opsPaid + t.gasToppedUp, "ops bucket");
        // Every wei claimed (or sent here) is either allocated or still waiting.
        assertEq(t.claimed, escrow.paidTo(address(router)), "claimed = escrow payouts");
        assertEq(t.claimed + handler.ghostDirect(), t.allocated + router.unallocated(), "nothing lost");
        // Outflows land where the books say.
        assertEq(pool.totalDonated() - donatedBefore, t.donated, "pool donations");
        assertEq(treasury.balance, t.opsPaid, "treasury");
        assertEq(handler.ghostGas(), t.gasToppedUp, "gas wallets");
        assertEq(token.balanceOf(distributor) + token.balanceOf(DEAD), t.tokensToSink, "tokens to sink");
    }
}
