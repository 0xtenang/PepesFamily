// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The parts of Pons V2 (Robinhood Chain launchpad) that MemeLev's fee router uses.
/// @dev Taken from the published Pons V2 source (github.com/koriyoshi2041/ponsfamily, contractsV2/src/v2).
///      The published source is not verified against the deployed bytecode: the fork tests in
///      test/fork exercise these calls against the live contracts on chain 4663.
///      Mainnet addresses found on 2026-10-29:
///        PonsV2LaunchFactory  0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e
///        PonsV2MemeHook       0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044
///        FeeEscrow            0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e
///        Uniswap V4 PoolManager 0x8366a39cc670b4001a1121b8f6a443a643e40951

/// @notice Pull-based fee ledger. `claim` pays the caller its own native-ETH balance.
/// @dev Fork-tested on 2026-10-29: `claim` pays with a call that forwards all gas (a contract whose receive() writes
///      storage can claim) and reverts when nothing is owed.
interface IPonsFeeEscrow {
    function claim() external returns (uint256 amount);
    function balanceOf(address recipient) external view returns (uint256);
}

interface IPonsLaunchFactory {
    enum GraduationPhase {
        NotGraduated,
        Swept,
        PoolCreated,
        Rescued
    }

    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        GraduationPhase phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    /// @dev Only the current creator fee recipient may call it.
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
}

/// @notice Per-launch bonding curve. `sweepFees` moves pending fees into the escrow. The creator fee recipient may call
///         it when no internal buyback swap is needed (Pons buybacks disabled); otherwise only the Pons operator can.
/// @dev The curve keeps the recipient in its `deployer()` slot, and `transferCreatorFeeRecipient` moves it. The
///      account that launched the token cannot sweep once the recipient is another address (fork-tested).
interface IPonsBondingCurve {
    function graduated() external view returns (bool);
    function sweepFees(uint256 minBuybackTokensOut) external;
}

/// @notice Singleton hook of graduated Pons pools. Same sweep rule as the curve, keyed by Uniswap V4 pool id.
/// @dev The hook takes its fee from the swap's unspecified side. Exact-input sells and exact-output buys pay it in
///      ETH, which the recipient can sweep. Exact-input buys pay it in the token, and converting that back to ETH is
///      an internal swap, so while any is pending only the Pons operator can sweep (fork-tested).
interface IPonsMemeHook {
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}
