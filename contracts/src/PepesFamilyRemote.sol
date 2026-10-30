// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeTransfer} from "./lib/SafeTransfer.sol";

interface IRemotePad {
    struct FeeSplit {
        uint16 creatorBps;
        uint16 holderBps;
        uint16 burnBps;
    }

    function IMD() external view returns (address);
    function ethRouter() external view returns (address);
    function launches(address token)
        external
        view
        returns (address quote, address creator, uint64 createdAt, uint64 createdBlock, bool quoteIsCurrency0);
    function launchWithSplit(string calldata name, string calldata symbol, string calldata metadata, address quote, FeeSplit calldata split)
        external
        returns (address token);
    function collectCreatorFees(address token) external;
    function setCreatorPayout(address token, address payout) external;
    function acceptCreatorPayout(address token) external;
    function creatorPayout(address token) external view returns (address);
    function pendingCreatorPayout(address token) external view returns (address);
}

interface IRemoteEthRouter {
    function buyWithEth(address token, uint256 minTokensOut, uint256 deadline) external payable returns (uint256 tokensOut);
}

interface IRemoteToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title RemoteCreatorVault
/// @notice The launchpad's creator payout for one token launched through PepesFamilyRemote. Every creator fee of that
///         token lands here, whoever triggers the collection (the launchpad's `collectCreatorFees` is public), so
///         it always belongs to that token's creator, and the Remote sends it on (IMD audit 964f33f1, H-1).
/// @dev The Remote deploys one of these and gives each token a minimal clone of it (EIP-1167, ~45k gas, so a
///      cross-chain launch stays inside HyperEVM's 3M-gas fast blocks). A clone keeps no storage: only the Remote
///      (this implementation's immutable) can call it, naming the launchpad and token each time.
contract RemoteCreatorVault {
    using SafeTransfer for address;

    error NotRemote();

    address public immutable remote;

    constructor() {
        remote = msg.sender;
    }

    modifier onlyRemote() {
        if (msg.sender != remote) revert NotRemote();
        _;
    }

    /// @notice Takes the payout role the Remote proposed for this vault.
    function accept(address pad, address token) external onlyRemote {
        IRemotePad(pad).acceptCreatorPayout(token);
    }

    /// @notice Proposes `payout` as the token's creator payout on the launchpad (address(0) cancels a proposal).
    function propose(address pad, address token, address payout) external onlyRemote {
        IRemotePad(pad).setCreatorPayout(token, payout);
    }

    /// @notice Collects the token's waiting creator fees and sends everything this vault holds of `quote` to `to`.
    function forward(address pad, address token, address quote, address to) external onlyRemote returns (uint256 amount) {
        if (IRemotePad(pad).creatorPayout(token) == address(this)) IRemotePad(pad).collectCreatorFees(token);
        amount = IRemoteToken(quote).balanceOf(address(this));
        if (amount != 0) quote.transferOut(to, amount);
    }
}

