// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBuybackExecutor} from "../interfaces/IBuybackExecutor.sol";
import {IPonsLaunchFactory} from "../interfaces/IPons.sol";
import {
    BalanceDelta,
    IPoolManager,
    IUnlockCallback,
    MIN_SQRT_PRICE,
    PoolKey,
    SwapParams
} from "../interfaces/IUniswapV4Minimal.sol";

/// @title PonsV4BuybackExecutor
/// @notice Buys a graduated Pons V2 token with native ETH on its Uniswap V4 pool, for the creator-fee router.
/// @dev Graduated Pons pools are keyed (ETH, token, poolFee, tickSpacing, PonsV2MemeHook), with fee and tick
///      spacing snapshotted per launch in the factory. The hook takes its base fee plus the launch's creator tax
///      in `afterSwap`, out of the swap's unspecified side:
///      - `buy` (exact input) pays the fee in the token: the buyer receives the pool output less
///        (hookFeeBps + creatorTaxBps), and the hook later sells those tokens back into the pool to convert them.
///      - `buyExactOut` (exact output) pays the fee in ETH on top of the pool input, so nothing is sold back
///        later and the same ETH buys slightly more. The fork tests measure both.
///      There is no price limit beyond the edge of the curve: the caller's `minOut` (or exact `amountOut`) is
///      the only slippage bound, so the caller must size it from an independent price.
contract PonsV4BuybackExecutor is IBuybackExecutor, IUnlockCallback {
    /// @dev What `unlockCallback` needs; the swap is always ETH (currency0) for the token (currency1).
    struct SwapCall {
        PoolKey key;
        int256 amountSpecified; // < 0 exact ETH in, > 0 exact tokens out
        uint256 minOut;
        uint256 maxIn;
        address to;
    }

    IPoolManager public immutable poolManager;
    IPonsLaunchFactory public immutable factory;
    address public immutable hook;
    /// @notice The only address that may buy (the creator-fee router).
    address public immutable caller;

    event Bought(address indexed token, address indexed to, uint256 ethIn, uint256 tokensOut, bool exactOut);

    error NotCaller();
    error NotPoolManager();
    error ZeroAddress();
    error BadAmount();
    error MinOutRequired();
    error NotGraduated(address token);
    error NotEthPair(address token);
    error UnexpectedDelta(int128 amount0, int128 amount1);
    error InsufficientOutput(uint256 got, uint256 minOut);
    error ExcessiveInput(uint256 owed, uint256 maxIn);
    error RefundFailed();

    modifier onlyCaller() {
        if (msg.sender != caller) revert NotCaller();
        _;
    }

    constructor(IPoolManager poolManager_, IPonsLaunchFactory factory_, address hook_, address caller_) {
        if (
            address(poolManager_) == address(0) || address(factory_) == address(0) || hook_ == address(0)
                || caller_ == address(0)
        ) revert ZeroAddress();
        poolManager = poolManager_;
        factory = factory_;
        hook = hook_;
        caller = caller_;
    }

    /// @inheritdoc IBuybackExecutor
    /// @dev Exact input. Unspent ETH (only if the swap ran out of curve) goes back to the caller.
    function buy(address token, uint256 minOut, address to) external payable onlyCaller returns (uint256 tokensOut) {
        if (msg.value == 0 || msg.value > uint256(uint128(type(int128).max))) revert BadAmount();
        if (minOut == 0) revert MinOutRequired();
        if (to == address(0)) revert ZeroAddress();
        uint256 ethIn;
        (ethIn, tokensOut) = _swap(
            SwapCall({
                key: poolKey(token), amountSpecified: -int256(msg.value), minOut: minOut, maxIn: msg.value, to: to
            })
        );
        _refund(msg.value - ethIn);
        emit Bought(token, to, ethIn, tokensOut, false);
    }

    /// @notice Buys exactly `amountOut` tokens for at most `msg.value` ETH and returns the ETH left over.
    /// @dev Exact output: the hook charges its fee and the creator tax in ETH, on top of the pool input.
    function buyExactOut(address token, uint256 amountOut, address to)
        external
        payable
        onlyCaller
        returns (uint256 ethIn)
    {
        if (msg.value == 0 || amountOut == 0 || amountOut > uint256(uint128(type(int128).max))) {
            revert BadAmount();
        }
        if (to == address(0)) revert ZeroAddress();
        uint256 tokensOut;
        (ethIn, tokensOut) = _swap(
            SwapCall({
                key: poolKey(token), amountSpecified: int256(amountOut), minOut: amountOut, maxIn: msg.value, to: to
            })
        );
        _refund(msg.value - ethIn);
        emit Bought(token, to, ethIn, tokensOut, true);
    }

    /// @notice The V4 pool key of a graduated, ETH-paired Pons launch.
    function poolKey(address token) public view returns (PoolKey memory) {
        IPonsLaunchFactory.LaunchedToken memory t = factory.getLaunchedToken(token);
        if (!t.exists || t.phase != IPonsLaunchFactory.GraduationPhase.PoolCreated) revert NotGraduated(token);
        if (t.pairToken != address(0)) revert NotEthPair(token);
        return
            PoolKey({currency0: address(0), currency1: token, fee: t.poolFee, tickSpacing: t.tickSpacing, hooks: hook});
    }

    /// @dev Swaps, then pays the ETH owed and takes the tokens straight to `to`. Checks run before any payment.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        SwapCall memory c = abi.decode(data, (SwapCall));

        BalanceDelta d = poolManager.swap(
            c.key,
            SwapParams({zeroForOne: true, amountSpecified: c.amountSpecified, sqrtPriceLimitX96: MIN_SQRT_PRICE + 1}),
            ""
        );
        int128 d0 = d.amount0();
        int128 d1 = d.amount1();
        if (d0 > 0 || d1 < 0) revert UnexpectedDelta(d0, d1);
        uint256 ethIn = uint256(uint128(-d0));
        uint256 out = uint256(uint128(d1));
        if (out < c.minOut) revert InsufficientOutput(out, c.minOut);
        if (ethIn > c.maxIn) revert ExcessiveInput(ethIn, c.maxIn);

        if (ethIn != 0) {
            // sync first: a stale synced currency would send native value down the ERC-20 branch and revert.
            poolManager.sync(address(0));
            poolManager.settle{value: ethIn}();
        }
        poolManager.take(c.key.currency1, c.to, out);
        return abi.encode(ethIn, out);
    }

    function _swap(SwapCall memory c) internal returns (uint256 ethIn, uint256 tokensOut) {
        (ethIn, tokensOut) = abi.decode(poolManager.unlock(abi.encode(c)), (uint256, uint256));
    }

    /// @dev After `unlock` returns, so the caller's receive() never runs inside the PoolManager's unlock.
    function _refund(uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert RefundFailed();
    }
}
