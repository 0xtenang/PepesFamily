// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The few Uniswap V4 types and PoolManager calls MemeLev uses, written out so we don't vendor v4-core.
/// @dev Checked on 2026-10-29 against Uniswap/v4-core main (src/interfaces/IPoolManager.sol, src/types/PoolKey.sol,
///      src/types/PoolOperation.sol, src/types/BalanceDelta.sol, src/libraries/TickMath.sol) and against the
///      deployed PoolManager on Robinhood Chain (0x8366a39cc670b4001a1121b8f6a443a643e40951): every selector
///      below is in its dispatcher, and the fork tests in test/fork run swaps through it.
///      `Currency` and `IHooks` are plain addresses here; the ABI encoding is the same.

/// @dev Same field order as v4-core. The pool id is keccak256(abi.encode(key)).
struct PoolKey {
    address currency0; // the lower address; address(0) is native ETH
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev amountSpecified < 0 is exact input, > 0 is exact output.
struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @dev Two int128 packed in one int256: amount0 in the upper 128 bits, amount1 in the lower 128 bits.
///      Positive means the pool owes the caller, negative means the caller owes the pool.
type BalanceDelta is int256;

using {amount0, amount1} for BalanceDelta global;

function amount0(BalanceDelta d) pure returns (int128) {
    return int128(BalanceDelta.unwrap(d) >> 128); // arithmetic shift, like v4-core's sar
}

function amount1(BalanceDelta d) pure returns (int128) {
    return int128(BalanceDelta.unwrap(d)); // low 128 bits, sign-extended, like v4-core's signextend(15, ...)
}

/// @dev v4-core TickMath bounds. A zeroForOne swap needs a limit above MIN, a oneForZero swap one below MAX.
uint160 constant MIN_SQRT_PRICE = 4295128739;
uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

function toPoolId(PoolKey memory key) pure returns (bytes32) {
    return keccak256(abi.encode(key));
}

interface IPoolManager {
    /// @notice Calls `unlockCallback(data)` on msg.sender; every currency delta must be zero when it returns.
    function unlock(bytes calldata data) external returns (bytes memory);

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta swapDelta);

    /// @notice For native ETH it only clears the synced currency, so the next `settle` counts msg.value.
    function sync(address currency) external;

    /// @notice Pays what the caller owes in the synced currency (msg.value for native ETH).
    function settle() external payable returns (uint256 paid);

    function take(address currency, address to, uint256 amount) external;

    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
