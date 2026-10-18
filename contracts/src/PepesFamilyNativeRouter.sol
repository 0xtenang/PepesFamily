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
import {IPepesFamily, PermitHelper} from "./PepesFamilyRouter.sol";

/// @notice The chain's wrapped native coin (WETH, WBNB, WHYPE: WETH9).
interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title PepesFamilyNativeRouter
/// @notice For a launchpad whose pair asset is the chain's wrapped native coin (WETH on Ethereum, WBNB on BNB Smart
///         Chain, WHYPE on HyperEVM): trade its tokens with the native coin itself in one transaction. Buying wraps
///         the coin sent and swaps it for the token; selling swaps the token for the wrapped coin and unwraps it.
///         Deployed by PepesFamily in place of PepesFamilyEthRouter (same functions, so wallets and the website use
///         either the same way). The PepesFamily hook charges its 4% exactly as for any other swap. Holds nothing
///         between transactions.
contract PepesFamilyNativeRouter is IUnlockCallback {
    using SafeTransfer for address;

    error NotPoolManager();
    error NotPair();
    error Slippage();
    error Expired();
    error BadAmount();
    error NotWrapped();

    IPoolManager public immutable poolManager;
    IPepesFamily public immutable pad;
    /// @notice The wrapped native coin: the launchpad's pair asset.
    address public immutable wrapped;

    struct Route {
        address user;
        address token;
        bool isBuy;
        uint256 amountIn;
        uint256 minOut;
    }

    constructor(IPoolManager poolManager_, address pad_, address wrapped_) {
        poolManager = poolManager_;
        pad = IPepesFamily(pad_);
        wrapped = wrapped_;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /// @dev Only the wrapped coin pays native coin in (unwrapping a sale).
    receive() external payable {
        if (msg.sender != wrapped) revert NotWrapped();
    }

    /// @notice Buy a token with the native coin (send it as msg.value). The name matches PepesFamilyEthRouter.
    function buyWithEth(address token, uint256 minTokensOut, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
        returns (uint256 tokensOut)
    {
        if (msg.value == 0) revert BadAmount();
        _checkPair(token);
        IWrappedNative(wrapped).deposit{value: msg.value}();
        tokensOut = abi.decode(
            poolManager.unlock(abi.encode(Route(msg.sender, token, true, msg.value, minTokensOut))), (uint256)
        );
        // An exact-input swap spends everything, unless the pool ran out of liquidity: refund what's left.
        uint256 left = _wrappedBalance();
        if (left > 0) {
            IWrappedNative(wrapped).withdraw(left);
            address(0).transferOut(msg.sender, left);
        }
    }

    /// @notice Sell a token for the native coin. Approve this contract for `tokenAmount` first.
    function sellForEth(address token, uint256 tokenAmount, uint256 minEthOut, uint256 deadline)
        external
        checkDeadline(deadline)
        returns (uint256 ethOut)
    {
        ethOut = _sell(token, tokenAmount, minEthOut);
    }

    /// @notice Same as `sellForEth`, with a gasless EIP-2612 approval signed for this router.
    function sellForEthWithPermit(
        address token,
        uint256 tokenAmount,
        uint256 minEthOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external checkDeadline(deadline) returns (uint256 ethOut) {
        if (tokenAmount == 0 || tokenAmount > uint256(type(int256).max)) revert BadAmount();
        _checkPair(token);
        PermitHelper.permit(token, tokenAmount, deadline, v, r, s);
        ethOut = _sell(token, tokenAmount, minEthOut);
    }

    function _sell(address token, uint256 tokenAmount, uint256 minEthOut) internal returns (uint256 ethOut) {
        if (tokenAmount == 0 || tokenAmount > uint256(type(int256).max)) revert BadAmount();
        _checkPair(token);
        ethOut = abi.decode(
            poolManager.unlock(abi.encode(Route(msg.sender, token, false, tokenAmount, minEthOut))), (uint256)
        );
        IWrappedNative(wrapped).withdraw(ethOut);
        address(0).transferOut(msg.sender, ethOut);
    }

    function _checkPair(address token) internal view {
        (address quote,,,,) = pad.launches(token);
        if (quote != wrapped) revert NotPair();
    }

    function _wrappedBalance() internal view returns (uint256 bal) {
        (bool ok, bytes memory data) = wrapped.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        if (ok && data.length >= 32) bal = abi.decode(data, (uint256));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Route memory r = abi.decode(raw, (Route));
        PoolKey memory key = pad.poolKey(r.token);
        bool wIs0 = Currency.unwrap(key.currency0) == wrapped;

        uint256 out;
        if (r.isBuy) {
            // wrapped coin -> token (the PepesFamily hook takes its fee here)
            BalanceDelta d = _swap(key, wIs0, r.amountIn, abi.encode(r.user));
            (int128 wDelta, int128 tokDelta) = wIs0 ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
            out = uint256(int256(tokDelta));
            if (out < r.minOut || out == 0) revert Slippage();
            uint256 wIn = uint256(int256(-wDelta));
            // pay the wrapped coin this router holds (wrapped from msg.value)
            poolManager.sync(Currency.wrap(wrapped));
            wrapped.transferOut(address(poolManager), wIn);
            poolManager.settle();
            pad.flush(r.token); // credit holders before the buyer receives tokens
            poolManager.take(Currency.wrap(r.token), r.user, out);
        } else {
            // token -> wrapped coin
            BalanceDelta d = _swap(key, !wIs0, r.amountIn, abi.encode(r.user));
            (int128 wDelta, int128 tokDelta) = wIs0 ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
            out = uint256(int256(wDelta));
            if (out < r.minOut || out == 0) revert Slippage();
            uint256 tokIn = uint256(int256(-tokDelta));
            poolManager.sync(Currency.wrap(r.token));
            r.token.transferFrom(r.user, address(poolManager), tokIn);
            poolManager.settle();
            pad.flush(r.token); // seller's tokens have left; credit holders
            // the wrapped coin comes here, to be unwrapped for the seller
            poolManager.take(Currency.wrap(wrapped), address(this), out);
        }
        return abi.encode(out);
    }

    /// @dev `hookData` carries the user, so the PepesFamily hook credits the right buyer or seller.
    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        return poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );
    }
}
