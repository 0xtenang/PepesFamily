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
///         Pace and price guard. Each buyback spends at most 1% of the $Pepes pool's IMD depth, at most once an
///         hour, so a single-transaction sandwich costs more in the $Pepes pool's 4% fee each way than it moves the
///         price. A predictable series of buybacks could still be front-run by buying first and selling after
///         several of them, so a buyback only runs while the $Pepes price (in IMD) is at most 2% above the price
///         right after the previous buyback, plus 2% for every day since. A pump stalls the buyback (the IMD
///         waits) instead of selling into it; an organic rise only delays it by days.
///
///         One contract for all v4 tokens, so the cap and the pace cover every v4 buyback together. Together with
///         the $EARN buyback (2% cap, its own contract) one transaction can buy at most 3% of depth, below the ~4%
///         at which a sandwich starts to pay (IMD Swarm audit ec4e3ea7); and once the $EARN buyback has moved the
///         price more than 2%, this one won't run until the next day's allowance.
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

    /// @notice IMD spent per buyback: at most 1% of the $Pepes pool's IMD depth.
    uint256 public constant MAX_BUYBACK_BPS = 100;
    uint256 public constant BUYBACK_INTERVAL = 1 hours;
    /// @notice The $Pepes price may be at most this much above the reference price ...
    uint256 public constant MAX_PRICE_RISE_BPS = 200;
    /// @notice ... plus this much for every day since the reference was set.
    uint256 public constant PRICE_RISE_PER_DAY_BPS = 200;
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
    /// @notice Pool sqrtPrice right after the last buyback (at deployment before the first), and when it was set.
    uint160 public refSqrtPrice;
    uint64 public refTime;

    uint256 private _locked = 1;

    /// @dev Resolves the $Pepes pool through the router's launchpad and requires it to be an initialised IMD pair, so
    ///      a mis-wired deployment reverts instead of creating a sink the IMD could never leave (audit finding 5).
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

    /// @notice Spends up to `maxBuyback()` of the IMD here on $Pepes and sends all $Pepes held here to the burn
    ///         address. Callable by anyone, at most once an hour and only within the price guard; larger reserves
    ///         burn over several calls.
    /// @param minPepesOut minimum $Pepes bought (0 accepts the capped market price)
    function buybackAndBurnPepes(uint256 minPepesOut, uint256 deadline) external returns (uint256 burned) {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        if (block.timestamp < lastBuyback + BUYBACK_INTERVAL) revert TooSoon();
        if (priceRiseBps() > allowedPriceRiseBps()) revert PriceRisen();
        uint256 imdIn = imd.balanceOf(address(this));
        uint256 cap = maxBuyback();
        if (imdIn > cap) imdIn = cap;
        if (imdIn == 0) revert BadAmount();
        lastBuyback = block.timestamp;
        _approve(imd, pepesRouter, imdIn);
        IPepesRouterV1(pepesRouter).buy(pepes, imdIn, minPepesOut, deadline);
        _approve(imd, pepesRouter, 0);
        // Everything held is burned, including $Pepes sent here directly (audit finding 2).
        burned = pepes.balanceOf(address(this));
        pepes.transferOut(DEAD, burned);
        totalImdSpent += imdIn;
        totalPepesBurned += burned;
        refSqrtPrice = _sqrtPrice();
        refTime = uint64(block.timestamp);
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

    /// @notice The price rise the next buyback tolerates: 2% plus 2% per day since the reference was set.
    function allowedPriceRiseBps() public view returns (uint256) {
        return MAX_PRICE_RISE_BPS + (PRICE_RISE_PER_DAY_BPS * (block.timestamp - refTime)) / 1 days;
    }

    /// @notice Most IMD one buyback spends: 1% of the $Pepes pool's (virtual) IMD reserve at the current price,
    ///         read from the PepesFamily v1 pool through the PoolManager. Zero only when the pool's position is out
    ///         of range, i.e. every $Pepes has been sold back to the pool; the IMD then waits (audit finding 6).
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
