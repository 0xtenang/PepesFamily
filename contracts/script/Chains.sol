// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PepesFamily} from "../src/PepesFamily.sol";

/// @notice Per-chain settings for deploying PepesFamily (the contracts are the same on every chain).
library Chains {
    address internal constant OWNER = 0x3c8A4d94B3219F6633F2cC94094f4765b30c691C;

    struct Config {
        string name;
        IPoolManager poolManager;
        address imd;
        address quoter; // Uniswap V4Quoter, used by tests and the website
        PepesFamily.ImdEthPool imdEthPool; // the Uniswap v4 ETH/IMD pool the ETH router trades through
    }

    function get(uint256 chainId) internal pure returns (Config memory c) {
        if (chainId == 4663) {
            // Robinhood Chain: ETH/IMD pool 0xd2fc01ee…8f02 (1% fee, tick spacing 100, no hooks)
            return Config(
                "robinhood",
                IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951),
                0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127,
                0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94,
                PepesFamily.ImdEthPool({fee: 10_000, tickSpacing: 100, hooks: address(0)})
            );
        }
        if (chainId == 1) {
            // Ethereum: IMD's home chain; ETH/IMD pool 0xb07d640f…bfb3 (1% fee, tick spacing 200, no hooks)
            return Config(
                "ethereum",
                IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90),
                0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7,
                0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203,
                PepesFamily.ImdEthPool({fee: 10_000, tickSpacing: 200, hooks: address(0)})
            );
        }
        revert("Chains: unsupported chain");
    }
}
