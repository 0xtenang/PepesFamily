// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

contract MockIMD {
    string public name = "Identity.md";
    string public symbol = "IMD";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    /// @dev Simulates a balance dropping outside a transfer (e.g. a rebasing or seized balance).
    function slash(address who, uint256 amt) external {
        balanceOf[who] -= amt;
    }

    function approve(address s, uint256 amt) external returns (bool) {
        allowance[msg.sender][s] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Stands in for $Pepes: any ERC20 the buyback router can mint.
contract MockPepes is MockIMD {}

/// @dev Stands in for the PepesFamily v1 router and pad: buys "Pepes" with IMD at 1,000 Pepes per IMD for
///      msg.sender, and reports a real (plain) $Pepes/IMD pool so the buyback cap can read its depth.
contract MockPepesRouter {
    MockIMD immutable imd;
    MockPepes immutable pepes;
    PoolKey key;

    constructor(MockIMD imd_, MockPepes pepes_) {
        imd = imd_;
        pepes = pepes_;
    }

    function setKey(PoolKey memory k) external {
        key = k;
    }

    function pad() external view returns (address) {
        return address(this);
    }

    function poolKey(address) external view returns (PoolKey memory) {
        return key;
    }

    function buy(address token, uint256 amountIn, uint256 minOut, uint256 deadline) external payable returns (uint256 out) {
        require(token == address(pepes) && block.timestamp <= deadline, "bad");
        imd.transferFrom(msg.sender, address(this), amountIn);
        out = amountIn * 1000;
        require(out >= minOut, "slippage");
        pepes.mint(msg.sender, out);
    }
}
