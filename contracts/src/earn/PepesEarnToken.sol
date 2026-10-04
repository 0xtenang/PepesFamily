// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DN404} from "dn404/DN404.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeTransfer} from "../lib/SafeTransfer.sol";
import {PepesEarnMirror} from "./PepesEarnMirror.sol";

interface IEarnHook {
    function flush(address token) external;
}

interface IEarnHookInfo {
    function router() external view returns (address);
    function ethRouter() external view returns (address);
    function poolManager() external view returns (address);
    function IMD() external view returns (address);
    function pepes() external view returns (address);
    function pepesRouter() external view returns (address);
}

interface IEarnRenderer {
    function tokenURI(uint256 id) external view returns (string memory);
}

/// @dev PepesFamily v1 router: buys an IMD-paired token with IMD for msg.sender.
interface IPepesRouter {
    function buy(address token, uint256 amountIn, uint256 minTokensOut, uint256 deadline)
        external
        payable
        returns (uint256);
    function pad() external view returns (address);
}

/// @dev PepesFamily v1 launchpad: gives the $Pepes pool key.
interface IPepesPad {
    function poolKey(address token) external view returns (PoolKey memory);
}

/// @title PepesEarnToken ($EARN)
/// @notice Pepes Earn IMD: 2,000 $EARN tokens, each whole token held shown as one on-chain NFT (DN404). $EARN trades
///         in a Uniswap v4 pool against IMD through the PepesEarnIMD hook, which charges 4% of every swap: 1%
///         protocol, 3% to $EARN holders pro rata (same magnified-dividend accounting as PepesFamily v3, including
///         its guard against flash-borrowed pool tokens).
///
///         Rewards are claimed manually. A wallet is active when it claims, sends $EARN, pulls $EARN itself, or
///         receives at least one whole $EARN (one NFT: pool buys of a whole token, marketplace purchases). Rewards
///         of a wallet inactive for more than 30 days expire, except what it earned during those last 30 days:
///         anyone may move expired rewards
///         into the buyback reserve, which can only be spent buying $Pepes and sending them to the burn address,
///         by anyone, in capped steps.
/// @dev No owner (owner() is the zero address) and no privileged function: nothing sends the reserve, rewards or
///      holders' tokens anywhere but the burn swap and the holders themselves.
contract PepesEarnToken is DN404 {
    using SafeTransfer for address;
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;

    error Overflow();
    error Reentrancy();
    error NotEligible();
    error BadAmount();
    error TooSoon();
    error ApproveFailed();

    event DividendsDistributed(uint256 amount, uint256 eligibleSupply);
    event DividendClaimed(address indexed holder, uint256 amount);
    event RewardsRecycled(address indexed holder, uint256 amount);
    event PepesBoughtAndBurned(uint256 imdIn, uint256 pepesBurned);

    uint256 public constant SUPPLY = 2_000e18;
    /// @dev Distributions wait until at least 1 whole token is held outside the pool. Bounds per-share growth.
    uint256 public constant MIN_ELIGIBLE_SUPPLY = 1e18;
    uint256 public constant INACTIVITY_PERIOD = 30 days;
    /// @notice Reserve spent per buyback: at most 2% of the $Pepes pool's IMD depth, at most once an hour. A
    ///         sandwich then costs more in the $Pepes pool's 4% fees than it can move the price (audit finding 2).
    uint256 public constant MAX_BUYBACK_BPS = 200;
    uint256 public constant BUYBACK_INTERVAL = 1 hours;
    uint256 internal constant MAGNITUDE = 2 ** 128;
    uint256 internal constant Q96 = 2 ** 96;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable hook;
    address public immutable router;
    address public immutable ethRouter;
    address public immutable poolManager;
    /// @notice Asset rewards are paid in (IMD).
    address public immutable quote;
    address public immutable renderer;
    /// @notice Token bought back and burned with expired rewards ($Pepes) and the router used to buy it.
    address public immutable pepes;
    address public immutable pepesRouter;

    uint256 public magnifiedDividendPerShare;
    mapping(address => int256) internal magnifiedDividendCorrections;
    mapping(address => uint256) public withdrawnDividends;
    /// @notice $EARN held by reward-eligible accounts.
    uint256 public eligibleSupply;
    /// @notice IMD held here that is owed to holders (distributed, not yet claimed or recycled).
    uint256 public accountedBalance;
    uint256 public totalDividendsDistributed;

    /// @notice Last activity of each holder (unix seconds): a claim, a send, an own pull, receiving at least one
    ///         whole $EARN, or the first receipt. Smaller receipts it didn't initiate don't count.
    mapping(address => uint256) public lastActive;
    /// @notice IMD from expired rewards, reserved for $Pepes buyback-and-burn.
    uint256 public buybackReserve;
    uint256 public totalRecycled;
    uint256 public totalPepesBurned;
    uint256 public lastBuyback;

    /// @dev magnifiedDividendPerShare after each distribution, by time: lets expiry compute what a holder earned
    ///      in the last 30 days (those rewards never expire).
    struct Checkpoint {
        uint64 time;
        uint192 mag;
    }

    Checkpoint[] internal _checkpoints;

    uint256 private _locked = 1;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /// @dev Deploys its own NFT mirror and links it in this same transaction, so nobody can link the mirror to
    ///      something else first (audit finding 5). Routers, PoolManager, IMD and the buyback targets come from the
    ///      hook. The whole supply goes to the hook (without NFTs), whose one-time `openPool` locks it in the pool.
    constructor(address hook_, address renderer_) {
        IEarnHookInfo p = IEarnHookInfo(hook_);
        hook = hook_;
        router = p.router();
        ethRouter = p.ethRouter();
        poolManager = address(p.poolManager());
        quote = p.IMD();
        pepes = p.pepes();
        pepesRouter = p.pepesRouter();
        renderer = renderer_;
        // DN404 lets only the mirror's recorded deployer link it; that is this constructor's caller.
        _initializeDN404(SUPPLY, hook_, address(new PepesEarnMirror(hook_, msg.sender)));
    }

    // ------------------------------------------------------------ metadata

    function name() public pure override returns (string memory) {
        return "Pepes Earn IMD";
    }

    function symbol() public pure override returns (string memory) {
        return "EARN";
    }

    function _tokenURI(uint256 id) internal view override returns (string memory) {
        return IEarnRenderer(renderer).tokenURI(id);
    }

    /// @notice No owner and no admin functions over balances or rewards. Zero so scanners show it as renounced.
    function owner() external pure returns (address) {
        return address(0);
    }

    // ------------------------------------------------------------ DN404 configuration

    /// @dev Wallets get NFTs; contracts don't (the pool, routers and hook hold tokens only). EIP-7702 delegated
    ///      EOAs (code = 0xef0100 ‖ address) count as wallets, so smart-account users receive their NFTs too.
    function _skipNFTDefault(address account) internal view override returns (bool) {
        uint256 size = account.code.length;
        if (size == 0) return false;
        if (size == 23 && bytes3(account.code) == 0xef0100) return false;
        return true;
    }

    /// @dev No default Permit2 allowance: the only approvals on $EARN are the ones holders give themselves.
    function _givePermit2DefaultInfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    /// @dev Token transfers (ERC20 side, including pool trades) ...
    function _transfer(address from, address to, uint256 amount) internal override {
        super._transfer(from, to, amount);
        _moved(from, to, amount, msg.sender);
    }

    /// @dev ... and NFT transfers on the mirror (marketplaces, wallet sends), which move one unit directly.
    function _transferFromNFT(address from, address to, uint256 id, address msgSender) internal override {
        super._transferFromNFT(from, to, id, msgSender);
        _moved(from, to, _unit(), msgSender);
    }

    /// @dev Reward bookkeeping for every balance change: keeps rewards with whoever held the tokens when they
    ///      were earned, tracks the eligible supply, and records activity. `actor` is who initiated the move.
    function _moved(address from, address to, uint256 amount, address actor) internal {
        // A zero-amount transferFrom needs no allowance, so it must not count as activity (audit finding 8).
        if (amount == 0) return;
        bool fromExcluded = isExcluded(from);
        bool toExcluded = isExcluded(to);
        int256 magCorrection = _toInt(magnifiedDividendPerShare * amount);
        if (!fromExcluded) {
            // Sending (directly or through an allowance the holder gave) is the holder's own activity.
            magnifiedDividendCorrections[from] += magCorrection;
            lastActive[from] = block.timestamp;
        }
        if (!toExcluded) {
            magnifiedDividendCorrections[to] -= magCorrection;
            // Receiving counts as activity when the recipient initiated it, when it is at least one whole $EARN
            // (one NFT: a pool buy of a whole token or a marketplace purchase), or for a first-time holder. The
            // chain can't tell a purchase from a gift, so a gift that resets someone's timer must cost a whole
            // $EARN rather than dust, whichever path delivers it (final check, lows 1 and 2). Expiry stays correct
            // either way: an unrecorded incoming transfer only raises the balance, which over-estimates "recent"
            // rewards in the holder's favour.
            if (actor == to || amount >= _unit() || lastActive[to] == 0) lastActive[to] = block.timestamp;
        }
        if (fromExcluded && !toExcluded) eligibleSupply += amount;
        else if (!fromExcluded && toExcluded) eligibleSupply -= amount;
    }

    // ------------------------------------------------------------ rewards

    function isExcluded(address account) public view returns (bool) {
        return account == poolManager || account == hook || account == router || account == ethRouter
            || account == address(this) || account == address(0) || account == DEAD;
    }

    /// @notice Spreads IMD received since the last call (holder fees) across current holders, pro rata.
    /// @dev Never reverts: trades and claims call it. Mid-unlock only the hook may distribute (see PadToken v3).
    function distribute() public returns (uint256 amount) {
        if (msg.sender != hook && IPoolManager(poolManager).isUnlocked()) return 0;
        uint256 bal = quote.balanceOf(address(this));
        uint256 tracked = accountedBalance + buybackReserve;
        uint256 eligible = eligibleSupply;
        if (bal <= tracked || eligible < MIN_ELIGIBLE_SUPPLY) return 0;
        amount = bal - tracked;
        uint256 mag = magnifiedDividendPerShare + (amount * MAGNITUDE) / eligible;
        magnifiedDividendPerShare = mag;
        accountedBalance += amount;
        totalDividendsDistributed += amount;
        _checkpoint(mag);
        emit DividendsDistributed(amount, eligible);
    }

    function accumulativeDividendOf(address holder) public view returns (uint256) {
        if (isExcluded(holder)) return 0;
        int256 mag = _toInt(magnifiedDividendPerShare * balanceOf(holder)) + magnifiedDividendCorrections[holder];
        return mag <= 0 ? 0 : uint256(mag) / MAGNITUDE;
    }

    function withdrawableDividendOf(address holder) public view returns (uint256) {
        uint256 acc = accumulativeDividendOf(holder);
        uint256 done = withdrawnDividends[holder];
        return acc > done ? acc - done : 0;
    }

    /// @notice Pulls in pending fees, pays out the caller's rewards, and resets their 30-day timer.
    function claim() external nonReentrant returns (uint256 amount) {
        IEarnHook(hook).flush(address(this));
        if (!isExcluded(msg.sender)) lastActive[msg.sender] = block.timestamp;
        amount = withdrawableDividendOf(msg.sender);
        if (amount != 0) {
            withdrawnDividends[msg.sender] += amount;
            accountedBalance -= amount;
            quote.transferOut(msg.sender, amount);
            emit DividendClaimed(msg.sender, amount);
        }
    }

    // ------------------------------------------------------------ expiry

    /// @notice Rewards of `holder` that have expired: everything unclaimed except what it earned in the last
    ///         30 days, once it has been inactive for more than 30 days. Zero while it is active.
    /// @dev Both boundaries are exclusive on the holder's side (audit finding 4): a wallet is inactive only after
    ///      more than 30 days, and a reward distributed exactly 30 days ago still counts as recent.
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
        uint256 recent = FullMath.mulDivRoundingUp(magnifiedDividendPerShare - magCut, balanceOf(holder), MAGNITUDE);
        return w > recent ? w - recent : 0;
    }

    /// @notice Moves `holder`'s expired rewards into the $Pepes buyback reserve. Callable by anyone; it can only
    ///         ever move rewards that have expired, and only into the reserve.
    function recycle(address holder) public returns (uint256 expired) {
        if (isExcluded(holder)) revert NotEligible();
        expired = expiredRewardsOf(holder);
        if (expired == 0) return 0;
        withdrawnDividends[holder] += expired;
        accountedBalance -= expired;
        buybackReserve += expired;
        totalRecycled += expired;
        emit RewardsRecycled(holder, expired);
    }

    function recycleMany(address[] calldata holders) external returns (uint256 total) {
        for (uint256 i; i < holders.length; i++) {
            if (!isExcluded(holders[i])) total += recycle(holders[i]);
        }
    }

    /// @notice Spends part of the buyback reserve on $Pepes and sends all of it to the burn address. Callable by
    ///         anyone, at most once an hour, for at most `maxBuyback()` (larger reserves burn over several calls),
    ///         so no one can profit from sandwiching it. The reserve can't go anywhere but this swap.
    /// @param minPepesOut minimum $Pepes bought (0 accepts the capped market price)
    function buybackAndBurnPepes(uint256 minPepesOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 burned)
    {
        if (block.timestamp < lastBuyback + BUYBACK_INTERVAL) revert TooSoon();
        uint256 imdIn = buybackReserve;
        uint256 cap = maxBuyback();
        if (imdIn > cap) imdIn = cap;
        if (imdIn == 0) revert BadAmount();
        lastBuyback = block.timestamp;
        buybackReserve -= imdIn;
        _approveToken(quote, pepesRouter, imdIn);
        uint256 before = pepes.balanceOf(address(this));
        IPepesRouter(pepesRouter).buy(pepes, imdIn, minPepesOut, deadline);
        _approveToken(quote, pepesRouter, 0);
        burned = pepes.balanceOf(address(this)) - before;
        pepes.transferOut(DEAD, burned);
        totalPepesBurned += burned;
        emit PepesBoughtAndBurned(imdIn, burned);
    }

    /// @notice Most reserve IMD one buyback spends: 2% of the $Pepes pool's (virtual) IMD reserve at the current
    ///         price, read from the PepesFamily v1 pool through the PoolManager.
    function maxBuyback() public view returns (uint256) {
        PoolKey memory key = IPepesPad(IPepesRouter(pepesRouter).pad()).poolKey(pepes);
        PoolId id = key.toId();
        (uint160 sqrtP,,,) = IPoolManager(poolManager).getSlot0(id);
        if (sqrtP == 0) return 0;
        uint256 liquidity = IPoolManager(poolManager).getLiquidity(id);
        uint256 imdDepth = Currency.unwrap(key.currency0) == quote
            ? FullMath.mulDiv(liquidity, Q96, sqrtP) // IMD is currency0: x = L / sqrtP
            : FullMath.mulDiv(liquidity, sqrtP, Q96); // IMD is currency1: y = L * sqrtP
        return (imdDepth * MAX_BUYBACK_BPS) / 10_000;
    }

    // ------------------------------------------------------------ views

    /// @notice NFT ids owned by `holder`, positions [begin, end) of its owned list (end is capped to the count).
    ///         Read-only helper for wallets and the website; `mirror.balanceOf(holder)` gives the count.
    function ownedIds(address holder, uint256 begin, uint256 end) external view returns (uint256[] memory ids) {
        DN404Storage storage $ = _getDN404Storage();
        uint256 n = $.addressData[holder].ownedLength;
        if (end > n) end = n;
        if (begin >= end) return ids;
        ids = new uint256[](end - begin);
        for (uint256 i = begin; i < end; i++) {
            ids[i - begin] = _get($.owned[holder], i);
        }
    }

    // ------------------------------------------------------------ checkpoints

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

    // ------------------------------------------------------------ helpers

    function _approveToken(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert ApproveFailed();
    }

    function _toInt(uint256 x) private pure returns (int256) {
        if (x > uint256(type(int256).max)) revert Overflow();
        return int256(x);
    }
}
