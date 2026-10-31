// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

import {PadTokenV6} from "./PadTokenV6.sol";
import {PadTokenFactory} from "./PadTokenFactory.sol";
import {NativePayout} from "./lib/NativePayout.sol";
import {PepesFamilyRouter} from "./PepesFamilyRouter.sol";
import {PepesFamilyEthRouter} from "./PepesFamilyEthRouter.sol";
import {PepesFamilyNativeRouter} from "./PepesFamilyNativeRouter.sol";
import {PepesFamilyLens} from "./PepesFamilyLens.sol";
import {SafeTransfer} from "./lib/SafeTransfer.sol";

/// @title PepesFamily (v6)
/// @notice Fixed-supply token launchpad on Uniswap v4. Every launch is paired with the chain's wrapped native coin
///         (`IMD`, named so for v5 compatibility: WETH on Robinhood Chain, Ethereum and Base, WBNB on BSC, WHYPE on
///         HyperEVM), so every fee is ETH (BNB, HYPE). Holders and creators are paid the plain coin. The full 1B supply is added as single-sided liquidity from the
///         launch price to the end of the curve, owned by this contract, which has no way to remove it: liquidity is
///         locked forever.
///
///         This contract is also the pools' v4 hook. Every swap, whichever router it comes through, pays 4% of its
///         pair-asset side, split the same way for every token (no per-token choice, unlike v5):
///           - 1% protocol fee     -> `feeRecipient`
///           - 1% creator fee      -> the token's creator payout address, collected any time
///           - 1% holder fee       -> the token's holders, pro rata (see PadTokenV6)
///           - 1% NFT holder fee   -> `nftFeeRecipient`: the PEPES FAMILY NFT contract on the chain the collection
///                                   lives on; elsewhere the team's address, which moves it to the NFT contract
///         During the swap fees are held as PoolManager ERC-6909 claims (no token balance moves mid-swap); `flush`
///         pays the holder fees, and PepesFamilyRouter flushes on every trade. Swaps must fill completely: a swap
///         stopped early by its price limit reverts, so nobody pays the fee of an amount the pool didn't trade.
///         Holder rewards left unclaimed by a wallet inactive for more than 7 days expire and go to
///         `feeRecipient`, which uses them to buy back and burn $Pepes (see PadTokenV6).
/// @dev Must be deployed at an address whose low 14 bits equal `HOOK_FLAGS` (mine a CREATE2 salt). Keeps v5's
///      function signatures (`launchWithSplit`, `feeSplit`, `pendingBurn`, `totalBurned`) so the routers, the lens
///      and PepesFamilyRemote work with it unchanged; the split argument is ignored.
contract PepesFamilyV6 is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeTransfer for address;
    using SafeCast for uint256;

    error NotPoolManager();
    error NotOwner();
    error NotRouter();
    error UnsupportedQuote();
    error UnknownToken();
    error BadMetadata();
    error BadTick();
    error ZeroAddress();
    error HookNotAllowed();
    error NotCreator();
    error PartialFill();

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        address indexed quote,
        string name,
        string symbol,
        string metadata,
        PoolId poolId,
        int24 startTick
    );
    /// @param quoteAmount quote paid by the buyer / received by the seller, fee included
    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 quoteAmount,
        uint256 tokenAmount,
        uint256 fee,
        uint160 sqrtPriceX96
    );
    event CreatorFeesCollected(address indexed token, address indexed to, uint256 amount);
    event CreatorPayoutUpdated(address indexed token, address payout);
    event CreatorPayoutProposed(address indexed token, address payout);
    event HolderFeesFlushed(address indexed token, uint256 amount);
    event ProtocolFeesCollected(address indexed quote, address indexed to, uint256 amount);
    event FeeRecipientUpdated(address feeRecipient);
    event NftFeesCollected(address indexed quote, address indexed to, uint256 amount);
    event NftFeeRecipientUpdated(address nftFeeRecipient);
    event StartTickUpdated(address indexed quote, int24 tick);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 400; // 4% total, four equal shares of 1% of the trade
    uint256 public constant PROTOCOL_FEE_BPS = 100;
    uint256 public constant CREATOR_FEE_BPS = 100;
    uint256 public constant HOLDER_FEE_BPS = 100;
    uint256 public constant NFT_FEE_BPS = 100;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    int24 public constant TICK_SPACING = 200;
    uint24 public constant LP_FEE = 0; // all fees are taken by the hook
    uint160 public constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @dev Kept out of the liquidity calculation so rounding can never ask for more than the supply; burned.
    uint256 internal constant LIQUIDITY_BUFFER = 1e9;
    uint256 internal constant Q96 = 2 ** 96;
    /// @dev keccak256("PepesFamily.beforeSwapFee") - transient slot passing the fee from beforeSwap to afterSwap.
    bytes32 internal constant FEE_SLOT = 0xb3f22a791898bb84e2b20e5bc6bffd5fae55b37f53e26d82882f1ef60c6f5e44;

    uint8 internal constant ACTION_ADD_LIQUIDITY = 0;
    uint8 internal constant ACTION_FLUSH = 1;
    uint8 internal constant ACTION_COLLECT = 2;
    uint8 internal constant ACTION_COLLECT_CREATOR = 3;

    IPoolManager public immutable poolManager;
    address public immutable IMD;
    address public immutable router;
    /// @notice Router for trading IMD-paired tokens with ETH (through the Uniswap v4 IMD/ETH pool).
    address public immutable ethRouter;
    /// @notice Read-only token list (`getTokenInfo`, `getTokens`), moved out of this contract for size.
    address public immutable lens;
    /// @notice Deploys this launchpad's tokens (PadTokenV6).
    address public immutable tokenFactory;

    address public owner;
    address public pendingOwner;
    address public feeRecipient;
    /// @notice Where the 1% NFT holder fee goes (see the contract notice).
    address public nftFeeRecipient;
    /// @notice Launch tick per quote asset, expressed as the tick of (tokens per quote). Sets the starting market cap.
    mapping(address quote => int24) public startTick;

    /// @notice Uniswap v4 IMD/ETH pool used by `ethRouter` (ETH is currency0, IMD currency1). With tickSpacing 0 the
    ///         pair asset is the chain's wrapped native coin itself (WETH, WBNB, WHYPE): `ethRouter` is then a
    ///         PepesFamilyNativeRouter, which wraps and unwraps instead of swapping through a pool.
    struct ImdEthPool {
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct Launch {
        address quote;
        address creator;
        uint64 createdAt;
        uint64 createdBlock;
        bool quoteIsCurrency0;
    }

    /// @notice v5's per-token split of the 3%, kept for its views and `launchWithSplit`'s signature. In v6 every
    ///         token has creator 1%, holders 1%, burn 0 (the remaining 1% is the NFT holder fee).
    struct FeeSplit {
        uint16 creatorBps;
        uint16 holderBps;
        uint16 burnBps;
    }


    mapping(address token => Launch) public launches;
    mapping(PoolId => address) public tokenOfPool;
    address[] public allTokens;

    /// @notice Holder fees held as ERC-6909 claims, waiting to be sent to the token contract.
    mapping(address token => uint256) public pendingHolderFees;
    /// @notice Protocol fees held as ERC-6909 claims, waiting to be sent to `feeRecipient`.
    mapping(address quote => uint256) public pendingProtocolFees;
    /// @notice NFT holder fees held as ERC-6909 claims, waiting to be sent to `nftFeeRecipient`.
    mapping(address quote => uint256) public pendingNftFees;
    /// @notice Creator fees held as ERC-6909 claims, waiting to be collected to `creatorPayout`.
    mapping(address token => uint256) public pendingCreatorFees;
    /// @notice Where a token's creator fees are paid (the creator at launch; the payout address can hand it on).
    mapping(address token => address) public creatorPayout;
    /// @notice Proposed new creator payout address, which must accept (two-step, so a typo can't lose the fees).
    mapping(address token => address) public pendingCreatorPayout;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        IPoolManager poolManager_,
        address imd,
        address owner_,
        address feeRecipient_,
        address nftFeeRecipient_,
        int24 imdStartTick,
        ImdEthPool memory imdEthPool,
        address tokenFactory_
    ) {
        if (
            imd == address(0) || owner_ == address(0) || feeRecipient_ == address(0)
                || nftFeeRecipient_ == address(0)
        ) revert ZeroAddress();
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
        poolManager = poolManager_;
        IMD = imd;
        owner = owner_;
        feeRecipient = feeRecipient_;
        nftFeeRecipient = nftFeeRecipient_;
        router = address(new PepesFamilyRouter(poolManager_, address(this)));
        ethRouter = imdEthPool.tickSpacing == 0
            ? address(new PepesFamilyNativeRouter(poolManager_, address(this), imd))
            : address(
                new PepesFamilyEthRouter(
                    poolManager_, address(this), imd, imdEthPool.fee, imdEthPool.tickSpacing, imdEthPool.hooks
                )
            );
        lens = address(new PepesFamilyLens(address(this), poolManager_));
        tokenFactory = tokenFactory_;
        PadTokenFactory(tokenFactory_).bind();
        _setStartTick(imd, imdStartTick);
        emit OwnershipTransferred(address(0), owner_);
        emit FeeRecipientUpdated(feeRecipient_);
        emit NftFeeRecipientUpdated(nftFeeRecipient_);
    }

    // --------------------------------------------------------------- Launch

    /// @notice Deploys a token paired with `quote` (must be `IMD`) and locks its full supply in a v4 pool. To launch
    ///         with an initial buy in the same transaction use `PepesFamilyRouter.launch`.
    /// @param split Ignored (v5 signature): every v6 token has the same split.
    /// @param metadata JSON string, e.g. {"image":"https://…","description":"…","website":"…","x":"…","telegram":"…"}
    function launchWithSplit(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address quote,
        FeeSplit calldata split
    ) external returns (address token) {
        return _launch(msg.sender, name, symbol, metadata, quote, split);
    }

    function launchForWithSplit(
        address creator,
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address quote,
        FeeSplit calldata split
    ) external returns (address token) {
        if (msg.sender != router) revert NotRouter();
        return _launch(creator, name, symbol, metadata, quote, split);
    }

    function _launch(
        address creator,
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address quote,
        FeeSplit memory
    ) internal returns (address token) {
        if (quote != IMD) revert UnsupportedQuote();
        if (creator == address(0)) revert ZeroAddress();
        uint256 nameLen = bytes(name).length;
        uint256 symLen = bytes(symbol).length;
        if (nameLen == 0 || nameLen > 32 || symLen == 0 || symLen > 12 || bytes(metadata).length > 2048) {
            revert BadMetadata();
        }

        token = PadTokenFactory(tokenFactory).create(name, symbol, metadata, quote, creator, router, address(poolManager));
        bool quoteIs0 = uint160(quote) < uint160(token);
        launches[token] = Launch({
            quote: quote,
            creator: creator,
            createdAt: uint64(block.timestamp),
            createdBlock: _l2BlockNumber(),
            quoteIsCurrency0: quoteIs0
        });
        allTokens.push(token);
        creatorPayout[token] = creator;

        PoolKey memory key = poolKey(token);
        PoolId id = key.toId();
        tokenOfPool[id] = token;

        // Price is currency1 per currency0. With the token as currency1 that is tokens-per-quote (= startTick);
        // with the token as currency0 it is the inverse, so the tick flips sign.
        int24 tick = quoteIs0 ? startTick[quote] : -startTick[quote];
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(tick));
        poolManager.unlock(abi.encode(ACTION_ADD_LIQUIDITY, abi.encode(key, token, tick, quoteIs0)));

        emit TokenLaunched(token, creator, quote, name, symbol, metadata, id, tick);
    }

    /// @dev Single-sided token liquidity across the rest of the curve: [MIN, start] when the token is currency1,
    ///      [start, MAX] when it is currency0. Buying moves the price into the range; x*y=k with virtual quote.
    function _addLaunchLiquidity(PoolKey memory key, address token, int24 tick, bool tokenIs1) internal {
        (int24 lower, int24 upper) = tokenIs1
            ? (TickMath.minUsableTick(TICK_SPACING), tick)
            : (tick, TickMath.maxUsableTick(TICK_SPACING));
        uint256 sqrtL = TickMath.getSqrtPriceAtTick(lower);
        uint256 sqrtU = TickMath.getSqrtPriceAtTick(upper);
        uint256 amount = TOTAL_SUPPLY - LIQUIDITY_BUFFER;
        uint256 liquidity = tokenIs1
            ? FullMath.mulDiv(amount, Q96, sqrtU - sqrtL)
            : FullMath.mulDiv(amount, FullMath.mulDiv(sqrtL, sqrtU, Q96), sqrtU - sqrtL);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: int256(liquidity), salt: 0}),
            ""
        );
        uint256 owed = uint256(-int256(tokenIs1 ? delta.amount1() : delta.amount0()));
        poolManager.sync(Currency.wrap(token));
        token.transferOut(address(poolManager), owed);
        poolManager.settle();
        token.transferOut(DEAD, PadTokenV6(payable(token)).balanceOf(address(this)));
    }

    // ------------------------------------------------------------ Hook

    /// @dev When the pair asset is the swap's specified currency, takes the 4% fee from it: exact-in, 4% of the
    ///      amount in; exact-out, grossed up so it is 4% of the gross amount out. Otherwise `afterSwap` takes it.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address token = tokenOfPool[key.toId()];
        bool exactIn = params.amountSpecified < 0;
        if ((exactIn == params.zeroForOne) != launches[token].quoteIsCurrency0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = exactIn ? (amount * FEE_BPS) / BPS : (amount * FEE_BPS) / (BPS - FEE_BPS);
        _chargeFee(token, fee);
        assembly ("memory-safe") {
            tstore(FEE_SLOT, fee)
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @dev When the token was the specified currency, takes the 4% fee from the pool's pair-asset amount: exact-in,
    ///      4% of the output; exact-out, grossed up from the input.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128 hookDelta) {
        address token = tokenOfPool[key.toId()];
        bool quoteIs0 = launches[token].quoteIsCurrency0;
        bool exactIn = params.amountSpecified < 0;
        int128 q = quoteIs0 ? delta.amount0() : delta.amount1();
        int128 t = quoteIs0 ? delta.amount1() : delta.amount0();
        uint256 poolQuote = uint256(int256(q < 0 ? -q : q));
        uint256 poolToken = uint256(int256(t < 0 ? -t : t));

        uint256 fee;
        bool quoteSpecified = (exactIn == params.zeroForOne) == quoteIs0;
        if (quoteSpecified) {
            assembly ("memory-safe") {
                fee := tload(FEE_SLOT)
                tstore(FEE_SLOT, 0)
            }
        }
        {
            // Full fill only: the pool must have traded the whole specified amount (net of the fee taken from it in
            // beforeSwap), so the specified-side fee always matches what was traded (audit 8f96baf6, 1).
            uint256 spec = quoteSpecified ? poolQuote : poolToken;
            uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            if (exactIn ? spec + fee < amount : spec < amount + fee) revert PartialFill();
        }
        if (!quoteSpecified) {
            fee = exactIn ? (poolQuote * FEE_BPS) / BPS : (poolQuote * FEE_BPS) / (BPS - FEE_BPS);
            _chargeFee(token, fee);
            hookDelta = fee.toInt128();
        }

        bool isBuy = params.zeroForOne == quoteIs0;
        // Our two routers report their user; for any other router the best we know is the transaction's signer.
        address trader = (sender == router || sender == ethRouter) && hookData.length == 32
            ? abi.decode(hookData, (address))
            : tx.origin;
        // A buy of any size, through any router, is the buyer's own activity (reward expiry, see PadToken).
        if (isBuy) PadTokenV6(payable(token)).markActive(trader);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        // Amounts as the trader sees them: pair asset paid / received incl. the fee, tokens received / paid.
        emit Trade(token, trader, isBuy, isBuy ? poolQuote + fee : poolQuote - fee, poolToken, fee, sqrtPriceX96);
        return (IHooks.afterSwap.selector, hookDelta);
    }

    /// @dev The hook is credited `fee` of the pair asset by the swap; minting claims of the same size settles that
    ///      credit. Four equal shares; the protocol takes the rounding remainder.
    function _chargeFee(address token, uint256 fee) internal {
        if (fee == 0) return;
        address quote = launches[token].quote;
        uint256 share = fee / 4;
        pendingProtocolFees[quote] += fee - 3 * share;
        pendingCreatorFees[token] += share;
        pendingHolderFees[token] += share;
        pendingNftFees[quote] += share;
        poolManager.mint(address(this), Currency.wrap(quote).toId(), fee);
    }

    // ------------------------------------------------------------ Fee flows

    /// @notice Sends pending holder fees for `token` to the token contract, which spreads them over holders.
    ///         Standalone (opens its own unlock), or inside one of our routers' unlocks (they do it on every trade).
    function flush(address token) external {
        if (pendingHolderFees[token] == 0) return;
        if (poolManager.isUnlocked()) {
            // Mid-unlock, anyone can flash-borrow the pool's tokens (v4 flash accounting) and would be counted as a
            // holder at distribution time. Only our routers, which control their whole unlock, may distribute here;
            // anyone else's call leaves the fees pending for a distribution outside an unlock.
            if (msg.sender == router || msg.sender == ethRouter) _flush(token);
        } else {
            poolManager.unlock(abi.encode(ACTION_FLUSH, abi.encode(token)));
        }
    }

    /// @notice Sends pending protocol fees for `quote` to `feeRecipient` and pending NFT holder fees to
    ///         `nftFeeRecipient`. Callable by anyone.
    function collectProtocolFees(address quote) external {
        if (pendingProtocolFees[quote] == 0 && pendingNftFees[quote] == 0) return;
        if (poolManager.isUnlocked()) _collect(quote);
        else poolManager.unlock(abi.encode(ACTION_COLLECT, abi.encode(quote)));
    }

    /// @notice Sends `token`'s pending creator fees to its `creatorPayout`, as the plain coin (wrapped if the payout
    ///         can't receive it). Callable by anyone. Inside someone else's unlock it pays the wrapped coin directly,
    ///         so no plain-coin call is made while the PoolManager is unlocked.
    function collectCreatorFees(address token) external {
        uint256 amount = pendingCreatorFees[token];
        if (amount == 0) return;
        if (poolManager.isUnlocked()) {
            _collectCreator(token, creatorPayout[token]);
        } else {
            poolManager.unlock(abi.encode(ACTION_COLLECT_CREATOR, abi.encode(token)));
            NativePayout.pay(IMD, creatorPayout[token], amount);
        }
    }

    /// @notice The current payout address proposes another address for the creator fees of `token`; it takes over
    ///         once it calls `acceptCreatorPayout`. Proposing address(0) cancels.
    function setCreatorPayout(address token, address payout) external {
        if (msg.sender != creatorPayout[token]) revert NotCreator();
        pendingCreatorPayout[token] = payout;
        emit CreatorPayoutProposed(token, payout);
    }

    function acceptCreatorPayout(address token) external {
        if (msg.sender != pendingCreatorPayout[token] || msg.sender == address(0)) revert NotCreator();
        creatorPayout[token] = msg.sender;
        pendingCreatorPayout[token] = address(0);
        emit CreatorPayoutUpdated(token, msg.sender);
    }

    /// @dev Takes the fees as the wrapped coin to `to` (the payout, or this contract to unwrap them after the unlock).
    function _collectCreator(address token, address to) internal {
        uint256 amount = pendingCreatorFees[token];
        if (amount == 0) return;
        pendingCreatorFees[token] = 0;
        Currency quote = Currency.wrap(launches[token].quote);
        poolManager.burn(address(this), quote.toId(), amount);
        poolManager.take(quote, to, amount);
        emit CreatorFeesCollected(token, creatorPayout[token], amount);
    }

    function _flush(address token) internal {
        uint256 amount = pendingHolderFees[token];
        if (amount == 0) return;
        pendingHolderFees[token] = 0;
        Currency quote = Currency.wrap(launches[token].quote);
        poolManager.burn(address(this), quote.toId(), amount);
        poolManager.take(quote, token, amount);
        PadTokenV6(payable(token)).distribute();
        emit HolderFeesFlushed(token, amount);
    }

    function _collect(address quote) internal {
        uint256 amount = pendingProtocolFees[quote];
        uint256 nft = pendingNftFees[quote];
        pendingProtocolFees[quote] = 0;
        pendingNftFees[quote] = 0;
        poolManager.burn(address(this), Currency.wrap(quote).toId(), amount + nft);
        if (amount != 0) {
            poolManager.take(Currency.wrap(quote), feeRecipient, amount);
            emit ProtocolFeesCollected(quote, feeRecipient, amount);
        }
        if (nft != 0) {
            poolManager.take(Currency.wrap(quote), nftFeeRecipient, nft);
            emit NftFeesCollected(quote, nftFeeRecipient, nft);
        }
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == ACTION_ADD_LIQUIDITY) {
            (PoolKey memory key, address token, int24 tick, bool tokenIs1) =
                abi.decode(payload, (PoolKey, address, int24, bool));
            _addLaunchLiquidity(key, token, tick, tokenIs1);
        } else if (action == ACTION_FLUSH) {
            _flush(abi.decode(payload, (address)));
        } else if (action == ACTION_COLLECT_CREATOR) {
            _collectCreator(abi.decode(payload, (address)), address(this));
        } else {
            _collect(abi.decode(payload, (address)));
        }
        return "";
    }

    /// @dev On Arbitrum chains (Robinhood Chain) `block.number` is the L1 block; ArbSys gives the L2 block that
    ///      logs are indexed by. Falls back to `block.number` elsewhere. The call gets a small, fixed amount of gas:
    ///      on some chains 0x64 is a different precompile that fails by burning all the gas it is given (BSC's
    ///      system precompile there did, and every launch ran out of gas), so a failure here must stay cheap.
    function _l2BlockNumber() internal view returns (uint64) {
        (bool ok, bytes memory data) = address(100).staticcall{gas: 50_000}(abi.encodeWithSignature("arbBlockNumber()"));
        return ok && data.length == 32 ? uint64(abi.decode(data, (uint256))) : uint64(block.number);
    }

    /// @dev Only the wrapped coin sends plain coin here, while `collectCreatorFees` unwraps a payout.
    receive() external payable {
        if (msg.sender != IMD) revert UnsupportedQuote();
    }

    // ---------------------------------------------------------------- Admin

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        emit FeeRecipientUpdated(feeRecipient_);
    }

    /// @notice Points the NFT holder fee somewhere else (e.g. from the team's address to an NFT contract on this
    ///         chain). Fees already pending go to the new address at the next collection.
    function setNftFeeRecipient(address nftFeeRecipient_) external onlyOwner {
        if (nftFeeRecipient_ == address(0)) revert ZeroAddress();
        nftFeeRecipient = nftFeeRecipient_;
        emit NftFeeRecipientUpdated(nftFeeRecipient_);
    }

    /// @notice Only affects future launches.
    function setStartTick(address quote, int24 tick) external onlyOwner {
        _setStartTick(quote, tick);
    }

    /// @notice Two-step transfer: `newOwner` must call `acceptOwnership`, so a typo can't lose the admin role.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function _setStartTick(address quote, int24 tick) internal {
        if (quote != IMD) revert UnsupportedQuote();
        int24 limit = TickMath.maxUsableTick(TICK_SPACING) - TICK_SPACING;
        if (tick % TICK_SPACING != 0 || tick > limit || tick < -limit) revert BadTick();
        startTick[quote] = tick;
        emit StartTickUpdated(quote, tick);
    }

    // ---------------------------------------------------------------- Views

    function poolKey(address token) public view returns (PoolKey memory key) {
        Launch storage l = launches[token];
        if (l.createdAt == 0) revert UnknownToken();
        (address c0, address c1) = l.quoteIsCurrency0 ? (l.quote, token) : (token, l.quote);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    /// @notice Every token's split, as v5 readers expect it: creator 1%, holders 1%, burn 0 (+ 1% NFT holders).
    function feeSplit(address) external pure returns (uint16 creatorBps, uint16 holderBps, uint16 burnBps) {
        return (uint16(CREATOR_FEE_BPS), uint16(HOLDER_FEE_BPS), 0);
    }

    /// @notice Always 0: v6 has no burn share. Kept so v5 readers (the lens's market cap) work unchanged.
    function pendingBurn(address) external pure returns (uint256) {}

    function totalBurned(address) external pure returns (uint256) {}

    // ------------------------------------------------- Disabled hook paths

    /// @dev Only this contract creates pools and adds liquidity; v4 skips hooks when the hook itself calls,
    ///      so these revert for everyone else. The hook calls it doesn't enable (HOOK_FLAGS) are never made, so this
    ///      contract leaves them out (it doesn't inherit IHooks) to stay under the contract size limit.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotAllowed();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotAllowed();
    }
}
