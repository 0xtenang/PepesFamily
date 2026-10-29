// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ILevPool} from "./interfaces/ILevPool.sol";
import {LevLogic} from "./libraries/LevLogic.sol";
import {ConfigCheck} from "./libraries/ConfigCheck.sol";
import {Config, Side, Market, Position} from "./LevTypes.sol";

/// @title LevExchangeBase
/// @notice Storage, events, errors and shared helpers of the exchange. LevExchange (money paths) and
///         LevExchangeAdmin (listings, config, guard, reads) both inherit it, so they share one storage layout:
///         LevExchange forwards every call it doesn't handle to LevExchangeAdmin with delegatecall.
/// @dev Never add, remove or reorder state variables in only one of the two contracts. Add them here.
abstract contract LevExchangeBase is Ownable2Step, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.UintSet;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant HOUR = 3600;
    uint256 internal constant NO_SLIP_BOUND = type(uint256).max;
    uint256 public constant MAX_MARKETS = 64;
    /// @dev Failed reads must keep coming at most this far apart for the stale clock to keep running.
    uint256 public constant STALE_PING_GAP = 120;

    uint8 public constant EXIT_CLOSE = 0;
    uint8 public constant EXIT_LIQUIDATION = 1;
    uint8 public constant EXIT_MAX_WIN = 2;
    uint8 public constant EXIT_RUG = 3;
    uint8 public constant EXIT_STALE = 4;

    address public treasury;
    address public guardian;
    bool public opensPaused;
    /// @notice LevRouter: runs trades signed by a trader's session key. Set once. It can only open and close
    ///         for a trader and withdraw to the trader's own address.
    address public router;

    Config internal _config;
    Market[] internal _markets;
    mapping(uint256 => Position) internal _positions;
    EnumerableSet.UintSet internal _openIds;
    mapping(address => EnumerableSet.UintSet) internal _byOwner;
    mapping(uint256 => mapping(uint32 => int24)) public rugTickOf;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public openStakeOf; // sum of a trader's open stakes, for session limits
    uint256 public nextPositionId = 1;
    uint256 public totalMaxWin;
    uint256 public treasuryBalance;
    uint64 public hourStart;
    uint256 public hourStartCash;
    int256 public hourPoolPnl; // pool's trading result since hourStart: fees and losses in, wins out
    uint64 public breakerUntil; // new positions are paused until this time after the loss breaker trips

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Opened(
        uint256 indexed id,
        address indexed owner,
        uint256 indexed marketId,
        bool isLong,
        uint8 leverage,
        uint256 stake,
        int24 entryTick,
        uint32 maxWinBps,
        uint256 fee
    );
    event Closed(
        uint256 indexed id,
        address indexed owner,
        uint256 indexed marketId,
        uint8 kind,
        int256 pnl,
        uint256 holdFee,
        uint256 fees,
        uint256 payout,
        address keeper,
        uint256 keeperReward
    );
    event MarketListed(uint256 indexed marketId, address oracle, uint8 maxLeverage, uint256 netCapEth, int24 refTick);
    event MarketUpdated(uint256 indexed marketId, bool active, uint8 maxLeverage, uint256 netCapEth);
    event RugGuardTriggered(uint256 indexed marketId, uint32 epoch, int24 fastTick, int24 slowTick);
    event FeedDown(uint256 indexed marketId, uint64 since);
    event ConfigUpdated();
    event OpensPaused(bool paused);
    event TreasuryClaimed(address to, uint256 amount);
    event RouterSet(address router);

    error MarketClosed();
    error MarketLocked();
    error StakeTooSmall();
    error LeverageNotAllowed();
    error PriceMoved();
    error CoinFull();
    error PoolFull();
    error InsufficientBalance();
    error NotPositionOwner();
    error NotOpen();
    error TooSoon();
    error OracleDown();
    error NotLiquidatable();
    error NotAtMaxWin();
    error NoRug();
    error NotRugged();
    error BreakerTripped();
    error LiquidityTooLow();
    error BadConfig();
    error TooManyMarkets();
    error TransferFailed();
    error Unauthorized();
    error AlreadySet();
    error RugInProgress();
    error WouldLiquidate();

    modifier onlyRouter() {
        if (msg.sender != router || router == address(0)) revert Unauthorized();
        _;
    }

    constructor(address owner_, address treasury_) Ownable(owner_) {
        treasury = treasury_;
        Config memory c = Config({
            openFeeStakeBps: 100,
            openFeeSizeBps: 25,
            profitFeeBps: 1000,
            poolFeeShareBps: 5000,
            holdRateBpsPerHour: 5,
            crowdMultBps: 30_000,
            freeHoldSeconds: 3600,
            liqEquityBps: 1500,
            keeperRewardBps: 2500,
            longMaxWinBps: 40_000,
            longMaxWinBps2: 60_000,
            longMaxWinBps3: 100_000,
            maxWinTier2Cash: 10 ether,
            maxWinTier3Cash: 20 ether,
            shortMaxWinBps: 10_000,
            maxShortLeverage: 5,
            lev5LiquidityEth: 7.5 ether,
            lev10LiquidityEth: 25 ether,
            minLiquidityEth: 1 ether,
            netCapLiquidityBps: 50,
            coverageBps: 5000,
            rugDropBps: 8000,
            rugCapBps: 2000,
            rugLockSeconds: 3600,
            minHoldSeconds: 10,
            staleSeconds: 600,
            hourlyLossBreakerBps: 1000,
            minStake: 0.001 ether
        });
        _validate(c);
        _config = c;
    }

    // ---------------------------------------------------------------- shared

    function _accrue(Market storage m, Config memory c) internal {
        uint256 dt = block.timestamp - m.lastFeeUpdate;
        if (dt == 0) return;
        m.lastFeeUpdate = uint64(block.timestamp);
        (uint256 gl, uint256 gs) = LevLogic.feeGrowth(c, dt, m.longs.size, m.shorts.size);
        m.longs.feeIndex += gl;
        m.shorts.feeIndex += gs;
    }

    function _tryRead(Market storage m)
        internal
        view
        returns (bool ok, int24 spot, int24 fast, int24 slow, uint256 liq)
    {
        try m.oracle.read() returns (int24 s, int24 f, int24 sl, uint256 l) {
            return (true, s, f, sl, l);
        } catch {
            return (false, 0, 0, 0, 0);
        }
    }

    function _recordGood(Market storage m, int24 fast, int24 slow) internal {
        m.lastGoodTick = slow;
        m.lastGoodFast = fast;
        m.lastGoodAt = uint64(block.timestamp);
        if (m.downSince != 0) {
            m.downSince = 0;
            m.lastFailAt = 0;
        }
    }

    function _market(uint256 id) internal view returns (Market storage) {
        if (id >= _markets.length) revert MarketClosed();
        return _markets[id];
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev Hard limits the owner can't go past, so LPs and traders know the worst case.
    function _validate(Config memory c) internal pure {
        if (!ConfigCheck.isValid(c)) revert BadConfig();
    }

    function _max24(int24 a, int24 b) internal pure returns (int24) {
        return a > b ? a : b;
    }

    function _min24(int24 a, int24 b) internal pure returns (int24) {
        return a < b ? a : b;
    }
}
