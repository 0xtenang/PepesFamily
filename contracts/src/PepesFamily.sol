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
import {PepesBuyback} from "./PepesBuyback.sol";
import {SafeTransfer} from "./lib/SafeTransfer.sol";

/// @title PepesFamily (v4)
/// @notice Fixed-supply token launchpad on Uniswap v4 (Robinhood Chain). Every launch is paired with IMD.
///         The full 1B supply is added as single-sided liquidity from the launch price to the end of the curve,
///         owned by this contract, which has no way to remove it: liquidity is locked forever.
///
///         This contract is also the pools' v4 hook. It charges 4% of the quote side of every swap, whichever
///         router the swap comes through:
///           - 1% protocol fee -> `feeRecipient`
///           - 3% holder fee   -> the token's holders, pro rata (see PadToken)
///         Fees are held as PoolManager ERC-6909 claims until flushed; PepesFamilyRouter flushes on every trade.
///         v4: holder rewards left unclaimed by a wallet inactive for more than 7 days expire and go to `buyback`
///         (PepesBuyback, deployed here), which spends them buying $Pepes and burning it (see PadToken).
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
    event HolderFeesFlushed(address indexed token, uint256 amount);
    event ProtocolFeesCollected(address indexed quote, address indexed to, uint256 amount);
    event FeeRecipientUpdated(address feeRecipient);
    event StartTickUpdated(address indexed quote, int24 tick);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 400; // 4% total
    uint256 public constant PROTOCOL_FEE_BPS = 100; // 1% of the trade; the other 3% goes to holders
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

    IPoolManager public immutable poolManager;
    address public immutable IMD;
    address public immutable router;
    /// @notice Router for trading IMD-paired tokens with ETH (through the Uniswap v4 IMD/ETH pool).
    address public immutable ethRouter;
    /// @notice Shared $Pepes buyback-and-burn that receives every v4 token's expired holder rewards.
    address public immutable buyback;

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

    mapping(address token => Launch) public launches;
    mapping(PoolId => address) public tokenOfPool;
    address[] public allTokens;

    /// @notice Holder fees held as ERC-6909 claims, waiting to be sent to the token contract.
    mapping(address token => uint256) public pendingHolderFees;
    /// @notice Protocol fees held as ERC-6909 claims, waiting to be sent to `feeRecipient`.
    mapping(address quote => uint256) public pendingProtocolFees;

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
        ImdEthPool memory imdEthPool,
        address pepes,
        address pepesRouter
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
        buyback = address(new PepesBuyback(imd, pepes, pepesRouter, address(poolManager_)));
        _setStartTick(imd, imdStartTick);
        emit OwnershipTransferred(address(0), owner_);
        emit FeeRecipientUpdated(feeRecipient_);
    }

    // --------------------------------------------------------------- Launch

    /// @notice Deploys a token paired with `quote` (must be IMD) and locks its full supply in a v4 pool.
    ///         To launch with an initial buy in the same transaction use `PepesFamilyRouter.launch`.
    /// @param metadata JSON string, e.g. {"image":"https://…","description":"…","website":"…","x":"…","telegram":"…"}
    function launch(string calldata name, string calldata symbol, string calldata metadata, address quote)
        external
        returns (address token)
    {
        return _launch(msg.sender, name, symbol, metadata, quote);
    }

    function launchFor(
        address creator,
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address quote
    ) external returns (address token) {
        if (msg.sender != router) revert NotRouter();
        return _launch(creator, name, symbol, metadata, quote);
    }

    function _launch(
        address creator,
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address quote
    ) internal returns (address token) {
        if (quote != IMD) revert UnsupportedQuote();
        uint256 nameLen = bytes(name).length;
        uint256 symLen = bytes(symbol).length;
        if (nameLen == 0 || nameLen > 32 || symLen == 0 || symLen > 12 || bytes(metadata).length > 2048) {
            revert BadMetadata();
        }

        token = address(new PadToken(name, symbol, metadata, quote, creator, router, address(poolManager), buyback));
        bool quoteIs0 = uint160(quote) < uint160(token);
        launches[token] = Launch({
            quote: quote,
            creator: creator,
            createdAt: uint64(block.timestamp),
            createdBlock: _l2BlockNumber(),
            quoteIsCurrency0: quoteIs0
        });
        allTokens.push(token);

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
        token.transferOut(DEAD, PadToken(payable(token)).balanceOf(address(this)));
    }

    // ------------------------------------------------------------ Hook

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address token = tokenOfPool[key.toId()];
        bool exactIn = params.amountSpecified < 0;
        // Fee is taken here only when the quote currency is the swap's specified currency.
        if ((exactIn == params.zeroForOne) != launches[token].quoteIsCurrency0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        // exact-in buy: 4% of what the buyer pays. exact-out sell: 4% of the gross the pool pays out.
        uint256 fee = exactIn ? (amount * FEE_BPS) / BPS : (amount * FEE_BPS) / (BPS - FEE_BPS);
        _chargeFee(token, fee);
        assembly ("memory-safe") {
            tstore(FEE_SLOT, fee)
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

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
        uint256 tokenAmount = uint256(int256(t < 0 ? -t : t));

        uint256 fee;
        if ((exactIn == params.zeroForOne) == quoteIs0) {
            assembly ("memory-safe") {
                fee := tload(FEE_SLOT)
                tstore(FEE_SLOT, 0)
            }
        } else {
            // Quote is the unspecified side. exact-in sell: 4% of the pool's output.
            // exact-out buy: 4% of what the buyer pays in total.
            fee = exactIn ? (poolQuote * FEE_BPS) / BPS : (poolQuote * FEE_BPS) / (BPS - FEE_BPS);
            _chargeFee(token, fee);
            hookDelta = fee.toInt128();
        }

        bool isBuy = params.zeroForOne == quoteIs0;
        // Our two routers report their user; for any other router the best we know is the transaction's signer.
        address trader = (sender == router || sender == ethRouter) && hookData.length == 32
            ? abi.decode(hookData, (address))
            : tx.origin;
        // A buy of any size, through any router, is the buyer's own activity (v4 reward expiry, see PadToken).
        if (isBuy) PadToken(payable(token)).markActive(trader);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        emit Trade(token, trader, isBuy, isBuy ? poolQuote + fee : poolQuote - fee, tokenAmount, fee, sqrtPriceX96);
        return (IHooks.afterSwap.selector, hookDelta);
    }

    /// @dev The hook is credited `fee` by the swap; minting claims of the same size settles that credit.
    function _chargeFee(address token, uint256 fee) internal {
        if (fee == 0) return;
        address quote = launches[token].quote;
        uint256 protocolFee = (fee * PROTOCOL_FEE_BPS) / FEE_BPS;
        pendingProtocolFees[quote] += protocolFee;
        pendingHolderFees[token] += fee - protocolFee;
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

    /// @notice Sends pending protocol fees for `quote` to `feeRecipient`. Callable by anyone.
    function collectProtocolFees(address quote) external {
        if (pendingProtocolFees[quote] == 0) return;
        if (poolManager.isUnlocked()) _collect(quote);
        else poolManager.unlock(abi.encode(ACTION_COLLECT, abi.encode(quote)));
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

    function getTokenInfo(address token) public view returns (TokenInfo memory info) {
        Launch storage l = launches[token];
        PoolId id = poolKey(token).toId();
        (uint160 sqrtP,,,) = poolManager.getSlot0(id);
        PadToken t = PadToken(payable(token));
        info = TokenInfo({
            token: token,
            name: t.name(),
            symbol: t.symbol(),
            metadata: t.metadata(),
            quote: l.quote,
            creator: l.creator,
            createdAt: l.createdAt,
            createdBlock: l.createdBlock,
            quoteIsCurrency0: l.quoteIsCurrency0,
            poolId: id,
            sqrtPriceX96: sqrtP,
            marketCap: marketCap(token),
            pendingHolderFees: pendingHolderFees[token],
            totalDividendsDistributed: t.totalDividendsDistributed()
        });
    }

    /// @notice Paged token list, oldest first. Use `tokenCount()` to page from the end for newest-first.
    function getTokens(uint256 offset, uint256 limit) external view returns (TokenInfo[] memory infos) {
        uint256 n = allTokens.length;
        if (offset >= n) return infos;
        uint256 end = offset + limit > n ? n : offset + limit;
        infos = new TokenInfo[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            infos[i - offset] = getTokenInfo(allTokens[i]);
        }
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
