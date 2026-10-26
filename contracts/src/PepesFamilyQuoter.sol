// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title PepesFamilyQuoter
/// @notice Quotes an exact-input swap in one Uniswap v4 pool by doing it inside an unlock and reverting with the
///         result, as Uniswap's V4Quoter does, and with the same `quoteExactInputSingle` interface, so the website
///         uses either. For chains without Uniswap's periphery contracts (the Elysium testnet). Never holds or moves
///         anything: every quote reverts inside the PoolManager. Not meant to be called on-chain by other contracts
///         (it isn't a view function).
contract PepesFamilyQuoter is IUnlockCallback {
    error NotPoolManager();
    error QuoteSwap(uint256 amountOut);
    error UnexpectedRevert(bytes reason);

    IPoolManager public immutable poolManager;

    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @notice What `exactAmount` in buys in `poolKey` (hook fees included), and roughly the gas the swap takes.
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try poolManager.unlock(abi.encode(params)) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            if (reason.length == 36 && bytes4(reason) == QuoteSwap.selector) {
                assembly {
                    amountOut := mload(add(reason, 36))
                }
                return (amountOut, gasEstimate);
            }
            revert UnexpectedRevert(reason);
        }
        revert UnexpectedRevert(""); // unreachable: the callback always reverts
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        QuoteExactSingleParams memory p = abi.decode(data, (QuoteExactSingleParams));
        BalanceDelta d = poolManager.swap(
            p.poolKey,
            SwapParams({
                zeroForOne: p.zeroForOne,
                amountSpecified: -int256(uint256(p.exactAmount)),
                sqrtPriceLimitX96: p.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            p.hookData
        );
        int128 out = p.zeroForOne ? d.amount1() : d.amount0();
        revert QuoteSwap(uint256(uint128(out)));
    }
}
