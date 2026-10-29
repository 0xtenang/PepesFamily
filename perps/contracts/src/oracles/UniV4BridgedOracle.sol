// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UniV4SampledOracle, IExtsload} from "./UniV4SampledOracle.sol";
import {IUniswapV3PoolLike} from "./UniV3Oracle.sol";
import {TickRatio} from "../libraries/TickRatio.sol";
import {PoolKey, toPoolId} from "../interfaces/IUniswapV4Minimal.sol";

/// @title UniV4BridgedOracle
/// @notice Price feed for a coin whose liquidity sits in a coin/stablecoin Uniswap V4 pool (UBIK/USDG on Robinhood
///         Chain): the coin's price in the stablecoin, times the stablecoin's price in ETH from a deep ETH/stablecoin
///         Uniswap V3 pool. Keepers record samples exactly as for `UniV4SampledOracle`; each sample is the combined
///         price, so the fast median and the slow average cover both legs.
/// @dev Depth is the stablecoin side of the coin pool's in-range liquidity valued in ETH, and never more than the
///      ETH side of the bridge pool's in-range liquidity. Both are read at the bridge's current tick.
contract UniV4BridgedOracle is UniV4SampledOracle {
    IUniswapV3PoolLike public immutable bridge;
    address public immutable coin;
    address public immutable quote;
    bool public immutable ethIsToken0; // in the bridge pool

    error NotCoinPool();
    error NotBridgePool();
    error OutOfRange();

    /// @param key The coin/quote V4 pool. Its id is computed here, so the listed currencies are the pool's own.
    /// @param bridge_ An ETH (WETH)/quote Uniswap V3 pool.
    constructor(
        IExtsload manager_,
        PoolKey memory key,
        address coin_,
        IUniswapV3PoolLike bridge_,
        address weth,
        uint32 fastWindow_,
        uint32 slowWindow_,
        uint32 minInterval_,
        uint32 maxAge_,
        address owner_
    )
        UniV4SampledOracle(
            manager_, toPoolId(key), key.currency1 == coin_, fastWindow_, slowWindow_, minInterval_, maxAge_, owner_
        )
    {
        // UniV4SampledOracle's `ethIsCurrency0` is read here as "the quote is currency0": it prices the coin in the quote.
        address q = key.currency0 == coin_ ? key.currency1 : key.currency0;
        if ((key.currency0 != coin_ && key.currency1 != coin_) || q == address(0)) revert NotCoinPool();
        address t0 = bridge_.token0();
        address t1 = bridge_.token1();
        if (!((t0 == weth && t1 == q) || (t0 == q && t1 == weth))) revert NotBridgePool();
        bridge = bridge_;
        coin = coin_;
        quote = q;
        ethIsToken0 = t0 == weth;
    }

    function _live() internal view override returns (int24 tick, uint256 depth) {
        (uint160 sqrtPriceX96, int24 raw) = _slot0();
        (, int24 btick,,,,,) = bridge.slot0();
        // the bridge prices token1 in token0; we want ETH per quote unit
        int256 ethPerQuote = ethIsToken0 ? -int256(btick) : int256(btick);
        int256 t = int256(_norm(raw)) + ethPerQuote;
        if (t < -887272 || t > 887272) revert OutOfRange();
        tick = int24(t);

        uint256 quoteDepth = _depth(sqrtPriceX96); // quote-side reserves of the coin pool
        depth = Math.mulDiv(quoteDepth, TickRatio.ratio(ethPerQuote), TickRatio.ONE);
        uint256 bl = IV3Liquidity(address(bridge)).liquidity();
        uint256 s = TickRatio.sqrtRatio(btick); // sqrt(token1 per token0), 18 decimals
        uint256 bridgeEth = ethIsToken0 ? Math.mulDiv(bl, TickRatio.ONE, s) : Math.mulDiv(bl, s, TickRatio.ONE);
        if (bridgeEth < depth) depth = bridgeEth;
    }
}

interface IV3Liquidity {
    function liquidity() external view returns (uint128);
}
