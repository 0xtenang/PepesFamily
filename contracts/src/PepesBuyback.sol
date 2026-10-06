// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeTransfer} from "./lib/SafeTransfer.sol";

/// @dev PepesFamily v1 router: buys an IMD-paired token with IMD for msg.sender.
interface IPepesRouterV1 {
    function buy(address token, uint256 amountIn, uint256 minTokensOut, uint256 deadline)
        external
        payable
        returns (uint256);
    function pad() external view returns (address);
}

/// @dev PepesFamily v1 launchpad: gives the $Pepes pool key.
interface IPepesPadV1 {
    function poolKey(address token) external view returns (PoolKey memory);
}

/// @title PepesBuyback
/// @notice Shared $Pepes buyback-and-burn for every PepesFamily v4 token. Expired holder rewards (see PadToken) are
///         sent here as IMD; anyone can spend them buying $Pepes, and every $Pepes this contract holds is sent to
///         the burn address.
///
///         Pace: each buyback spends at most 1% of the $Pepes pool's IMD depth (and at least 0.1 IMD), at most once
///         an hour, so a single-transaction sandwich costs more in the $Pepes pool's 4% fee each way than it moves
///         the price.
///
///         Price guard: a buyback only runs while the $Pepes price is at most 2% above a slow reference price. The
///         reference follows the buybacks' own price impact exactly, and otherwise drifts toward the market by at
///         most 2% per day, counting at most one day per update (`poke`, also run by every recycle and buyback). So
///         third-party buys between buybacks, a pump after an idle period, or a dip bracketed around a buyback move
///         the reference by at most 2% a day: a pump stalls the buyback until it is undone or has held for days,
///         and an organic rise or fall is followed at 2% a day (IMD Swarm audits ec4e3ea7 and b803125e).
///
///         One contract for all v4 tokens, so the cap, pace and guard cover every v4 buyback together. With the
///         $EARN buyback (2% cap, its own contract) one transaction can buy at most 3% of depth, below the ~4% at
///         which a sandwich starts to pay.
/// @dev No owner and no privileged function: the IMD here can only ever leave through the burn swap.
contract PepesBuyback {
    using SafeTransfer for address;
    using StateLibrary for IPoolManager;

    error TooSoon();
    error BadAmount();
    error ApproveFailed();
    error Reentrancy();
    error ZeroAddress();
    error BadWiring();
    error PriceRisen();

    event PepesBoughtAndBurned(uint256 imdIn, uint256 pepesBurned);
    event ReferenceUpdated(uint160 refSqrtPrice);

    /// @notice IMD spent per buyback: at most 1% of the $Pepes pool's IMD depth ...
    uint256 public constant MAX_BUYBACK_BPS = 100;
    /// @notice ... and at least this much (smaller reserves wait), so dust can't take the hourly slot.
    uint256 public constant MIN_BUYBACK = 0.1e18;
    uint256 public constant BUYBACK_INTERVAL = 1 hours;
    /// @notice A buyback runs only while the $Pepes price is at most this far above the reference.
    uint256 public constant MAX_PRICE_RISE_BPS = 200;
    /// @notice The reference moves toward the market price by at most this much (price) per day ...
    uint256 public constant REF_STEP_PER_DAY_BPS = 200;
    /// @notice ... counting at most this much time per update, so idle time doesn't build up tolerance.
    uint256 public constant MAX_REF_ELAPSED = 1 days;
    uint256 internal constant Q96 = 2 ** 96;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable imd;
    address public immutable pepes;
    /// @notice PepesFamily v1 router, through which $Pepes is bought.
    address public immutable pepesRouter;
    address public immutable poolManager;
    /// @notice True when IMD is currency0 of the $Pepes pool (then a higher $Pepes price is a lower sqrtPrice).
    bool public immutable imdIsCurrency0;

    uint256 public lastBuyback;
    uint256 public totalImdSpent;
    uint256 public totalPepesBurned;
    /// @notice Reference pool sqrtPrice for the price guard, and when it was last moved toward the market.
    uint160 public refSqrtPrice;
    uint64 public refTime;

    uint256 private _locked = 1;

    /// @dev Resolves the $Pepes pool through the router's launchpad and requires it to be an initialised IMD pair, so
    ///      a mis-wired deployment reverts instead of creating a sink the IMD could never leave.
    constructor(address imd_, address pepes_, address pepesRouter_, address poolManager_) {
        if (imd_ == address(0) || pepes_ == address(0) || pepesRouter_ == address(0) || poolManager_ == address(0)) {
            revert ZeroAddress();
        }
        imd = imd_;
        pepes = pepes_;
        pepesRouter = pepesRouter_;
        poolManager = poolManager_;
        PoolKey memory key = IPepesPadV1(IPepesRouterV1(pepesRouter_).pad()).poolKey(pepes_);
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (!((c0 == imd_ && c1 == pepes_) || (c0 == pepes_ && c1 == imd_))) revert BadWiring();
        imdIsCurrency0 = c0 == imd_;
        (uint160 sqrtP,,,) = IPoolManager(poolManager_).getSlot0(key.toId());
        if (sqrtP == 0) revert BadWiring();
        refSqrtPrice = sqrtP;
        refTime = uint64(block.timestamp);
    }

    /// @notice IMD waiting to be spent on buybacks.
    function reserve() external view returns (uint256) {
        return imd.balanceOf(address(this));
    }

    /// @notice Moves the reference toward the current price by at most 2% per day since the last update (at most
    ///         one day counted). Anyone may call it; every recycle and buyback does.
    function poke() public {
        uint256 dt = block.timestamp - refTime;
        if (dt == 0) return;
        if (dt > MAX_REF_ELAPSED) dt = MAX_REF_ELAPSED;
        refTime = uint64(block.timestamp);
        uint256 cur = _sqrtPrice();
        uint256 ref = refSqrtPrice;
        // A price step of b bps is about b/2 bps in sqrtPrice; the same bound applies in both directions.
        uint256 h = (REF_STEP_PER_DAY_BPS * dt) / (2 * 1 days);
        uint256 lo = (ref * (10_000 - h)) / 10_000;
        uint256 hi = (ref * (10_000 + h)) / 10_000;
        uint256 next = cur < lo ? lo : cur > hi ? hi : cur;
        if (next != ref) {
            refSqrtPrice = uint160(next);
            emit ReferenceUpdated(uint160(next));
        }
    }

    /// @notice Spends up to `maxBuyback()` of the IMD here on $Pepes and sends all $Pepes held here to the burn
    ///         address. Callable by anyone, at most once an hour and only within the price guard; larger reserves
    ///         burn over several calls.
    /// @param minPepesOut minimum $Pepes bought (0 accepts the capped market price)
    function buybackAndBurnPepes(uint256 minPepesOut, uint256 deadline) external returns (uint256 burned) {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        if (block.timestamp < lastBuyback + BUYBACK_INTERVAL) revert TooSoon();
        poke();
        if (priceRiseBps() > MAX_PRICE_RISE_BPS) revert PriceRisen();
        uint256 imdIn = imd.balanceOf(address(this));
        uint256 cap = maxBuyback();
        if (imdIn > cap) imdIn = cap;
        if (imdIn < MIN_BUYBACK) revert BadAmount();
        lastBuyback = block.timestamp;
        uint160 before = _sqrtPrice();
        _approve(imd, pepesRouter, imdIn);
        IPepesRouterV1(pepesRouter).buy(pepes, imdIn, minPepesOut, deadline);
        _approve(imd, pepesRouter, 0);
        // Everything held is burned, including $Pepes sent here directly.
        burned = pepes.balanceOf(address(this));
        pepes.transferOut(DEAD, burned);
        totalImdSpent += imdIn;
        totalPepesBurned += burned;
        // The reference follows this buyback's own price impact, and nothing else.
        uint160 next = uint160(FullMath.mulDiv(refSqrtPrice, _sqrtPrice(), before));
        refSqrtPrice = next;
        emit ReferenceUpdated(next);
        emit PepesBoughtAndBurned(imdIn, burned);
        _locked = 1;
    }

    /// @notice How far the $Pepes price (in IMD) is above the reference price, in basis points (0 if not above).
    function priceRiseBps() public view returns (uint256) {
        uint160 nowP = _sqrtPrice();
        uint160 refP = refSqrtPrice;
        // $Pepes price is proportional to 1/P when IMD is currency0, to P otherwise (P = sqrtPrice^2).
        (uint256 hi, uint256 lo) = imdIsCurrency0 ? (uint256(refP), uint256(nowP)) : (uint256(nowP), uint256(refP));
        if (lo == 0 || hi <= lo) return 0;
        uint256 r = FullMath.mulDiv(hi, 1e18, lo);
        uint256 ratio = FullMath.mulDiv(r, r, 1e18);
        return (ratio - 1e18) / 1e14;
    }

    /// @notice Most IMD one buyback spends: 1% of the $Pepes pool's (virtual) IMD reserve at the current price,
    ///         read from the PepesFamily v1 pool through the PoolManager. Zero only when the pool's position is out
    ///         of range, i.e. every $Pepes has been sold back to the pool; the IMD then waits.
    function maxBuyback() public view returns (uint256) {
        PoolId id = _poolId();
        (uint160 sqrtP,,,) = IPoolManager(poolManager).getSlot0(id);
        if (sqrtP == 0) return 0;
        uint256 liquidity = IPoolManager(poolManager).getLiquidity(id);
        uint256 imdDepth = imdIsCurrency0
            ? FullMath.mulDiv(liquidity, Q96, sqrtP) // IMD is currency0: x = L / sqrtP
            : FullMath.mulDiv(liquidity, sqrtP, Q96); // IMD is currency1: y = L * sqrtP
        return (imdDepth * MAX_BUYBACK_BPS) / 10_000;
    }

    function _poolId() internal view returns (PoolId) {
        return IPepesPadV1(IPepesRouterV1(pepesRouter).pad()).poolKey(pepes).toId();
    }

    function _sqrtPrice() internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = IPoolManager(poolManager).getSlot0(_poolId());
    }

    function _approve(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert ApproveFailed();
    }
}
