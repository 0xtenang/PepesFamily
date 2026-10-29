// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

interface IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @title UniV4SampledOracle
/// @notice Price feed for a coin/ETH Uniswap V4 pool. V4 pools keep no price history, so keepers record the
///         live price at least `minInterval` apart. The fast price is the median of the last 3 samples and the
///         slow price a time-weighted average of the samples.
/// @dev Reads PoolManager storage the same way v4-core's StateLibrary does (pools mapping at slot 6,
///      liquidity 3 slots after slot0). Check this against the deployed PoolManager before listing a coin.
///      Samples come only from approved keepers so nobody can move the price, record a sample and move it
///      back in one transaction. Each sample also records the pool's ETH depth; `read` reports the smallest
///      depth seen over the slow window, so liquidity added for a moment can't unlock more leverage.
contract UniV4SampledOracle is IPriceOracle, Ownable2Step {
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant LIQUIDITY_OFFSET = 3;
    uint256 internal constant Q96 = 2 ** 96;
    uint256 public constant CAPACITY = 128;
    uint256 public constant FAST_SAMPLES = 3;

    struct Sample {
        uint64 time;
        int24 tick;
        uint128 depth; // ETH-side reserves of the in-range liquidity when sampled
    }

    IExtsload public immutable manager;
    bytes32 public immutable poolId;
    bool public immutable ethIsCurrency0;
    uint32 public immutable fastWindow;
    uint32 public immutable slowWindow;
    uint32 public immutable minInterval;
    uint32 public immutable maxAge;

    Sample[CAPACITY] internal _samples;
    uint256 public head; // next write slot
    uint256 public count;
    mapping(address => bool) public isKeeper;

    event Poked(int24 tick, uint64 time);
    event KeeperSet(address keeper, bool allowed);

    error NotKeeper();
    error TooSoon();
    error Stale();
    error NotEnoughHistory();
    error BadWindows();

    constructor(
        IExtsload manager_,
        bytes32 poolId_,
        bool ethIsCurrency0_,
        uint32 fastWindow_,
        uint32 slowWindow_,
        uint32 minInterval_,
        uint32 maxAge_,
        address owner_
    ) Ownable(owner_) {
        // The fast price is the median of the last FAST_SAMPLES samples, which must all fall inside fastWindow, and
        // samples may never be more than 2 intervals apart, so one pushed reading can't carry the fast price.
        if (
            minInterval_ == 0 || fastWindow_ < FAST_SAMPLES * minInterval_ || slowWindow_ <= fastWindow_
                || slowWindow_ / minInterval_ >= CAPACITY || maxAge_ == 0 || maxAge_ > 2 * minInterval_
        ) revert BadWindows();
        manager = manager_;
        poolId = poolId_;
        ethIsCurrency0 = ethIsCurrency0_;
        fastWindow = fastWindow_;
        slowWindow = slowWindow_;
        minInterval = minInterval_;
        maxAge = maxAge_;
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    function poke() external {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        if (count > 0 && block.timestamp < _latest().time + minInterval) revert TooSoon();
        (int24 tick, uint256 depth) = _live();
        Sample memory s = Sample({time: uint64(block.timestamp), tick: tick, depth: uint128(depth)});
        _samples[head] = s;
        head = (head + 1) % CAPACITY;
        if (count < CAPACITY) count++;
        emit Poked(s.tick, s.time);
    }

    function read() external view returns (int24 spotTick, int24 fastTick, int24 slowTick, uint256 liquidityEth) {
        if (count == 0 || block.timestamp > _latest().time + maxAge) revert Stale();
        uint256 live;
        (spotTick, live) = _live();
        fastTick = _medianRecent(fastWindow);
        slowTick = _twap(slowWindow);
        liquidityEth = _minDepth(slowWindow);
        if (live < liquidityEth) liquidityEth = live;
    }

    function latestSample() external view returns (uint64 time, int24 tick) {
        Sample memory s = _latest();
        return (s.time, s.tick);
    }

    /// @dev Each sample holds from its time until the next sample (the newest holds until now).
    function _twap(uint32 window) internal view returns (int24) {
        uint256 start = block.timestamp - window;
        uint256 end = block.timestamp;
        int256 acc;
        for (uint256 k; k < count; ++k) {
            Sample memory s = _samples[(head + CAPACITY - 1 - k) % CAPACITY];
            uint256 from = s.time > start ? s.time : start;
            if (end > from) acc += int256(s.tick) * int256(end - from);
            if (s.time <= start) {
                int256 m = acc / int256(uint256(window));
                if (acc < 0 && acc % int256(uint256(window)) != 0) m--;
                return int24(m);
            }
            end = s.time;
        }
        revert NotEnoughHistory();
    }

    /// @dev Median of the newest FAST_SAMPLES samples. All of them must be inside `window`.
    function _medianRecent(uint32 window) internal view returns (int24) {
        if (count < FAST_SAMPLES) revert NotEnoughHistory();
        int24 a = _samples[(head + CAPACITY - 1) % CAPACITY].tick;
        int24 b = _samples[(head + CAPACITY - 2) % CAPACITY].tick;
        Sample memory oldest = _samples[(head + CAPACITY - 3) % CAPACITY];
        if (oldest.time + window < block.timestamp) revert NotEnoughHistory();
        int24 c = oldest.tick;
        if (a > b) (a, b) = (b, a);
        if (b > c) (b, c) = (c, b);
        if (a > b) (a, b) = (b, a);
        return b;
    }

    /// @dev Smallest sampled depth among the samples that cover the window.
    function _minDepth(uint32 window) internal view returns (uint256 m) {
        uint256 start = block.timestamp - window;
        m = type(uint256).max;
        for (uint256 k; k < count; ++k) {
            Sample memory s = _samples[(head + CAPACITY - 1 - k) % CAPACITY];
            if (s.depth < m) m = s.depth;
            if (s.time <= start) break;
        }
    }

    /// @dev The coin's live price in ETH (as a tick) and the pool's ETH depth. `UniV4BridgedOracle` overrides it.
    function _live() internal view virtual returns (int24 tick, uint256 depth) {
        (uint160 sqrtPriceX96, int24 raw) = _slot0();
        return (_norm(raw), _depth(sqrtPriceX96));
    }

    /// @dev ETH-side reserves of the pool's in-range liquidity at this price.
    function _depth(uint160 sqrtPriceX96) internal view returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        uint256 liq = uint128(uint256(manager.extsload(bytes32(uint256(_stateSlot()) + LIQUIDITY_OFFSET))));
        return ethIsCurrency0 ? Math.mulDiv(liq, Q96, sqrtPriceX96) : Math.mulDiv(liq, sqrtPriceX96, Q96);
    }

    function _latest() internal view returns (Sample memory) {
        return _samples[(head + CAPACITY - 1) % CAPACITY];
    }

    function _slot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        uint256 data = uint256(manager.extsload(_stateSlot()));
        sqrtPriceX96 = uint160(data);
        tick = int24(int256(data >> 160));
    }

    function _stateSlot() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, POOLS_SLOT));
    }

    /// @dev The pool prices currency0 in currency1. We want the coin priced in ETH.
    function _norm(int24 tick) internal view returns (int24) {
        return ethIsCurrency0 ? -tick : tick;
    }
}
