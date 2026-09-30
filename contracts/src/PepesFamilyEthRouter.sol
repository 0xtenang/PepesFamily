// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {SafeTransfer} from "./lib/SafeTransfer.sol";
import {IPepesFamily} from "./PepesFamilyRouter.sol";

/// @title PepesFamilyEthRouter
/// @notice Lets people trade IMD-paired PepesFamily tokens with ETH in one transaction, by routing through the
///         Uniswap v4 IMD/ETH pool: ETH -> IMD -> token (buy) and token -> IMD -> ETH (sell).
///         The PepesFamily hook charges its 4% on the IMD leg exactly as for any other swap.
contract PepesFamilyEthRouter is IUnlockCallback {
    using SafeTransfer for address;

    error NotPoolManager();
    error NotImdPair();
    error Slippage();
    error Expired();
    error BadAmount();

    IPoolManager public immutable poolManager;
    IPepesFamily public immutable pad;
    address public immutable IMD;

    /// @dev Uniswap v4 IMD/ETH pool used for the ETH leg (ETH is currency0, IMD currency1).
    uint24 public immutable imdEthFee;
    int24 public immutable imdEthTickSpacing;
    address public immutable imdEthHooks;

    struct Route {
        address user;
        address token;
        bool isBuy;
        uint256 amountIn;
        uint256 minOut;
    }

    constructor(IPoolManager poolManager_, address pad_, address imd, uint24 fee, int24 tickSpacing, address hooks) {
        poolManager = poolManager_;
        pad = IPepesFamily(pad_);
        IMD = imd;
        imdEthFee = fee;
        imdEthTickSpacing = tickSpacing;
        imdEthHooks = hooks;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    function imdEthKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(IMD),
            fee: imdEthFee,
            tickSpacing: imdEthTickSpacing,
            hooks: IHooks(imdEthHooks)
        });
    }

    /// @notice Buy an IMD-paired token with ETH (send it as msg.value).
    function buyWithEth(address token, uint256 minTokensOut, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
        returns (uint256 tokensOut)
    {
        if (msg.value == 0) revert BadAmount();
        _checkImdPair(token);
        tokensOut = abi.decode(
            poolManager.unlock(abi.encode(Route(msg.sender, token, true, msg.value, minTokensOut))), (uint256)
        );
        // Refund ETH the IMD/ETH pool didn't take (only if it ran out of liquidity).
        if (address(this).balance > 0) address(0).transferOut(msg.sender, address(this).balance);
    }

    /// @notice Sell an IMD-paired token for ETH. Approve this contract for `tokenAmount` first.
    function sellForEth(address token, uint256 tokenAmount, uint256 minEthOut, uint256 deadline)
        external
        checkDeadline(deadline)
        returns (uint256 ethOut)
    {
        if (tokenAmount == 0 || tokenAmount > uint256(type(int256).max)) revert BadAmount();
        _checkImdPair(token);
        ethOut = abi.decode(
            poolManager.unlock(abi.encode(Route(msg.sender, token, false, tokenAmount, minEthOut))), (uint256)
        );
    }

    function _checkImdPair(address token) internal view {
        (address quote,,,,) = pad.launches(token);
        if (quote != IMD) revert NotImdPair();
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Route memory r = abi.decode(raw, (Route));
        PoolKey memory tokenKey = pad.poolKey(r.token);
        bool imdIs0 = Currency.unwrap(tokenKey.currency0) == IMD;

        uint256 out;
        if (r.isBuy) {
            // ETH -> IMD
            BalanceDelta d1 = _swap(imdEthKey(), true, r.amountIn);
            uint256 ethIn = uint256(int256(-d1.amount0()));
            uint256 imdOut = uint256(int256(d1.amount1()));
            // IMD -> token (the PepesFamily hook takes its fee here)
            BalanceDelta d2 = _swap(tokenKey, imdIs0, imdOut);
            (int128 imdDelta, int128 tokDelta) = imdIs0 ? (d2.amount0(), d2.amount1()) : (d2.amount1(), d2.amount0());
            out = uint256(int256(tokDelta));
            if (out < r.minOut || out == 0) revert Slippage();

            poolManager.settle{value: ethIn}();
            // IMD credited by leg 1 and spent by leg 2 net out inside the PoolManager; return any remainder.
            uint256 imdLeft = imdOut - uint256(int256(-imdDelta));
            if (imdLeft > 0) poolManager.take(Currency.wrap(IMD), r.user, imdLeft);

            pad.flush(r.token); // credit holders before the buyer receives tokens
            poolManager.take(Currency.wrap(r.token), r.user, out);
        } else {
            // token -> IMD
            BalanceDelta d1 = _swap(tokenKey, !imdIs0, r.amountIn);
            (int128 imdDelta, int128 tokDelta) = imdIs0 ? (d1.amount0(), d1.amount1()) : (d1.amount1(), d1.amount0());
            uint256 imdOut = uint256(int256(imdDelta));
            uint256 tokIn = uint256(int256(-tokDelta));

            poolManager.sync(Currency.wrap(r.token));
            r.token.transferFrom(r.user, address(poolManager), tokIn);
            poolManager.settle();
            pad.flush(r.token); // seller's tokens have left; credit holders

            // IMD -> ETH
            BalanceDelta d2 = _swap(imdEthKey(), false, imdOut);
            out = uint256(int256(d2.amount0()));
            if (out < r.minOut || out == 0) revert Slippage();
            uint256 imdLeft = imdOut - uint256(int256(-d2.amount1()));
            if (imdLeft > 0) poolManager.take(Currency.wrap(IMD), r.user, imdLeft);
            poolManager.take(Currency.wrap(address(0)), r.user, out);
        }
        return abi.encode(out);
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (BalanceDelta) {
        return poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
    }
}
