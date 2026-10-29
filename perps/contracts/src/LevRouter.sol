// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";
import {LevLogic} from "./libraries/LevLogic.sol";
import {Config} from "./LevTypes.sol";

interface ILevExchangeForRouter {
    function depositFor(address user) external payable;
    function openFor(address trader, uint256 marketId, bool isLong, uint8 leverage, uint256 stake, int24 limitTick, uint256 maxSlipTicks)
        external
        returns (uint256);
    function closeFor(address trader, uint256 id, int24 limitTick, uint256 maxSlipTicks) external;
    function withdrawFor(address trader, uint256 amount) external;
    function openStakeOf(address trader) external view returns (uint256);
    function getConfig() external view returns (Config memory);
}

/// @title LevRouter
/// @notice One-click trading. A trader approves a session key once (one wallet transaction, usually together with
///         the deposit). After that, every trade is a typed message signed by that key in the browser: no wallet
///         pop-up and no gas. Anyone may submit a signed trade (our relayer pays the gas), so if the relayer is
///         down a backup relayer or the trader can submit it too.
/// @dev Session keys are P-256 keys (WebCrypto, created non-extractable in the browser), verified with
///      OpenZeppelin's P256 (the RIP-7212 precompile when the chain has it). The key signs SHA-256 of the EIP-712
///      digest, which is what WebCrypto's ECDSA does with the digest as the message.
///      What a stolen session key can do is bounded by the limits the owner set: it can only open and close
///      positions within those limits, at fills within a slippage bound of the fast price, and withdraw to the
///      owner's own address. It can never move funds anywhere else.
contract LevRouter is EIP712, Ownable2Step {
    uint8 public constant ACT_OPEN = 1;
    uint8 public constant ACT_CLOSE_OWN = 2; // close positions this session opened
    uint8 public constant ACT_CLOSE_ANY = 4; // close any of the owner's positions
    uint8 public constant ACT_WITHDRAW = 8; // withdraw to the owner's own address
    uint8 internal constant ALL_ACTIONS = 15;

    uint8 public constant KIND_OPEN = 1;
    uint8 public constant KIND_CLOSE = 2;
    uint8 public constant KIND_WITHDRAW = 3;

    uint64 public constant MAX_SESSION = 7 days;
    uint64 public constant MAX_DEADLINE_AHEAD = 120;
    uint16 public constant MAX_SLIP_TICKS = 3000; // about 30%

    bytes32 public constant OPEN_TYPEHASH = keccak256(
        "Open(address owner,bytes32 key,uint32 generation,uint32 marketId,bool isLong,uint8 leverage,uint96 stake,int24 limitTick,uint256 nonce,uint64 deadline)"
    );
    bytes32 public constant CLOSE_TYPEHASH = keccak256(
        "Close(address owner,bytes32 key,uint32 generation,uint256 positionId,int24 limitTick,uint256 nonce,uint64 deadline)"
    );
    bytes32 public constant WITHDRAW_TYPEHASH =
        keccak256("Withdraw(address owner,bytes32 key,uint32 generation,uint256 amount,uint256 nonce,uint64 deadline)");
    bytes32 public constant REVOKE_TYPEHASH =
        keccak256("Revoke(address owner,bytes32 key,uint32 generation,uint256 nonce,uint64 deadline)");

    struct Limits {
        uint64 expiry;
        uint8 actions; // ACT_* bits
        uint8 maxLeverage;
        uint16 openSlipTicks; // an open may fill at most this far (1 tick ~ 0.01%) worse than the fast price
        uint16 closeSlipTicks; // same for closes
        uint96 maxStakePerTrade;
        uint96 maxOpenStake; // across all the owner's open positions
        uint96 dailyBudget; // stake plus open fees this key may commit per rolling day; bounds what a stolen key can lose
    }

    struct Session {
        bytes32 qx;
        bytes32 qy;
        Limits limits;
        uint32 epoch;
        uint32 generation;
        uint64 dayStart; // when spentToday was last updated
        uint96 spentToday; // budget in use; it frees up linearly over a day
        bool active;
    }

    struct OpenIntent {
        address owner;
        bytes32 key;
        uint32 generation;
        uint32 marketId;
        bool isLong;
        uint8 leverage;
        uint96 stake;
        int24 limitTick;
        uint256 nonce;
        uint64 deadline;
    }

    struct CloseIntent {
        address owner;
        bytes32 key;
        uint32 generation;
        uint256 positionId;
        int24 limitTick; // worst acceptable exit: longs revert below it, shorts above it
        uint256 nonce;
        uint64 deadline;
    }

    struct WithdrawIntent {
        address owner;
        bytes32 key;
        uint32 generation;
        uint256 amount;
        uint256 nonce;
        uint64 deadline;
    }

    struct RevokeIntent {
        address owner;
        bytes32 key;
        uint32 generation;
        uint256 nonce;
        uint64 deadline;
    }

    ILevExchangeForRouter public immutable exchange;
    address public guardian;
    bool public paused;

    mapping(address => mapping(bytes32 => Session)) internal _sessions;
    mapping(address => uint32) public epochOf;
    mapping(address => uint32) public generationOf;
    mapping(address => mapping(uint256 => bool)) public nonceUsed;
    mapping(uint256 => bytes32) public openedBy; // position id => session key that opened it
    /// @notice Bumped by the guardian or owner to void every session at once, e.g. after a web-app compromise.
    uint32 public globalEpoch;
    mapping(address => mapping(bytes32 => uint32)) public sessionGlobalEpoch;

    event SessionAuthorized(address indexed owner, bytes32 indexed key, uint32 generation, bytes32 qx, bytes32 qy, Limits limits);
    event SessionRevoked(address indexed owner, bytes32 indexed key);
    event AllSessionsRevoked(address indexed owner, uint32 epoch);
    event NonceCancelled(address indexed owner, uint256 nonce);
    event IntentExecuted(
        address indexed owner, bytes32 indexed key, uint256 nonce, uint8 kind, uint256 positionIdOrAmount, address submitter
    );
    event PausedSet(bool paused);
    event EverySessionRevoked(uint32 globalEpoch);

    error Paused();
    error BadLimits();
    error BadKey();
    error BadDeadline();
    error SessionInvalid();
    error NotAllowed();
    error NonceUsed();
    error BadSignature();
    error OverLimit();
    error Unauthorized();

    constructor(ILevExchangeForRouter exchange_, address owner_) EIP712("MemeLev", "1") Ownable(owner_) {
        exchange = exchange_;
    }

    // ---------------------------------------------------------- owner actions

    /// @notice Approve a session key, optionally depositing ETH in the same transaction. Re-approving a key
    ///         gives it a new generation, so intents it signed before can't come back.
    function authorize(bytes32 qx, bytes32 qy, Limits calldata limits) external payable returns (bytes32 key) {
        if (paused) revert Paused();
        _checkLimits(limits);
        if (!P256.isValidPublicKey(qx, qy)) revert BadKey();
        if (msg.value > 0) exchange.depositFor{value: msg.value}(msg.sender);
        key = keccak256(abi.encode(qx, qy));
        uint32 generation = ++generationOf[msg.sender];
        _sessions[msg.sender][key] = Session({
            qx: qx,
            qy: qy,
            limits: limits,
            epoch: epochOf[msg.sender],
            generation: generation,
            dayStart: uint64(block.timestamp),
            spentToday: 0,
            active: true
        });
        sessionGlobalEpoch[msg.sender][key] = globalEpoch;
        emit SessionAuthorized(msg.sender, key, generation, qx, qy, limits);
    }

    function revoke(bytes32 key) external {
        delete _sessions[msg.sender][key];
        emit SessionRevoked(msg.sender, key);
    }

    /// @notice Kill every session key and every intent they signed that hasn't run yet.
    function revokeAll() external {
        uint32 epoch = ++epochOf[msg.sender];
        emit AllSessionsRevoked(msg.sender, epoch);
    }

    function cancelNonce(uint256 nonce) external {
        nonceUsed[msg.sender][nonce] = true;
        emit NonceCancelled(msg.sender, nonce);
    }

    // ------------------------------------------------- signed by a session key

    function open(OpenIntent calldata o, bytes32 r, bytes32 s) external returns (uint256 id) {
        Session storage ss = _use(o.owner, o.key, o.generation, o.nonce, o.deadline, hashOpen(o), r, s, false);
        Limits memory l = ss.limits;
        if (l.actions & ACT_OPEN == 0) revert NotAllowed();
        if (o.leverage > l.maxLeverage || o.stake > l.maxStakePerTrade) revert OverLimit();
        if (exchange.openStakeOf(o.owner) + o.stake > l.maxOpenStake) revert OverLimit();
        // The budget counts the open fee too, and frees up linearly over a day (no reset to exploit).
        uint256 cost = uint256(o.stake) + LevLogic.tradeFee(exchange.getConfig(), o.stake, uint256(o.stake) * o.leverage);
        uint256 used = ss.spentToday;
        uint256 freed = ((block.timestamp - ss.dayStart) * uint256(l.dailyBudget)) / 1 days;
        used = used > freed ? used - freed : 0;
        if (used + cost > l.dailyBudget) revert OverLimit();
        ss.spentToday = uint96(used + cost);
        ss.dayStart = uint64(block.timestamp);
        id = exchange.openFor(o.owner, o.marketId, o.isLong, o.leverage, o.stake, o.limitTick, l.openSlipTicks);
        openedBy[id] = o.key;
        emit IntentExecuted(o.owner, o.key, o.nonce, KIND_OPEN, id, msg.sender);
    }

    /// @dev A close intent names one position id, and ids are never reused.
    function close(CloseIntent calldata c, bytes32 r, bytes32 s) external {
        Session storage ss = _use(c.owner, c.key, c.generation, c.nonce, c.deadline, hashClose(c), r, s, false);
        uint8 actions = ss.limits.actions;
        bool mine = openedBy[c.positionId] == c.key;
        if (actions & ACT_CLOSE_ANY == 0 && !(mine && actions & ACT_CLOSE_OWN != 0)) revert NotAllowed();
        exchange.closeFor(c.owner, c.positionId, c.limitTick, ss.limits.closeSlipTicks);
        emit IntentExecuted(c.owner, c.key, c.nonce, KIND_CLOSE, c.positionId, msg.sender);
    }

    /// @notice Gas-free way out: always pays the owner's own address.
    function withdraw(WithdrawIntent calldata w, bytes32 r, bytes32 s) external {
        Session storage ss = _use(w.owner, w.key, w.generation, w.nonce, w.deadline, hashWithdraw(w), r, s, false);
        if (ss.limits.actions & ACT_WITHDRAW == 0) revert NotAllowed();
        exchange.withdrawFor(w.owner, w.amount);
        emit IntentExecuted(w.owner, w.key, w.nonce, KIND_WITHDRAW, w.amount, msg.sender);
    }

    /// @notice A session key revoking itself, e.g. on logout. Gas-free through the relayer, and allowed while
    ///         paused: removing a session is always safe.
    function revokeBySig(RevokeIntent calldata v, bytes32 r, bytes32 s) external {
        _use(v.owner, v.key, v.generation, v.nonce, v.deadline, hashRevoke(v), r, s, true);
        delete _sessions[v.owner][v.key];
        emit SessionRevoked(v.owner, v.key);
    }

    // ------------------------------------------------------------------ admin

    /// @notice Stop every signed-intent path at once, e.g. if the web app is compromised. Direct trading on
    ///         LevExchange keeps working.
    /// @dev The guardian can pause; only the owner can unpause.
    function setPaused(bool paused_) external {
        if (msg.sender != owner() && !(msg.sender == guardian && paused_)) revert Unauthorized();
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Void every session of every trader. They re-approve with one wallet transaction.
    function revokeEverySession() external {
        if (msg.sender != owner() && msg.sender != guardian) revert Unauthorized();
        uint32 e = ++globalEpoch;
        emit EverySessionRevoked(e);
    }

    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;
    }

    // ------------------------------------------------------------------ views

    function sessionOf(address owner, bytes32 key) external view returns (Session memory s, bool live) {
        s = _sessions[owner][key];
        live = s.active && s.epoch == epochOf[owner] && sessionGlobalEpoch[owner][key] == globalEpoch
            && block.timestamp <= s.limits.expiry && !paused;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function hashOpen(OpenIntent calldata o) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    OPEN_TYPEHASH,
                    o.owner,
                    o.key,
                    o.generation,
                    o.marketId,
                    o.isLong,
                    o.leverage,
                    o.stake,
                    o.limitTick,
                    o.nonce,
                    o.deadline
                )
            )
        );
    }

    function hashClose(CloseIntent calldata c) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(CLOSE_TYPEHASH, c.owner, c.key, c.generation, c.positionId, c.limitTick, c.nonce, c.deadline)
            )
        );
    }

    function hashWithdraw(WithdrawIntent calldata w) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(WITHDRAW_TYPEHASH, w.owner, w.key, w.generation, w.amount, w.nonce, w.deadline))
        );
    }

    function hashRevoke(RevokeIntent calldata v) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(REVOKE_TYPEHASH, v.owner, v.key, v.generation, v.nonce, v.deadline)));
    }

    // --------------------------------------------------------------- internal

    function _use(
        address owner,
        bytes32 key,
        uint32 generation,
        uint256 nonce,
        uint64 deadline,
        bytes32 digest,
        bytes32 r,
        bytes32 s,
        bool allowWhilePaused
    ) internal returns (Session storage ss) {
        if (paused && !allowWhilePaused) revert Paused();
        if (block.timestamp > deadline || deadline > block.timestamp + MAX_DEADLINE_AHEAD) revert BadDeadline();
        ss = _sessions[owner][key];
        if (
            !ss.active || ss.generation != generation || ss.epoch != epochOf[owner]
                || sessionGlobalEpoch[owner][key] != globalEpoch || block.timestamp > ss.limits.expiry
        ) {
            revert SessionInvalid();
        }
        if (nonceUsed[owner][nonce]) revert NonceUsed();
        nonceUsed[owner][nonce] = true;
        if (!P256.verify(sha256(abi.encodePacked(digest)), r, s, ss.qx, ss.qy)) revert BadSignature();
    }

    function _checkLimits(Limits calldata l) internal view {
        bool bad = l.expiry <= block.timestamp || l.expiry > block.timestamp + MAX_SESSION || l.actions == 0
            || l.actions > ALL_ACTIONS || l.maxLeverage == 0 || l.maxLeverage > 10 || l.openSlipTicks > MAX_SLIP_TICKS
            || l.closeSlipTicks > MAX_SLIP_TICKS || (l.actions & ACT_OPEN != 0 && l.dailyBudget == 0);
        if (bad) revert BadLimits();
    }
}
