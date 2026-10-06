// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeTransfer} from "./lib/SafeTransfer.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

interface IPadFlush {
    function flush(address token) external;
}

/// @title PadToken (PepesFamily v4)
/// @notice Fixed-supply ERC20 launched by PepesFamily, paired with IMD. Holders earn a pro-rata share of the 3%
///         holder fee charged on every Uniswap v4 swap of this token, paid in IMD and claimed manually.
///
///         Rewards are meant to be claimed: a wallet is active when it claims, buys (any amount, through any
///         router: the pad's hook records the buyer), sends tokens, pulls tokens itself, receives tokens for the
///         first time, or is sent at least a tenth of what it already holds. Rewards of a wallet inactive for more
///         than 7 days expire, except what it earned during those last 7 days. Anyone may send expired rewards to
///         `buyback` (PepesBuyback), which can only spend them buying $Pepes and burning it.
/// @dev Dividends use the "magnified dividend per share" pattern: accrual is O(1) and automatic for every
///      holder on each distribution; holders withdraw with `claim()`. The pad, the router, the v4
///      PoolManager (which holds the pool's tokens), this contract and burn addresses are excluded.
contract PadToken {
    using SafeTransfer for address;
    using TransientStateLibrary for IPoolManager;

    error InsufficientBalance();
    error InsufficientAllowance();
    error InvalidRecipient();
    error Overflow();
    error Reentrancy();
    error PermitExpired();
    error InvalidSignature();
    error NotEligible();
    error NotPad();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event DividendsDistributed(uint256 amount, uint256 eligibleSupply);
    event DividendClaimed(address indexed holder, uint256 amount);
    event RewardsRecycled(address indexed holder, uint256 amount);

    uint256 public constant totalSupply = 1_000_000_000e18;
    uint8 public constant decimals = 18;
    /// @dev Distributions wait until at least 1 whole token is held outside the pool. Bounds per-share growth.
    uint256 public constant MIN_ELIGIBLE_SUPPLY = 1e18;
    /// @notice Rewards of a wallet inactive for longer than this expire (except those earned within it).
    uint256 public constant INACTIVITY_PERIOD = 7 days;
    /// @notice A receipt the recipient didn't initiate counts as activity only when it is at least 1/10 of what the
    ///         recipient already holds: holding off someone's expiry costs a tenth of their bag each time, whatever
    ///         the token's price (audit finding 3). Buys are recorded by the hook instead, whatever their size.
    uint256 public constant GIFT_ACTIVITY_DIVISOR = 10;
    uint256 internal constant MAGNITUDE = 2 ** 128;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    string public name;
    string public symbol;
    /// @notice JSON metadata (image, description, links) supplied by the creator.
    string public metadata;

    address public immutable pad;
    address public immutable router;
    address public immutable poolManager;
    /// @notice Asset rewards are paid in (IMD).
    address public immutable quote;
    address public immutable creator;
    /// @notice Where expired rewards go: the shared $Pepes buyback-and-burn (PepesBuyback).
    address public immutable buyback;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public magnifiedDividendPerShare;
    mapping(address => int256) internal magnifiedDividendCorrections;
    mapping(address => uint256) public withdrawnDividends;
    /// @notice Tokens held by dividend-eligible accounts.
    uint256 public eligibleSupply;
    /// @notice IMD held here that is owed to holders (distributed, not yet claimed or recycled).
    uint256 public accountedBalance;
    uint256 public totalDividendsDistributed;

    /// @notice Last activity of each holder (unix seconds), see the contract notice.
    mapping(address => uint256) public lastActive;
    /// @notice Expired rewards sent to the buyback so far.
    uint256 public totalRecycled;

    /// @dev magnifiedDividendPerShare after each distribution, by time: lets expiry compute what a holder earned
    ///      in the last 7 days (those rewards never expire).
    struct Checkpoint {
        uint64 time;
        uint192 mag;
    }

    Checkpoint[] internal _checkpoints;

    uint256 private _locked = 1;

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    mapping(address => uint256) public nonces;
    uint256 private immutable _initialChainId;
    bytes32 private immutable _initialDomainSeparator;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        string memory metadata_,
        address quote_,
        address creator_,
        address router_,
        address poolManager_,
        address buyback_
    ) {
        pad = msg.sender;
        router = router_;
        poolManager = poolManager_;
        quote = quote_;
        creator = creator_;
        buyback = buyback_;
        name = name_;
        symbol = symbol_;
        metadata = metadata_;
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
        _initialChainId = block.chainid;
        _initialDomainSeparator = _domainSeparator();
    }

    /// @notice This token has no owner and no admin functions: nothing about it can ever be changed.
    ///         Exposed as the zero address so explorers and scanners show it as renounced.
    function owner() external pure returns (address) {
        return address(0);
    }

    // ------------------------------------------------------------ EIP-2612

    /// @notice EIP-712 domain separator for `permit` (gasless approvals).
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _initialChainId ? _initialDomainSeparator : _domainSeparator();
    }

    /// @notice Sets `spender`'s allowance from `holder`'s signature instead of an `approve` transaction.
    function permit(address holder, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        if (block.timestamp > deadline) revert PermitExpired();
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, value, nonces[holder]++, deadline))
            )
        );
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != holder) revert InvalidSignature();
        allowance[holder][spender] = value;
        emit Approval(holder, spender, value);
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ---------------------------------------------------------------- ERC20

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @dev Standard allowance for every spender: no address is exempt. Routers get approval via
    ///      `approve` or a gasless EIP-2612 `permit` signature.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert InvalidRecipient();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
        }
        balanceOf[to] += amount;

        bool fromExcluded = isExcluded(from);
        bool toExcluded = isExcluded(to);
        int256 magCorrection = _toInt(magnifiedDividendPerShare * amount);
        if (!fromExcluded) magnifiedDividendCorrections[from] += magCorrection;
        if (!toExcluded) magnifiedDividendCorrections[to] -= magCorrection;
        if (fromExcluded && !toExcluded) eligibleSupply += amount;
        else if (!fromExcluded && toExcluded) eligibleSupply -= amount;

        // Activity (a zero-amount transferFrom needs no allowance, so it never counts). Sending, directly or through
        // an allowance the holder gave, is the holder's own act. Receiving counts when the recipient initiated it,
        // the first time, or when it is at least a tenth of what the recipient held (buys are recorded by the hook
        // through `markActive`). An unrecorded small receipt only raises the balance, which over-estimates
        // "recent" rewards in the holder's favour.
        if (amount != 0) {
            if (!fromExcluded) lastActive[from] = block.timestamp;
            if (
                !toExcluded
                    && (
                        msg.sender == to || lastActive[to] == 0
                            || amount * GIFT_ACTIVITY_DIVISOR >= balanceOf[to] - amount
                    )
            ) lastActive[to] = block.timestamp;
        }

        emit Transfer(from, to, amount);
    }

    /// @notice Records a buy as activity of the buyer. Only the pad (the pools' hook) calls it, for every buy of this
    ///         token: the buyer is the user our router reports, otherwise the transaction's signer, which nobody
    ///         can set for someone else.
    function markActive(address buyer) external {
        if (msg.sender != pad) revert NotPad();
        if (!isExcluded(buyer)) lastActive[buyer] = block.timestamp;
    }

    // ------------------------------------------------------------ Dividends

    function isExcluded(address account) public view returns (bool) {
        return account == poolManager || account == pad || account == router || account == address(this)
            || account == address(0) || account == DEAD;
    }

    /// @notice Spreads any IMD received since the last call across current holders, pro rata.
    /// @dev Called by the pad after it forwards holder fees; anyone may call it (e.g. after a donation).
    ///      If nobody holds tokens yet, the funds wait here for the next distribution.
    function distribute() public returns (uint256 amount) {
        // While the PoolManager is unlocked its tokens can be flash-borrowed and would count as held, so a
        // distribution then could be captured without owning anything. Only the pad (from its own unlock or one of
        // its routers') may distribute mid-unlock; otherwise funds wait for a distribution outside an unlock.
        if (msg.sender != pad && IPoolManager(poolManager).isUnlocked()) return 0;
        uint256 bal = quote.balanceOf(address(this));
        uint256 eligible = eligibleSupply;
        // Never revert: trades and claims call this, so an odd IMD balance must not block them.
        if (bal <= accountedBalance || eligible < MIN_ELIGIBLE_SUPPLY) return 0;
        amount = bal - accountedBalance;
        uint256 mag = magnifiedDividendPerShare + (amount * MAGNITUDE) / eligible;
        magnifiedDividendPerShare = mag;
        accountedBalance = bal;
        totalDividendsDistributed += amount;
        _checkpoint(mag);
        emit DividendsDistributed(amount, eligible);
    }

    function accumulativeDividendOf(address holder) public view returns (uint256) {
        if (isExcluded(holder)) return 0;
        int256 mag = _toInt(magnifiedDividendPerShare * balanceOf[holder]) + magnifiedDividendCorrections[holder];
        return mag <= 0 ? 0 : uint256(mag) / MAGNITUDE;
    }

    function withdrawableDividendOf(address holder) public view returns (uint256) {
        uint256 acc = accumulativeDividendOf(holder);
        uint256 done = withdrawnDividends[holder];
        return acc > done ? acc - done : 0;
    }

    /// @notice Pulls in fees from swaps made through other routers, pays out the caller's share, and resets
    ///         their 7-day timer.
    function claim() external nonReentrant returns (uint256 amount) {
        IPadFlush(pad).flush(address(this));
        if (!isExcluded(msg.sender)) lastActive[msg.sender] = block.timestamp;
        amount = withdrawableDividendOf(msg.sender);
        if (amount != 0) {
            withdrawnDividends[msg.sender] += amount;
            accountedBalance -= amount;
            quote.transferOut(msg.sender, amount);
            emit DividendClaimed(msg.sender, amount);
        }
    }

    // ------------------------------------------------------------ Expiry

    /// @notice Rewards of `holder` that have expired: everything unclaimed except what it earned in the last
    ///         7 days, once it has been inactive for more than 7 days. Zero while it is active.
    /// @dev Both boundaries are exclusive on the holder's side: a wallet is inactive only after more than 7 days,
    ///      and a reward distributed exactly 7 days ago still counts as recent.
    function expiredRewardsOf(address holder) public view returns (uint256) {
        if (isExcluded(holder)) return 0;
        uint256 last = lastActive[holder];
        if (last == 0 || block.timestamp <= last + INACTIVITY_PERIOD) return 0;
        uint256 w = withdrawableDividendOf(holder);
        if (w == 0) return 0;
        // Since `last` the balance can only have grown (every send records activity), so balance x (per-share
        // growth since the cutoff) is at least what it earned since the cutoff: "recent" can only be
        // over-estimated, in the holder's favour. Rounded up as well.
        uint256 magCut = magAt(block.timestamp - INACTIVITY_PERIOD - 1);
        uint256 recent = FullMath.mulDivRoundingUp(magnifiedDividendPerShare - magCut, balanceOf[holder], MAGNITUDE);
        return w > recent ? w - recent : 0;
    }

    /// @notice Sends `holder`'s expired rewards to the $Pepes buyback-and-burn. Callable by anyone; it can only ever
    ///         move rewards that have expired, and only to `buyback`.
    function recycle(address holder) public nonReentrant returns (uint256 expired) {
        if (isExcluded(holder)) revert NotEligible();
        expired = expiredRewardsOf(holder);
        if (expired == 0) return 0;
        withdrawnDividends[holder] += expired;
        accountedBalance -= expired;
        totalRecycled += expired;
        quote.transferOut(buyback, expired);
        emit RewardsRecycled(holder, expired);
    }

    function recycleMany(address[] calldata holders) external returns (uint256 total) {
        for (uint256 i; i < holders.length; i++) {
            if (!isExcluded(holders[i])) total += recycle(holders[i]);
        }
    }

    function checkpointCount() external view returns (uint256) {
        return _checkpoints.length;
    }

    /// @notice magnifiedDividendPerShare as of time `t` (after every distribution at or before `t`).
    function magAt(uint256 t) public view returns (uint256) {
        uint256 hi = _checkpoints.length;
        uint256 lo;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_checkpoints[mid].time <= t) lo = mid + 1;
            else hi = mid;
        }
        return lo == 0 ? 0 : _checkpoints[lo - 1].mag;
    }

    function _checkpoint(uint256 mag) internal {
        if (mag > type(uint192).max) return; // unreachable in practice; never block a distribution
        uint256 n = _checkpoints.length;
        if (n != 0 && _checkpoints[n - 1].time == block.timestamp) _checkpoints[n - 1].mag = uint192(mag);
        else _checkpoints.push(Checkpoint(uint64(block.timestamp), uint192(mag)));
    }

    function _toInt(uint256 x) private pure returns (int256) {
        if (x > uint256(type(int256).max)) revert Overflow();
        return int256(x);
    }
}
