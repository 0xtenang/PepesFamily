// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SafeTransfer} from "./lib/SafeTransfer.sol";

/// @notice The chain's wrapped native coin (WHYPE on Elysium: WETH9).
interface IWrapped {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title PepesFamilySwapRouter
/// @notice Buy and sell any token in a Uniswap v4 pool paired with the chain's coin (HYPE on Elysium), whether the
///         pool holds the coin itself (currency0 = address(0)) or its wrapped form (WHYPE): one exact-input swap,
///         the coin in, the token out, or the token in, the coin out. For tokens launched elsewhere; PepesFamily's own
///         launches keep their own routers. No owner, no fee, no state: it holds nothing between transactions.
/// @dev The pool key comes from the caller, so a pool's hook is whatever that pool chose; the swap is settled from the
///      delta the PoolManager returns (hook adjustments included), never paying in more than the caller sent, and
///      `minOut` bounds what the caller accepts. Pools whose hook would leave the caller owing the output side are
///      refused.
contract PepesFamilySwapRouter is IUnlockCallback {
    using SafeTransfer for address;

    error NotPoolManager();
    error NotCoinPair();
    error Slippage();
    error Expired();
    error BadAmount();
    error BadDelta();

    IPoolManager public immutable poolManager;
    /// @notice The chain's wrapped coin.
    address public immutable wrapped;

    struct Route {
        address user;
        PoolKey key;
        bool buy;
        uint256 amountIn;
        uint256 minOut;
    }

    constructor(IPoolManager poolManager_, address wrapped_) {
        poolManager = poolManager_;
        wrapped = wrapped_;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /// @dev The coin arrives from the PoolManager (a native pool's output) or the wrapped coin (unwrapping).
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != wrapped) revert NotCoinPair();
    }

    /// @notice Buy the token of `key`'s pool with the coin sent as msg.value. Whatever the pool can't fill is refunded.
    function buy(PoolKey calldata key, uint256 minOut, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
        returns (uint256 out)
    {
        if (msg.value == 0 || msg.value > uint256(type(int256).max)) revert BadAmount();
        if (!_native(key)) IWrapped(wrapped).deposit{value: msg.value}();
        out = abi.decode(poolManager.unlock(abi.encode(Route(msg.sender, key, true, msg.value, minOut))), (uint256));
        // an exact-input swap spends it all unless the pool ran out of liquidity: refund the rest, as the coin
        if (!_native(key)) {
            uint256 w = _wrappedBalance();
            if (w > 0) IWrapped(wrapped).withdraw(w);
        }
        address(0).transferOut(msg.sender, address(this).balance);
    }

    /// @notice Sell `amountIn` of the token of `key`'s pool for the coin. Approve this contract for it first.
    function sell(PoolKey calldata key, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        checkDeadline(deadline)
        returns (uint256 out)
    {
        if (amountIn == 0 || amountIn > uint256(type(int256).max)) revert BadAmount();
        out = abi.decode(poolManager.unlock(abi.encode(Route(msg.sender, key, false, amountIn, minOut))), (uint256));
        if (!_native(key)) IWrapped(wrapped).withdraw(out);
        address(0).transferOut(msg.sender, out);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Route memory r = abi.decode(raw, (Route));
        PoolKey memory key = r.key;
        bool native = _native(key);
        // the coin's side of the pool (native: always currency0, as address(0) sorts first)
        bool coinIs0 = native || Currency.unwrap(key.currency0) == wrapped;
        if (!native && !coinIs0 && Currency.unwrap(key.currency1) != wrapped) revert NotCoinPair();
        Currency coin = coinIs0 ? key.currency0 : key.currency1;
        Currency token = coinIs0 ? key.currency1 : key.currency0;

        // buying: coin in (zeroForOne when the coin is currency0); selling: the other way
        bool zeroForOne = r.buy == coinIs0;
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(r.amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 inDelta, int128 outDelta) = zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        if (inDelta > 0 || outDelta < 0) revert BadDelta(); // a hook that leaves the caller owing the output side
        uint256 payIn = uint256(int256(-inDelta));
        uint256 out = uint256(int256(outDelta));
        if (payIn > r.amountIn) revert BadDelta();
        if (out == 0 || out < r.minOut) revert Slippage();

        if (r.buy) {
            if (native) {
                poolManager.settle{value: payIn}();
            } else {
                poolManager.sync(coin);
                wrapped.transferOut(address(poolManager), payIn);
                poolManager.settle();
            }
            poolManager.take(token, r.user, out);
        } else {
            poolManager.sync(token);
            Currency.unwrap(token).transferFrom(r.user, address(poolManager), payIn);
            poolManager.settle();
            poolManager.take(coin, address(this), out); // paid on to the seller as the coin
        }
        return abi.encode(out);
    }

    function _native(PoolKey memory key) internal pure returns (bool) {
        return Currency.unwrap(key.currency0) == address(0);
    }

    function _wrappedBalance() internal view returns (uint256 bal) {
        (bool ok, bytes memory data) = wrapped.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        if (ok && data.length >= 32) bal = abi.decode(data, (uint256));
    }
}
