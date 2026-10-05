// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeTransfer} from "../lib/SafeTransfer.sol";

interface IPepesToken {
    function quote() external view returns (address);
    function claim() external returns (uint256);
}

interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

/// @title PepesWorldVault
/// @notice Lifetime access pass for Pepes World, the PepesFamily web game. A wallet can play if it holds at least
///         1 $EARN (one Pepes Earn IMD NFT) or if it has entered through this vault once.
///         Entering is a one-time deposit of `passPrice` $Pepes. The deposit is not refundable: the pass never
///         expires, and the deposited $Pepes belong to the PepesFamily team (`owner`), who can withdraw them and
///         the IMD rewards they earn. The owner can also grant free passes (giveaways, contest prizes).
///         Changing `passPrice` only affects future entries; existing passes are never revoked.
contract PepesWorldVault {
    using SafeTransfer for address;

    error NotOwner();
    error AlreadyEntered();
    error ZeroAddress();
    error WrongAmountReceived();

    event Entered(address indexed player, address indexed payer, uint256 amount);
    event PassGranted(address indexed player);
    event PassPriceSet(uint256 passPrice);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice $Pepes, the token deposited for a pass.
    address public immutable pepes;
    /// @notice $EARN: holding at least 1 whole token (= 1 NFT) also unlocks the game.
    address public immutable earn;
    /// @notice IMD, the asset $Pepes rewards are paid in.
    address public immutable imd;

    address public owner;
    address public pendingOwner;
    /// @notice $Pepes needed for a new pass.
    uint256 public passPrice;

    mapping(address => bool) public hasPass;
    uint256 public passes;
    uint256 public totalDeposited;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address pepes_, address earn_, address owner_, uint256 passPrice_) {
        if (pepes_ == address(0) || earn_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        pepes = pepes_;
        earn = earn_;
        imd = IPepesToken(pepes_).quote();
        owner = owner_;
        passPrice = passPrice_;
        emit OwnershipTransferred(address(0), owner_);
        emit PassPriceSet(passPrice_);
    }

    // ---------------------------------------------------------------- Players

    /// @notice Deposits `passPrice` $Pepes (approve this vault first) for a lifetime pass.
    function enter() external {
        _enter(msg.sender);
    }

    /// @notice Buys a pass for another wallet (a gift). The caller pays.
    function enterFor(address player) external {
        if (player == address(0)) revert ZeroAddress();
        _enter(player);
    }

    /// @notice True if `player` can play Pepes World: a pass from this vault, or at least 1 $EARN (1 NFT).
    function canPlay(address player) external view returns (bool) {
        return hasPass[player] || IBalanceOf(earn).balanceOf(player) >= 1e18;
    }

    function _enter(address player) internal {
        if (hasPass[player]) revert AlreadyEntered();
        uint256 amount = passPrice;
        hasPass[player] = true;
        passes++;
        totalDeposited += amount;
        uint256 before = pepes.balanceOf(address(this));
        pepes.transferFrom(msg.sender, address(this), amount);
        if (pepes.balanceOf(address(this)) - before != amount) revert WrongAmountReceived();
        emit Entered(player, msg.sender, amount);
    }

    // ---------------------------------------------------------------- Owner

    /// @notice Free pass, e.g. for a giveaway or a contest winner.
    function grantPass(address player) external onlyOwner {
        if (player == address(0)) revert ZeroAddress();
        if (hasPass[player]) revert AlreadyEntered();
        hasPass[player] = true;
        passes++;
        emit PassGranted(player);
    }

    /// @notice Sets the price of future passes. Existing passes are unaffected.
    function setPassPrice(uint256 passPrice_) external onlyOwner {
        passPrice = passPrice_;
        emit PassPriceSet(passPrice_);
    }

    /// @notice Claims the IMD rewards earned by the deposited $Pepes and sends this vault's IMD to `to`.
    function claimRewards(address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        IPepesToken(pepes).claim();
        amount = imd.balanceOf(address(this));
        imd.transferOut(to, amount);
        emit Withdrawn(imd, to, amount);
    }

    /// @notice Withdraws any token held here (the deposited $Pepes, IMD, or anything sent by mistake).
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.transferOut(to, amount);
        emit Withdrawn(token, to, amount);
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
}
