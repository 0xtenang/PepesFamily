// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Uniswap V4 PoolManager stand-in: raw storage reads, laid out like the real one.
contract MockPoolManager {
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    mapping(bytes32 => bytes32) internal _slots;

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }

    function setSlot0(bytes32 poolId, uint160 sqrtPriceX96, int24 tick) external {
        bytes32 slot = keccak256(abi.encodePacked(poolId, POOLS_SLOT));
        _slots[slot] = bytes32(uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160));
    }

    function setLiquidity(bytes32 poolId, uint128 liquidity) external {
        bytes32 slot = keccak256(abi.encodePacked(poolId, POOLS_SLOT));
        _slots[bytes32(uint256(slot) + 3)] = bytes32(uint256(liquidity));
    }
}
