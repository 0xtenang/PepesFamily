// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

interface IPepesFamilyV5 {
    function poolKey(address token) external view returns (PoolKey memory);
    function launches(address token)
        external
        view
        returns (address quote, address creator, uint64 createdAt, uint64 createdBlock, bool quoteIsCurrency0);
    function marketCap(address token) external view returns (uint256);
    function pendingHolderFees(address token) external view returns (uint256);
    function allTokens(uint256 i) external view returns (address);
    function tokenCount() external view returns (uint256);
}

interface IPadTokenInfo {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function metadata() external view returns (string memory);
    function totalDividendsDistributed() external view returns (uint256);
}

/// @notice Token info as the PepesFamily launchpads v1-v4 return it from `getTokenInfo` / `getTokens`.
struct TokenInfo {
    address token;
    string name;
    string symbol;
    string metadata;
    address quote;
    address creator;
    uint64 createdAt;
    uint64 createdBlock;
    bool quoteIsCurrency0;
    PoolId poolId;
    uint160 sqrtPriceX96;
    uint256 marketCap;
    uint256 pendingHolderFees;
    uint256 totalDividendsDistributed;
}

/// @title PepesFamilyLens
/// @notice Read-only token list for PepesFamily v5, deployed by the launchpad itself. Same `getTokenInfo` /
///         `getTokens` / `tokenCount` / `marketCap` interface as launchpads v1-v4 had built in; v5 moved them here to
///         stay under the contract size limit. Holds nothing and changes nothing.
contract PepesFamilyLens {
    using StateLibrary for IPoolManager;

    IPepesFamilyV5 public immutable pad;
    IPoolManager public immutable poolManager;

    constructor(address pad_, IPoolManager poolManager_) {
        pad = IPepesFamilyV5(pad_);
        poolManager = poolManager_;
    }

    function tokenCount() external view returns (uint256) {
        return pad.tokenCount();
    }

    function marketCap(address token) external view returns (uint256) {
        return pad.marketCap(token);
    }

    function getTokenInfo(address token) public view returns (TokenInfo memory info) {
        (address quote, address creator, uint64 createdAt, uint64 createdBlock, bool quoteIs0) = pad.launches(token);
        PoolId id = pad.poolKey(token).toId(); // reverts UnknownToken for tokens of other launchpads
        (uint160 sqrtP,,,) = poolManager.getSlot0(id);
        IPadTokenInfo t = IPadTokenInfo(token);
        info = TokenInfo({
            token: token,
            name: t.name(),
            symbol: t.symbol(),
            metadata: t.metadata(),
            quote: quote,
            creator: creator,
            createdAt: createdAt,
            createdBlock: createdBlock,
            quoteIsCurrency0: quoteIs0,
            poolId: id,
            sqrtPriceX96: sqrtP,
            marketCap: pad.marketCap(token),
            pendingHolderFees: pad.pendingHolderFees(token),
            totalDividendsDistributed: t.totalDividendsDistributed()
        });
    }

    /// @notice Paged token list, oldest first. Use `tokenCount()` to page from the end for newest-first.
    function getTokens(uint256 offset, uint256 limit) external view returns (TokenInfo[] memory infos) {
        uint256 n = pad.tokenCount();
        if (offset >= n) return infos;
        uint256 end = offset + limit > n ? n : offset + limit;
        infos = new TokenInfo[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            infos[i - offset] = getTokenInfo(pad.allTokens(i));
        }
    }
}
