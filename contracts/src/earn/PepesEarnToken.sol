// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DN404} from "dn404/DN404.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeTransfer} from "../lib/SafeTransfer.sol";

interface IEarnPad {
    function flush(address token) external;
    function owner() external view returns (address);
}

interface IEarnPadInfo {
    function router() external view returns (address);
    function ethRouter() external view returns (address);
    function poolManager() external view returns (address);
    function IMD() external view returns (address);
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
}

/// @title PepesEarnToken ($EARN)
/// @notice Pepes Earn IMD: 2,000 $EARN tokens, each whole token shown as one on-chain NFT (DN404). $EARN trades in a
///         Uniswap v4 pool against IMD through the PepesEarnPad hook, which charges 4% of every swap: 1% protocol,
///         3% to $EARN holders pro rata (same magnified-dividend accounting as PepesFamily v3, including its guard
///         against flash-borrowed pool tokens).
///
///         Rewards are claimed manually. Rewards of a wallet that has neither claimed nor moved any $EARN for
///         30 days expire, except what it earned during those last 30 days: anyone may move expired rewards into
///         the buyback reserve, which can only be spent buying $Pepes and sending them to the burn address.
/// @dev The token has no owner (owner() is the zero address). The launchpad owner may only time buybacks; there
///      is no function that sends reserve, rewards or holders' tokens anywhere else.
contract PepesEarnToken is DN404 {
    using SafeTransfer for address;
    using TransientStateLibrary for IPoolManager;

    error Overflow();
    error Reentrancy();
    error NotOwner();
    error NotEligible();
    error StillActive();
    error BadAmount();
    error ApproveFailed();

    event DividendsDistributed(uint256 amount, uint256 eligibleSupply);
    event DividendClaimed(address indexed holder, uint256 amount);
    event RewardsRecycled(address indexed holder, uint256 amount);
    event PepesBoughtAndBurned(uint256 imdIn, uint256 pepesBurned);

    uint256 public constant SUPPLY = 2_000e18;
    /// @dev Distributions wait until at least 1 whole token is held outside the pool. Bounds per-share growth.
    uint256 public constant MIN_ELIGIBLE_SUPPLY = 1e18;
    uint256 public constant INACTIVITY_PERIOD = 30 days;
    uint256 internal constant MAGNITUDE = 2 ** 128;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable pad;
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

    /// @notice Last claim or $EARN balance change of each holder (unix seconds).
    mapping(address => uint256) public lastActive;
    /// @notice IMD from expired rewards, reserved for $Pepes buyback-and-burn.
    uint256 public buybackReserve;
    uint256 public totalRecycled;
    uint256 public totalPepesBurned;

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

    /// @dev Deployed by the same account that deployed `mirror` (DN404 links them by deployer). The whole supply
    ///      goes to the pad (without NFTs), whose one-time `launch` locks it in the pool.
    constructor(
        address pad_,
        address mirror,
        address renderer_,
        address pepes_,
        address pepesRouter_
    ) {
        IEarnPadInfo p = IEarnPadInfo(pad_);
        pad = pad_;
        router = p.router();
        ethRouter = p.ethRouter();
        poolManager = address(p.poolManager());
        quote = p.IMD();
        renderer = renderer_;
        pepes = pepes_;
        pepesRouter = pepesRouter_;
        _initializeDN404(SUPPLY, pad_, mirror);
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

    /// @dev Wallets get NFTs; contracts don't (the pool, routers and pad hold tokens only). EIP-7702 delegated
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
        _moved(from, to, amount);
    }

    /// @dev ... and NFT transfers on the mirror (marketplaces, wallet sends), which move one unit directly.
    function _transferFromNFT(address from, address to, uint256 id, address msgSender) internal override {
        super._transferFromNFT(from, to, id, msgSender);
        _moved(from, to, _unit());
    }

    /// @dev Reward bookkeeping for every balance change: keeps rewards with whoever held the tokens when they
    ///      were earned, tracks the eligible supply, and marks both sides active.
    function _moved(address from, address to, uint256 amount) internal {
        bool fromExcluded = isExcluded(from);
        bool toExcluded = isExcluded(to);
        int256 magCorrection = _toInt(magnifiedDividendPerShare * amount);
        if (!fromExcluded) {
            magnifiedDividendCorrections[from] += magCorrection;
            lastActive[from] = block.timestamp;
        }
        if (!toExcluded) {
            magnifiedDividendCorrections[to] -= magCorrection;
            lastActive[to] = block.timestamp;
        }
        if (fromExcluded && !toExcluded) eligibleSupply += amount;
        else if (!fromExcluded && toExcluded) eligibleSupply -= amount;
    }

    // ------------------------------------------------------------ rewards

    function isExcluded(address account) public view returns (bool) {
        return account == poolManager || account == pad || account == router || account == ethRouter
            || account == address(this) || account == address(0) || account == DEAD;
    }

    /// @notice Spreads IMD received since the last call (holder fees) across current holders, pro rata.
    /// @dev Never reverts: trades and claims call it. Mid-unlock only the pad may distribute (see PadToken v3).
    function distribute() public returns (uint256 amount) {
        if (msg.sender != pad && IPoolManager(poolManager).isUnlocked()) return 0;
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
        IEarnPad(pad).flush(address(this));
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
    ///         30 days, once it has neither claimed nor moved $EARN for 30 days. Zero while it is active.
    function expiredRewardsOf(address holder) public view returns (uint256) {
        if (isExcluded(holder)) return 0;
        uint256 last = lastActive[holder];
        if (last == 0 || block.timestamp < last + INACTIVITY_PERIOD) return 0;
        uint256 w = withdrawableDividendOf(holder);
        if (w == 0) return 0;
        // The balance cannot have changed since `last` (any change marks the holder active), so what it earned
        // since the cutoff is balance x (per-share growth since the cutoff). Rounded up in the holder's favour.
        uint256 magCut = magAt(block.timestamp - INACTIVITY_PERIOD);
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

    /// @notice Spends `imdIn` of the buyback reserve on $Pepes and sends all of it to the burn address.
    /// @dev Only the launchpad owner, who picks the timing and the minimum output (so the swap can't be
    ///      sandwiched). The reserve can't go anywhere but this swap.
    function buybackAndBurnPepes(uint256 imdIn, uint256 minPepesOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 burned)
    {
        if (msg.sender != IEarnPad(pad).owner()) revert NotOwner();
        if (imdIn == 0 || imdIn > buybackReserve) revert BadAmount();
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
