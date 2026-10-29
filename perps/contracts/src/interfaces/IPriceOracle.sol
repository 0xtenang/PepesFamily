// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Price feed for one listed coin.
/// @dev Prices are Uniswap-style ticks of the coin's price in ETH: price = 1.0001^tick.
interface IPriceOracle {
    /// @return spotTick Live price.
    /// @return fastTick Short time-weighted average (about a minute).
    /// @return slowTick Long time-weighted average (about half an hour).
    /// @return liquidityEth ETH held on the ETH side of the coin's pool.
    function read() external view returns (int24 spotTick, int24 fastTick, int24 slowTick, uint256 liquidityEth);
}
