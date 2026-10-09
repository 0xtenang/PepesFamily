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

import {PadToken} from "./PadToken.sol";
import {PepesFamilyRouter} from "./PepesFamilyRouter.sol";
import {PepesFamilyEthRouter} from "./PepesFamilyEthRouter.sol";
import {PepesFamilyLens} from "./PepesFamilyLens.sol";
import {SafeTransfer} from "./lib/SafeTransfer.sol";

/// @title PepesFamily (v5)
/// @notice Fixed-supply token launchpad on Uniswap v4 (Robinhood Chain). Every launch is paired with IMD.
///         The full 1B supply is added as single-sided liquidity from the launch price to the end of the curve,
///         owned by this contract, which has no way to remove it: liquidity is locked forever.
///
///         This contract is also the pools' v4 hook. Every swap, whichever router it comes through, pays 4%:
///           - 1% protocol fee, in IMD             -> `feeRecipient`
///           - 3% split as the creator chose at launch (fixed forever), in 0.5% steps:
///               creator share, in IMD (at most 2%) -> the token's creator payout address, claimed any time
///               holder share, in IMD               -> the token's holders, pro rata (see PadToken)
///               burn share, in the token itself   -> taken from the token side of the swap and sent to 0x…dEaD
///         The burn is taken directly from each trade (a buyer receives that share less, a seller pays it on top),
///         so it needs no market buyer. IMD fees are held as PoolManager ERC-6909 claims until flushed or
///         collected; PepesFamilyRouter flushes holder fees on every trade.
///         Holder rewards left unclaimed by a wallet inactive for more than 7 days expire and go to
///         `feeRecipient`, which uses them to buy back and burn $Pepes (see PadToken).
/// @dev Must be deployed at an address whose low 14 bits equal `HOOK_FLAGS` (mine a CREATE2 salt).
contract PepesFamily is IHooks, IUnlockCallback {
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
    error BadSplit();
    error NotCreator();

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
    event FeeSplitSet(address indexed token, uint16 creatorBps, uint16 holderBps, uint16 burnBps);
    event TokensBurned(address indexed token, uint256 amount);
    event CreatorFeesCollected(address indexed token, address indexed to, uint256 amount);
    event CreatorPayoutUpdated(address indexed token, address payout);
    event HolderFeesFlushed(address indexed token, uint256 amount);
    event ProtocolFeesCollected(address indexed quote, address indexed to, uint256 amount);
    event FeeRecipientUpdated(address feeRecipient);
    event StartTickUpdated(address indexed quote, int24 tick);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 400; // 4% total
    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1% of the trade, in IMD
    /// @notice The creator's 3%: shares of creator / holders / burn, each a multiple of 0.5%, creator at most 2%.
    uint256 public constant SPLIT_BPS = 300;
    uint256 public constant SPLIT_STEP_BPS = 50;
    uint256 public constant MAX_CREATOR_BPS = 200;
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
    /// @dev keccak256("PepesFamily.beforeSwapBurn") - transient slot passing a burn taken in beforeSwap to afterSwap.
    bytes32 internal constant BURN_SLOT = 0xe1469100834ed59070a6460b0bab08f5db838ab47d942220baf1510b40fb5337;

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

    address public owner;
    address public pendingOwner;
    address public feeRecipient;
    /// @notice Launch tick per quote asset, expressed as the tick of (tokens per quote). Sets the starting market cap.
    mapping(address quote => int24) public startTick;

    /// @notice Uniswap v4 IMD/ETH pool used by `ethRouter` (ETH is currency0, IMD currency1).
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

    /// @notice Where a token's 3% goes, in basis points of each trade (sum 300).
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
    /// @notice Each token's split of the 3%, chosen at launch and never changed.
    mapping(address token => FeeSplit) public feeSplit;
    /// @notice Creator fees held as ERC-6909 claims, waiting to be collected to `creatorPayout`.
    mapping(address token => uint256) public pendingCreatorFees;
    /// @notice Where a token's creator fees are paid (the creator at launch; the payout address can hand it on).
    mapping(address token => address) public creatorPayout;
    /// @notice Tokens burned by trades (the burn share), per token.
    mapping(address token => uint256) public totalBurned;

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
        int24 imdStartTick,
        ImdEthPool memory imdEthPool
    ) {
        if (imd == address(0) || owner_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
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
        router = address(new PepesFamilyRouter(poolManager_, address(this)));
        ethRouter = address(
            new PepesFamilyEthRouter(
                poolManager_, address(this), imd, imdEthPool.fee, imdEthPool.tickSpacing, imdEthPool.hooks
            )
        );
        lens = address(new PepesFamilyLens(address(this), poolManager_));
        _setStartTick(imd, imdStartTick);
        emit OwnershipTransferred(address(0), owner_);
        emit FeeRecipientUpdated(feeRecipient_);
    }

    // --------------------------------------------------------------- Launch

    /// @notice Deploys a token paired with `quote` (must be IMD) and locks its full supply in a v4 pool, with the
    ///         creator's split of the 3%. To launch with an initial buy in the same transaction use
    ///         `PepesFamilyRouter.launchWithSplit` (its `launch` uses the default split: all 3% to holders).
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
        FeeSplit memory split
    ) internal returns (address token) {
        if (quote != IMD) revert UnsupportedQuote();
        if (
            uint256(split.creatorBps) + split.holderBps + split.burnBps != SPLIT_BPS
                || split.creatorBps % SPLIT_STEP_BPS != 0 || split.holderBps % SPLIT_STEP_BPS != 0
                || split.burnBps % SPLIT_STEP_BPS != 0 || split.creatorBps > MAX_CREATOR_BPS
        ) revert BadSplit();
        if (creator == address(0)) revert ZeroAddress();
        uint256 nameLen = bytes(name).length;
        uint256 symLen = bytes(symbol).length;
        if (nameLen == 0 || nameLen > 32 || symLen == 0 || symLen > 12 || bytes(metadata).length > 2048) {
            revert BadMetadata();
        }

        token = address(new PadToken(name, symbol, metadata, quote, creator, router, address(poolManager)));
        bool quoteIs0 = uint160(quote) < uint160(token);
        launches[token] = Launch({
            quote: quote,
            creator: creator,
            createdAt: uint64(block.timestamp),
            createdBlock: _l2BlockNumber(),
            quoteIsCurrency0: quoteIs0
        });
        allTokens.push(token);
        feeSplit[token] = split;
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
        emit FeeSplitSet(token, split.creatorBps, split.holderBps, split.burnBps);
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
        token.transferOut(DEAD, PadToken(payable(token)).balanceOf(address(this)));
    }

    // ------------------------------------------------------------ Hook

    /// @dev Takes the fee of the swap's specified currency: the IMD fee (4% minus the burn share) when IMD is
    ///      specified, the burn share when the token is. exact-in: that share of the amount in; exact-out: grossed
    ///      up, so it is that share of the gross amount out.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address token = tokenOfPool[key.toId()];
        bool exactIn = params.amountSpecified < 0;
        bool quoteSpecified = (exactIn == params.zeroForOne) == launches[token].quoteIsCurrency0;
        uint256 burnBps = feeSplit[token].burnBps;
        uint256 bps = quoteSpecified ? FEE_BPS - burnBps : burnBps;
        if (bps == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = exactIn ? (amount * bps) / BPS : (amount * bps) / (BPS - bps);
        if (quoteSpecified) {
            _chargeFee(token, fee);
            assembly ("memory-safe") {
                tstore(FEE_SLOT, fee)
            }
        } else {
            _burn(token, fee);
            assembly ("memory-safe") {
                tstore(BURN_SLOT, fee)
            }
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @dev Takes the fee of the swap's unspecified currency from the pool's own amounts: the burn share of the
    ///      tokens when IMD was specified, the IMD fee when the token was. exact-in: that share of the output;
    ///      exact-out: grossed up from the input.
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
        uint256 burnBps = feeSplit[token].burnBps;

        uint256 fee;
        uint256 burned;
        if ((exactIn == params.zeroForOne) == quoteIs0) {
            assembly ("memory-safe") {
                fee := tload(FEE_SLOT)
                tstore(FEE_SLOT, 0)
            }
            if (burnBps != 0) {
                burned = exactIn ? (poolToken * burnBps) / BPS : (poolToken * burnBps) / (BPS - burnBps);
                _burn(token, burned);
                hookDelta = burned.toInt128();
            }
        } else {
            assembly ("memory-safe") {
                burned := tload(BURN_SLOT)
                tstore(BURN_SLOT, 0)
            }
            uint256 qBps = FEE_BPS - burnBps;
            fee = exactIn ? (poolQuote * qBps) / BPS : (poolQuote * qBps) / (BPS - qBps);
            _chargeFee(token, fee);
            hookDelta = fee.toInt128();
        }

        bool isBuy = params.zeroForOne == quoteIs0;
        // Our two routers report their user; for any other router the best we know is the transaction's signer.
        address trader = (sender == router || sender == ethRouter) && hookData.length == 32
            ? abi.decode(hookData, (address))
            : tx.origin;
        // A buy of any size, through any router, is the buyer's own activity (reward expiry, see PadToken).
        if (isBuy) PadToken(payable(token)).markActive(trader);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        // Amounts as the trader sees them: IMD paid / received incl. the IMD fee, tokens received / paid incl. burn.
        emit Trade(
            token,
            trader,
            isBuy,
            isBuy ? poolQuote + fee : poolQuote - fee,
            isBuy ? poolToken - burned : poolToken + burned,
            fee,
            sqrtPriceX96
        );
        return (IHooks.afterSwap.selector, hookDelta);
    }

    /// @dev The hook is credited `fee` IMD by the swap; minting claims of the same size settles that credit. The fee
    ///      is (4% - burn share) of the trade: 1% protocol, the rest to creator and holders in the token's ratio.
    function _chargeFee(address token, uint256 fee) internal {
        if (fee == 0) return;
        address quote = launches[token].quote;
        FeeSplit memory sp = feeSplit[token];
        uint256 qBps = FEE_BPS - sp.burnBps;
        uint256 protocolFee = (fee * PROTOCOL_FEE_BPS) / qBps;
        uint256 creatorFee = (fee * sp.creatorBps) / qBps;
        pendingProtocolFees[quote] += protocolFee;
        if (creatorFee != 0) pendingCreatorFees[token] += creatorFee;
        uint256 holderFee = fee - protocolFee - creatorFee;
        if (holderFee != 0) pendingHolderFees[token] += holderFee;
        poolManager.mint(address(this), Currency.wrap(quote).toId(), fee);
    }

    /// @dev The hook is credited `amount` tokens by the swap; taking them straight to the burn address settles it.
    function _burn(address token, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.take(Currency.wrap(token), DEAD, amount);
        totalBurned[token] += amount;
        emit TokensBurned(token, amount);
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

    /// @notice Sends pending protocol fees for `quote` to `feeRecipient`. Callable by anyone.
    function collectProtocolFees(address quote) external {
        if (pendingProtocolFees[quote] == 0) return;
        if (poolManager.isUnlocked()) _collect(quote);
        else poolManager.unlock(abi.encode(ACTION_COLLECT, abi.encode(quote)));
    }

    /// @notice Sends `token`'s pending creator fees to its `creatorPayout`. Callable by anyone.
    function collectCreatorFees(address token) external {
        if (pendingCreatorFees[token] == 0) return;
        if (poolManager.isUnlocked()) _collectCreator(token);
        else poolManager.unlock(abi.encode(ACTION_COLLECT_CREATOR, abi.encode(token)));
    }

    /// @notice The current payout address hands the creator fees of `token` to another address.
    function setCreatorPayout(address token, address payout) external {
        if (msg.sender != creatorPayout[token]) revert NotCreator();
        if (payout == address(0)) revert ZeroAddress();
        creatorPayout[token] = payout;
        emit CreatorPayoutUpdated(token, payout);
    }

    function _collectCreator(address token) internal {
        uint256 amount = pendingCreatorFees[token];
        if (amount == 0) return;
        pendingCreatorFees[token] = 0;
        Currency quote = Currency.wrap(launches[token].quote);
        address to = creatorPayout[token];
        poolManager.burn(address(this), quote.toId(), amount);
        poolManager.take(quote, to, amount);
        emit CreatorFeesCollected(token, to, amount);
    }

    function _flush(address token) internal {
        uint256 amount = pendingHolderFees[token];
        if (amount == 0) return;
        pendingHolderFees[token] = 0;
        Currency quote = Currency.wrap(launches[token].quote);
        poolManager.burn(address(this), quote.toId(), amount);
        poolManager.take(quote, token, amount);
        PadToken(payable(token)).distribute();
        emit HolderFeesFlushed(token, amount);
    }

    function _collect(address quote) internal {
        uint256 amount = pendingProtocolFees[quote];
        if (amount == 0) return;
        pendingProtocolFees[quote] = 0;
        poolManager.burn(address(this), Currency.wrap(quote).toId(), amount);
        poolManager.take(Currency.wrap(quote), feeRecipient, amount);
        emit ProtocolFeesCollected(quote, feeRecipient, amount);
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
            _collectCreator(abi.decode(payload, (address)));
        } else {
            _collect(abi.decode(payload, (address)));
        }
        return "";
    }

    /// @dev On Arbitrum chains (Robinhood Chain) `block.number` is the L1 block; ArbSys gives the L2 block that
    ///      logs are indexed by. Falls back to `block.number` elsewhere.
    function _l2BlockNumber() internal view returns (uint64) {
        (bool ok, bytes memory data) = address(100).staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        return ok && data.length == 32 ? uint64(abi.decode(data, (uint256))) : uint64(block.number);
    }

    // ---------------------------------------------------------------- Admin

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        emit FeeRecipientUpdated(feeRecipient_);
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

    /// @notice Fully diluted market cap in quote wei at the current pool price.
    function marketCap(address token) public view returns (uint256) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolKey(token).toId());
        return launches[token].quoteIsCurrency0
            ? FullMath.mulDiv(FullMath.mulDiv(TOTAL_SUPPLY, Q96, sqrtP), Q96, sqrtP) // price = tokens per quote
            : FullMath.mulDiv(FullMath.mulDiv(TOTAL_SUPPLY, sqrtP, Q96), sqrtP, Q96); // price = quote per token
    }

    // ------------------------------------------------- Disabled hook paths

    /// @dev Only this contract creates pools and adds liquidity; v4 skips hooks when the hook itself calls,
    ///      so these revert for everyone else.
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

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotAllowed();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotAllowed();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotAllowed();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotAllowed();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotAllowed();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotAllowed();
    }
}