/// @title PepesFamilyRemote
/// @notice Launch and buy PepesFamily tokens for someone else, paid in the chain's coin: the entry point for
///         cross-chain actions. A filler such as Relay or Across delivers the coin here from a payment the user made on
///         another chain and calls `launchFor` or `buyFor` with the user's address, in the same transaction.
///         - Tokens bought go straight to the user; nothing is kept here between transactions.
///         - A token launched here has this contract as its creator on the launchpad, so it records the real creator
///           (`creatorOf`). Its creator fees are paid to a vault of its own (`vaultOf`), and this contract passes
///           them to the creator (`collectCreatorFees`, callable by anyone). The creator can also take the creator
///           fees over directly on the launchpad (`handOver`, then the launchpad's `acceptCreatorPayout`), or pass
///           the role to another address (`transferCreator`) while the vault still holds it.
///         - `gasDrop` leaves the user a little of the chain's coin, so they can claim and sell there later.
///         Only launchpads on the allowlist are used (the owner adds them: PepesFamily v5 launchpads only), so a fake
///         launchpad can never be used to claim another token's creator role.
contract PepesFamilyRemote {
    using SafeTransfer for address;

    error NotOwner();
    error NotPad();
    error NotCreator();
    error ZeroAddress();
    error BadValue();
    error Reentered();
    error AlreadyRecorded();
    error DropFailed();
    error HandedOverAlready();

    event LaunchedFor(address indexed pad, address indexed token, address indexed creator, uint256 spent, uint256 tokens);
    event BoughtFor(address indexed pad, address indexed token, address indexed buyer, uint256 spent, uint256 tokens);
    event GasDropped(address indexed to, uint256 amount);
    event CreatorFeesForwarded(address indexed token, address indexed creator, uint256 amount);
    event CreatorTransferred(address indexed token, address indexed from, address indexed to);
    event HandedOver(address indexed token, address indexed creator);
    event PadSet(address indexed pad, bool allowed);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed from, address indexed to);

    address public owner;
    address public pendingOwner;
    /// @notice The PepesFamily launchpads this contract works with.
    mapping(address pad => bool) public isPad;
    /// @notice The real creator of a token launched here (this contract is its creator on the launchpad).
    mapping(address token => address) public creatorOf;
    /// @notice The launchpad of a token launched here.
    mapping(address token => address) public padOf;
    /// @notice The launchpad's creator payout for a token launched here, until the creator takes it over.
    mapping(address token => RemoteCreatorVault) public vaultOf;
    /// @notice The vault code every token's vault is a clone of.
    address public immutable vaultImplementation;

    uint256 private locked = 1;

    modifier nonReentrant() {
        if (locked != 1) revert Reentered();
        locked = 2;
        _;
        locked = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, address[] memory pads) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        vaultImplementation = address(new RemoteCreatorVault());
        emit OwnershipTransferred(address(0), owner_);
        for (uint256 i; i < pads.length; i++) {
            isPad[pads[i]] = true;
            emit PadSet(pads[i], true);
        }
    }

    /// @notice Refunds from the routers (unspent coin) and wrapped-coin withdrawals land here, and go on to the user
    ///         within the same call.
    receive() external payable {}

    // ---------------------------------------------------------------- for users

    /// @notice Launch a token for `creator` on `pad` (paired with the launchpad's asset), buy it with `buyValue` of
    ///         the coin sent (0: no buy), and give `creator` the tokens and `gasDrop` of the coin.
    ///         msg.value must be buyValue + gasDrop.
    function launchFor(
        address pad,
        address creator,
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        IRemotePad.FeeSplit calldata split,
        uint256 buyValue,
        uint256 minTokens,
        uint256 gasDrop
    ) external payable nonReentrant returns (address token, uint256 tokens) {
        if (!isPad[pad]) revert NotPad();
        if (creator == address(0)) revert ZeroAddress();
        if (msg.value != buyValue + gasDrop) revert BadValue();
        token = IRemotePad(pad).launchWithSplit(name, symbol, metadata, IRemotePad(pad).IMD(), split);
        if (creatorOf[token] != address(0)) revert AlreadyRecorded();
        creatorOf[token] = creator;
        padOf[token] = pad;
        RemoteCreatorVault vault = RemoteCreatorVault(_clone(vaultImplementation));
        vaultOf[token] = vault;
        IRemotePad(pad).setCreatorPayout(token, address(vault));
        vault.accept(pad, token);
        if (buyValue != 0) tokens = _buy(pad, token, creator, buyValue, minTokens);
        _drop(creator, gasDrop);
        emit LaunchedFor(pad, token, creator, buyValue, tokens);
    }

    /// @notice Buy `token` on `pad` for `buyer` with the coin sent minus `gasDrop`, and give `buyer` the tokens and
    ///         `gasDrop` of the coin.
    function buyFor(address pad, address token, address buyer, uint256 minTokens, uint256 gasDrop)
        external
        payable
        nonReentrant
        returns (uint256 tokens)
    {
        if (!isPad[pad]) revert NotPad();
        if (buyer == address(0)) revert ZeroAddress();
        if (msg.value <= gasDrop) revert BadValue();
        tokens = _buy(pad, token, buyer, msg.value - gasDrop, minTokens);
        _drop(buyer, gasDrop);
        emit BoughtFor(pad, token, buyer, msg.value - gasDrop, tokens);
    }

    /// @notice Sends `token`'s creator fees to its creator: those waiting on the launchpad and any already
    ///         collected into the token's vault. Callable by anyone. (After `handOver` the launchpad pays the
    ///         creator directly; this still sends on anything the vault received before.)
    function collectCreatorFees(address token) external nonReentrant returns (uint256 amount) {
        amount = _forward(token);
    }

    /// @notice The creator proposes themselves as the launchpad's creator payout for `token`; they then call the
    ///         launchpad's `acceptCreatorPayout(token)` to receive creator fees directly.
    function handOver(address token) external nonReentrant {
        address creator = creatorOf[token];
        if (msg.sender != creator) revert NotCreator();
        _requireVaultPays(token);
        vaultOf[token].propose(padOf[token], token, creator);
        emit HandedOver(token, creator);
    }

    /// @notice The creator passes the creator role of `token` to `to`. Fees earned so far go to the current creator
    ///         first, and a handover the current creator proposed is cancelled, so it can't be accepted after the
    ///         role has passed on (IMD audit 964f33f1, L-5). Once the creator has taken the payout over on the
    ///         launchpad, the role lives there: pass it with the launchpad's `setCreatorPayout` instead.
    function transferCreator(address token, address to) external nonReentrant {
        if (msg.sender != creatorOf[token]) revert NotCreator();
        if (to == address(0)) revert ZeroAddress();
        _requireVaultPays(token);
        _forward(token);
        address pad = padOf[token];
        if (IRemotePad(pad).pendingCreatorPayout(token) != address(0)) vaultOf[token].propose(pad, token, address(0));
        creatorOf[token] = to;
        emit CreatorTransferred(token, msg.sender, to);
    }

    // ---------------------------------------------------------------- owner

    /// @notice Adds or removes a launchpad. It can't move any funds; it only decides which launchpads are used.
    function setPad(address pad, bool allowed) external onlyOwner {
        isPad[pad] = allowed;
        emit PadSet(pad, allowed);
    }

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

    // ---------------------------------------------------------------- internal

    /// @dev Buys through the launchpad's ETH router (the coin, wrapped or swapped to the pair asset), passes the
    ///      tokens on, and returns any coin the router gave back.
    function _buy(address pad, address token, address to, uint256 value, uint256 minTokens) internal returns (uint256 tokens) {
        uint256 coinBefore = address(this).balance - value;
        tokens = IRemoteEthRouter(IRemotePad(pad).ethRouter()).buyWithEth{value: value}(token, minTokens, block.timestamp);
        token.transferOut(to, tokens);
        uint256 refund = address(this).balance - coinBefore;
        if (refund != 0) address(0).transferOut(to, refund);
    }

    function _forward(address token) internal returns (uint256 amount) {
        address creator = creatorOf[token];
        if (creator == address(0)) revert NotCreator();
        address pad = padOf[token];
        (address quote,,,,) = IRemotePad(pad).launches(token);
        amount = vaultOf[token].forward(pad, token, quote, creator);
        emit CreatorFeesForwarded(token, creator, amount);
    }

    /// @dev EIP-1167 minimal proxy of `impl`.
    function _clone(address impl) internal returns (address instance) {
        assembly ("memory-safe") {
            mstore(0x00, or(shr(0xe8, shl(0x60, impl)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            mstore(0x20, or(shl(0x78, impl), 0x5af43d82803e903d91602b57fd5bf3))
            instance := create(0, 0x09, 0x37)
        }
        if (instance == address(0)) revert ZeroAddress();
    }

    function _requireVaultPays(address token) internal view {
        if (IRemotePad(padOf[token]).creatorPayout(token) != address(vaultOf[token])) revert HandedOverAlready();
    }

    function _drop(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert DropFailed();
        emit GasDropped(to, amount);
    }
}
