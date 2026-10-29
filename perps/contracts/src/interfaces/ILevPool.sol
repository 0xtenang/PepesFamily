// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice What the exchange needs from the LP pool.
interface ILevPool {
    function cash() external view returns (uint256);
    function donate() external payable;
    function receiveFromExchange() external payable;
    function payToExchange(uint256 amount) external;
}

/// @notice What the LP pool needs from the exchange.
interface ILevExchange {
    function totalMaxWin() external view returns (uint256);
}

/// @notice What the LP pool needs from LevLens: open positions' value to traders, and whether it can be trusted.
interface ILevNav {
    function liabilityRange() external view returns (int256 owedLow, int256 owedHigh, bool blocked);
}

/// @notice A creator-fee router the pool asks to deliver pending fees before it prices shares.
interface IFeeSource {
    function harvest() external;
}
