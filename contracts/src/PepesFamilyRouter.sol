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

/// @dev PepesFamily v5's split of the 3% (creator / holders / burn, basis points of the trade, sum 300).
struct FeeSplit {
    uint16 creatorBps;
    uint16 holderBps;
    uint16 burnBps;
}

interface IPepesFamily {
    function poolKey(address token) external view returns (PoolKey memory);
    function launches(address token)
        external
        view
        returns (address quote, address creator, uint64 createdAt, uint64 createdBlock, bool quoteIsCurrency0);
    function launchForWithSplit(
        address creator,
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address quote,
        FeeSplit calldata split
    ) external returns (address token);
    function flush(address token) external;
}

interface IERC20Permit {
    function permit(address holder, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
    function allowance(address holder, address spender) external view returns (uint256);
}

library PermitHelper {
    error PermitFailed();

    /// @dev Applies `msg.sender`'s permit for this contract. If someone front-ran it with the same signature the
    ///      call reverts, but the allowance is already set, so that case is accepted instead of failing the trade.
    function permit(address token, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) internal {
        try IERC20Permit(token).permit(msg.sender, address(this), amount, deadline, v, r, s) {}
        catch {
            if (IERC20Permit(token).allowance(msg.sender, address(this)) < amount) revert PermitFailed();
        }
    }
}

/// @title PepesFamilyRouter
/// @notice Simple buy/sell/launch entry points for PepesFamily tokens on Uniswap v4. Deployed by PepesFamily.
///         Fees are charged by the PepesFamily hook exactly as for any other router; this router also forwards the
///         holder share to the token contract on every trade, so holders are credited immediately.
contract PepesFamilyRouter is IUnlockCallback {
    using SafeTransfer for address;

    error NotPoolManager();
    error Slippage();
    error Expired();
    error BadAmount();

    IPoolManager public immutable poolManager;
    IPepesFamily public immutable pad;

    struct SwapData {
        address user;
        address token;
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 minOut;
    }

    constructor(IPoolManager poolManager_, address pad_) {
        poolManager = poolManager_;
        pad = IPepesFamily(pad_);
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /// @notice Launches a token (creator = msg.sender) with the default split (all 3% to holders) and optionally buys
    ///         `initialBuy` of quote in the same tx. For IMD launches approve this router for `initialBuy` IMD first.
    function launch(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address quote,
        uint256 initialBuy,
        uint256 minTokensOut
    ) external payable returns (address token, uint256 tokensOut) {
        token = pad.launchForWithSplit(msg.sender, name, symbol, metadata, quote, FeeSplit(0, 300, 0));
        if (initialBuy > 0) tokensOut = _swap(token, true, initialBuy, minTokensOut);
        else if (msg.value != 0) revert BadAmount();
    }

    /// @notice Same as `launch`, with the creator's split of the 3% (PepesFamily v5).
    function launchWithSplit(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address quote,
        FeeSplit calldata split,
        uint256 initialBuy,
        uint256 minTokensOut
    ) external payable returns (address token, uint256 tokensOut) {
        token = pad.launchForWithSplit(msg.sender, name, symbol, metadata, quote, split);
        if (initialBuy > 0) tokensOut = _swap(token, true, initialBuy, minTokensOut);
        else if (msg.value != 0) revert BadAmount();
    }

    /// @notice Buy with the pool's quote asset: send ETH as msg.value, or approve this router for IMD.
    function buy(address token, uint256 amountIn, uint256 minTokensOut, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
        returns (uint256 tokensOut)
    {
        return _swap(token, true, amountIn, minTokensOut);
    }

    /// @notice Sell tokens for the pool's quote asset. Approve this router for `tokenAmount` first,
    ///         or use `sellWithPermit`.
    function sell(address token, uint256 tokenAmount, uint256 minQuoteOut, uint256 deadline)
        external
        checkDeadline(deadline)
        returns (uint256 quoteOut)
    {
        return _swap(token, false, tokenAmount, minQuoteOut);
    }

    /// @notice Sell with a gasless EIP-2612 approval signed for this router (`value` >= `tokenAmount`).
    function sellWithPermit(
        address token,
        uint256 tokenAmount,
        uint256 minQuoteOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external checkDeadline(deadline) returns (uint256 quoteOut) {
        PermitHelper.permit(token, tokenAmount, deadline, v, r, s);
        return _swap(token, false, tokenAmount, minQuoteOut);
    }

    function _swap(address token, bool isBuy, uint256 amountIn, uint256 minOut) internal returns (uint256 out) {
        if (amountIn == 0 || amountIn > uint256(type(int256).max)) revert BadAmount();
        (address quote,,,, bool quoteIs0) = pad.launches(token);
        bool payingEth = isBuy && quote == address(0);
        if (payingEth ? msg.value != amountIn : msg.value != 0) revert BadAmount();

        SwapData memory data = SwapData({
            user: msg.sender,
            token: token,
            key: pad.poolKey(token),
            zeroForOne: isBuy == quoteIs0, // buying = paying quote in
            amountIn: amountIn,
            minOut: minOut
        });
        out = abi.decode(poolManager.unlock(abi.encode(data)), (uint256));

        // Refund unspent ETH (only possible if the swap hit the end of the curve).
        if (payingEth && address(this).balance > 0) address(0).transferOut(msg.sender, address(this).balance);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        SwapData memory d = abi.decode(raw, (SwapData));

        BalanceDelta delta = poolManager.swap(
            d.key,
            SwapParams({
                zeroForOne: d.zeroForOne,
                amountSpecified: -int256(d.amountIn),
                sqrtPriceLimitX96: d.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            abi.encode(d.user)
        );
        (Currency cIn, Currency cOut) = d.zeroForOne ? (d.key.currency0, d.key.currency1) : (d.key.currency1, d.key.currency0);
        (int128 dIn, int128 dOut) = d.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 owed = uint256(int256(-dIn));
        uint256 out = uint256(int256(dOut));
        if (out < d.minOut || out == 0) revert Slippage();

        // Pay the input.
        if (cIn.isAddressZero()) {
            poolManager.settle{value: owed}();
        } else {
            poolManager.sync(cIn);
            Currency.unwrap(cIn).transferFrom(d.user, address(poolManager), owed);
            poolManager.settle();
        }

        // Credit holders before the buyer receives tokens (and after the seller's tokens left),
        // so a trader never earns from their own trade.
        pad.flush(d.token);

        poolManager.take(cOut, d.user, out);
        return abi.encode(out);
    }
}
