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

    /// @notice One launchpad: a chain and the single pair asset its launches use (each pair asset is its own
    ///         deployment of the same contracts). `ethPool` is the Uniswap v4 ETH/asset pool the ETH router trades
    ///         through; tickSpacing 0 means the asset is the chain's wrapped native coin (a wrap/unwrap router).
    struct Pad {
        string key; // e.g. "ethereum-pepe": deployments/<key>.json
        uint256 chainId;
        IPoolManager poolManager;
        address quote;
        address quoter;
        PepesFamily.ImdEthPool ethPool;
        uint256 startMcap; // starting market cap, in quote wei (about $3,700 on 2026-10-18, like IMD's 635)
    }

    /// @notice The launchpads added on 2026-10-18: $PEPE and ETH on Ethereum, ETH and $CASHCAT on Robinhood Chain (and the
    ///         two IMD ones, for completeness).
    function pad(string memory key) internal pure returns (Pad memory) {
        bytes32 k = keccak256(bytes(key));
        PepesFamily.ImdEthPool memory wrappedNative = PepesFamily.ImdEthPool({fee: 0, tickSpacing: 0, hooks: address(0)});
        if (k == keccak256("robinhood-imd")) {
            Config memory c = get(4663);
            return Pad(key, 4663, c.poolManager, c.imd, c.quoter, c.imdEthPool, 635e18);
        }
        if (k == keccak256("ethereum-imd")) {
            Config memory c = get(1);
            return Pad(key, 1, c.poolManager, c.imd, c.quoter, c.imdEthPool, 635e18);
        }
        if (k == keccak256("ethereum-pepe")) {
            // $PEPE; PEPE/ETH v4 pool 0xe42df52d…61cd (1% fee, tick spacing 200, no hooks)
            return Pad(key, 1, IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90), 0x6982508145454Ce325dDbE47a25d4ec3d2311933,
                0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203, PepesFamily.ImdEthPool({fee: 10_000, tickSpacing: 200, hooks: address(0)}), 950_000_000e18);
        }
        if (k == keccak256("ethereum-weth")) {
            // WETH: launches pair with ETH itself
            return Pad(key, 1, IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90), 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
                0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203, wrappedNative, 1.5e18);
        }
        if (k == keccak256("robinhood-weth")) {
            // Robinhood Chain, WETH (Arbitrum's aeWETH, behind a proxy): launches pair with ETH itself
            Config memory c = get(4663);
            return Pad(key, 4663, c.poolManager, 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, c.quoter, wrappedNative, 1.5e18);
        }
        if (k == keccak256("robinhood-cashcat")) {
            // Robinhood Chain, $CASHCAT; CASHCAT/ETH v4 pool 0xf7dc0af9…50b1 (2% fee, tick spacing 400, no hooks)
            Config memory c = get(4663);
            return Pad(key, 4663, c.poolManager, 0x020bfC650A365f8BB26819deAAbF3E21291018b4, c.quoter,
                PepesFamily.ImdEthPool({fee: 20_000, tickSpacing: 400, hooks: address(0)}), 35_000e18);
        }
        if (k == keccak256("elysium-testnet-whype")) {
            // Elysium testnet (Kinetiq's Arbitrum Orbit chain on Hyperliquid, gas in HYPE), WHYPE. No Uniswap v4 there
            // yet: our own PoolManager and PepesFamilyQuoter (script/ElysiumAddrs.s.sol; testnet only, as v4-core's
            // license allows). Mainnet waits for Uniswap's own deployment.
            return Pad(key, 99801, IPoolManager(0x13DA18e28F1928F85465EaFe49CB6BBac1d52203), 0xCD57F65c2B0e5881CFC2E609F7CD53b746E1F234,
                0x365EfD5fFb4e42657CFB36fE61255082E5327dEd, wrappedNative, 47e18);
        }
        if (k == keccak256("base-weth")) {
            // Base, WETH (the OP Stack predeploy): launches pair with ETH itself
            return Pad(key, 8453, IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b), 0x4200000000000000000000000000000000000006,
                0x0d5e0F971ED27FBfF6c2837bf31316121532048D, wrappedNative, 1.5e18);
        }
        if (k == keccak256("hyperevm-whype")) {
            // HyperEVM, WHYPE (deploying needs the address on big blocks: a HyperCore setting)
            return Pad(key, 999, IPoolManager(0x12D4Fd9C5DeDd00ab8a0bCe2CF0167bbf94b6B1F), 0x5555555555555555555555555555555555555555,
                0x108Bfe38532C98f8Cd8D7Ab49c9dDAa3675a1c5e, wrappedNative, 47e18);
        }
        if (k == keccak256("bsc-wbnb")) {
            // BNB Smart Chain, WBNB: launches pair with BNB itself (5 BNB, about $3,700 on 2026-10-27)
            return Pad(key, 56, IPoolManager(0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF), 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
                0x9F75dD27D6664c475B90e105573E550ff69437B0, wrappedNative, 5e18);
        }
        revert("Chains: unknown launchpad");
    }
}