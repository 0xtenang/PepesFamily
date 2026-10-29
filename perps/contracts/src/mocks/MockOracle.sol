// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @notice Settable price feed for tests.
contract MockOracle is IPriceOracle {
    int24 public spot;
    int24 public fast;
    int24 public slow;
    uint256 public liquidity;
    bool public failing;

    constructor(int24 tick, uint256 liquidity_) {
        spot = tick;
        fast = tick;
        slow = tick;
        liquidity = liquidity_;
    }

    function setAll(int24 tick) external {
        spot = tick;
        fast = tick;
        slow = tick;
    }

    function set(int24 spot_, int24 fast_, int24 slow_) external {
        spot = spot_;
        fast = fast_;
        slow = slow_;
    }

    function setLiquidity(uint256 liquidity_) external {
        liquidity = liquidity_;
    }

    function setFailing(bool failing_) external {
        failing = failing_;
    }

    function read() external view returns (int24, int24, int24, uint256) {
        require(!failing, "feed down");
        return (spot, fast, slow, liquidity);
    }
}
