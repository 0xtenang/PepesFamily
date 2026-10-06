// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeTransfer} from "./lib/SafeTransfer.sol";

/// @dev PepesFamily v1 router: buys an IMD-paired token with IMD for msg.sender.
interface IPepesRouterV1 {
    function buy(address token, uint256 amountIn, uint256 minTokensOut, uint256 deadline)
        external
        payable
        returns (uint256);
    function pad() external view returns (address);
}

/// @dev PepesFamily v1 launchpad: gives the $Pepes pool key.
interface IPepesPadV1 {
    function poolKey(address token) external view returns (PoolKey memory);
}

/// @title PepesBuyback
/// @notice Shared $Pepes buyback-and-burn for every PepesFamily v4 token. Expired holder rewards (see PadToken) are
///         sent here as IMD; anyone can spend them buying $Pepes, which all go to the burn address.
///         One contract for all v4 tokens, so one cap and one hourly pace cover every buyback: if each token
///         bought back on its own, many buybacks could be stacked in one transaction and sandwiched together.
/// @dev No owner and no privileged function: the IMD here can only ever leave through the burn swap.
contract PepesBuyback {
    using SafeTransfer for address;
    using StateLibrary for IPoolManager;

    error TooSoon();
    error BadAmount();
    error ApproveFailed();
    error Reentrancy();
    error ZeroAddress();

    event PepesBoughtAndBurned(uint256 imdIn, uint256 pepesBurned);

    /// @notice IMD spent per buyback: at most 1% of the $Pepes pool's IMD depth, at most once an hour. Half of the
    ///         $EARN buyback's 2%, so both together stay within the 2%-of-depth bound under which a sandwich costs
    ///         more in the $Pepes pool's 4% fees (each way) than it can move the price.
    uint256 public constant MAX_BUYBACK_BPS = 100;
    uint256 public constant BUYBACK_INTERVAL = 1 hours;
    uint256 internal constant Q96 = 2 ** 96;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable imd;
    address public immutable pepes;
    /// @notice PepesFamily v1 router, through which $Pepes is bought.
    address public immutable pepesRouter;
    address public immutable poolManager;

    uint256 public lastBuyback;
    uint256 public totalImdSpent;
    uint256 public totalPepesBurned;

    uint256 private _locked = 1;

    constructor(address imd_, address pepes_, address pepesRouter_, address poolManager_) {
        if (imd_ == address(0) || pepes_ == address(0) || pepesRouter_ == address(0) || poolManager_ == address(0)) {
            revert ZeroAddress();
        }
        imd = imd_;
        pepes = pepes_;
        pepesRouter = pepesRouter_;
        poolManager = poolManager_;
    }

    /// @notice IMD waiting to be spent on buybacks.
    function reserve() external view returns (uint256) {
        return imd.balanceOf(address(this));
    }

    /// @notice Spends up to `maxBuyback()` of the IMD here on $Pepes and sends all of it to the burn address.
    ///         Callable by anyone, at most once an hour; larger reserves burn over several calls.
    /// @param minPepesOut minimum $Pepes bought (0 accepts the capped market price)
    function buybackAndBurnPepes(uint256 minPepesOut, uint256 deadline) external returns (uint256 burned) {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        if (block.timestamp < lastBuyback + BUYBACK_INTERVAL) revert TooSoon();
        uint256 imdIn = imd.balanceOf(address(this));
        uint256 cap = maxBuyback();
        if (imdIn > cap) imdIn = cap;
        if (imdIn == 0) revert BadAmount();
        lastBuyback = block.timestamp;
        _approve(imd, pepesRouter, imdIn);
        uint256 before = pepes.balanceOf(address(this));
        IPepesRouterV1(pepesRouter).buy(pepes, imdIn, minPepesOut, deadline);
        _approve(imd, pepesRouter, 0);
        burned = pepes.balanceOf(address(this)) - before;
        pepes.transferOut(DEAD, burned);
        totalImdSpent += imdIn;
        totalPepesBurned += burned;
        emit PepesBoughtAndBurned(imdIn, burned);
        _locked = 1;
    }

    /// @notice Most IMD one buyback spends: 1% of the $Pepes pool's (virtual) IMD reserve at the current price,
    ///         read from the PepesFamily v1 pool through the PoolManager.
    function maxBuyback() public view returns (uint256) {
        PoolKey memory key = IPepesPadV1(IPepesRouterV1(pepesRouter).pad()).poolKey(pepes);
        PoolId id = key.toId();
        (uint160 sqrtP,,,) = IPoolManager(poolManager).getSlot0(id);
        if (sqrtP == 0) return 0;
        uint256 liquidity = IPoolManager(poolManager).getLiquidity(id);
        uint256 imdDepth = Currency.unwrap(key.currency0) == imd
            ? FullMath.mulDiv(liquidity, Q96, sqrtP) // IMD is currency0: x = L / sqrtP
            : FullMath.mulDiv(liquidity, sqrtP, Q96); // IMD is currency1: y = L * sqrtP
        return (imdDepth * MAX_BUYBACK_BPS) / 10_000;
    }

    function _approve(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert ApproveFailed();
    }
}
