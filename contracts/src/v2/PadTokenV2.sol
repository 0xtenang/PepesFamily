// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeTransfer} from "../lib/SafeTransfer.sol";

interface IPadFlush {
    function flush(address token) external;
}

/// @title PadTokenV2 (deployed by PepesFamily v2 0x072Fb5A1…E8CC; kept so v2 tokens can be source-verified)
/// @notice Fixed-supply ERC20 launched by PepesFamily. Holders earn a pro-rata share of the 3% holder fee
///         charged on every Uniswap v4 swap of this token, paid in its quote asset (ETH or IMD).
/// @dev Dividends use the "magnified dividend per share" pattern: accrual is O(1) and automatic for every
///      holder on each distribution; holders withdraw with `claim()`. The pad, the router, the v4
///      PoolManager (which holds the pool's tokens), this contract and burn addresses are excluded.
contract PadTokenV2 {
    using SafeTransfer for address;

    error InsufficientBalance();
    error InsufficientAllowance();
    error InvalidRecipient();
    error EthNotAccepted();
    error Overflow();
    error Reentrancy();
    error PermitExpired();
    error InvalidSignature();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event DividendsDistributed(uint256 amount, uint256 eligibleSupply);
    event DividendClaimed(address indexed holder, uint256 amount);

    uint256 public constant totalSupply = 1_000_000_000e18;
    uint8 public constant decimals = 18;
    /// @dev Distributions wait until at least 1 whole token is held outside the pool. Bounds per-share growth.
    uint256 public constant MIN_ELIGIBLE_SUPPLY = 1e18;
    uint256 internal constant MAGNITUDE = 2 ** 128;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    string public name;
    string public symbol;
    /// @notice JSON metadata (image, description, links) supplied by the creator.
    string public metadata;

    address public immutable pad;
    address public immutable router;
    address public immutable poolManager;
    /// @notice Asset dividends are paid in. address(0) = ETH, otherwise IMD.
    address public immutable quote;
    address public immutable creator;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public magnifiedDividendPerShare;
    mapping(address => int256) internal magnifiedDividendCorrections;
    mapping(address => uint256) public withdrawnDividends;
    /// @notice Tokens held by dividend-eligible accounts.
    uint256 public eligibleSupply;
    /// @notice Quote held here that has already been accounted as dividends (distributed, not yet claimed).
    uint256 public accountedBalance;
    uint256 public totalDividendsDistributed;

    uint256 private _locked = 1;

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    mapping(address => uint256) public nonces;
    uint256 private immutable _initialChainId;
    bytes32 private immutable _initialDomainSeparator;

    constructor(
        string memory name_,
        string memory symbol_,
        string memory metadata_,
        address quote_,
        address creator_,
        address router_,
        address poolManager_
    ) {
        pad = msg.sender;
        router = router_;
        poolManager = poolManager_;
        quote = quote_;
        creator = creator_;
        name = name_;
        symbol = symbol_;
        metadata = metadata_;
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
        _initialChainId = block.chainid;
        _initialDomainSeparator = _domainSeparator();
    }

    receive() external payable {
        if (quote != address(0)) revert EthNotAccepted();
    }

    /// @notice This token has no owner and no admin functions: nothing about it can ever be changed.
    ///         Exposed as the zero address so explorers and scanners show it as renounced.
    function owner() external pure returns (address) {
        return address(0);
    }

    // ------------------------------------------------------------ EIP-2612

    /// @notice EIP-712 domain separator for `permit` (gasless approvals).
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _initialChainId ? _initialDomainSeparator : _domainSeparator();
    }

    /// @notice Sets `spender`'s allowance from `holder`'s signature instead of an `approve` transaction.
    function permit(address holder, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        if (block.timestamp > deadline) revert PermitExpired();
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, value, nonces[holder]++, deadline))
            )
        );
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != holder) revert InvalidSignature();
        allowance[holder][spender] = value;
        emit Approval(holder, spender, value);
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ---------------------------------------------------------------- ERC20

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @dev Standard allowance for every spender: no address is exempt. Routers get approval via
    ///      `approve` or a gasless EIP-2612 `permit` signature.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert InvalidRecipient();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
        }
        balanceOf[to] += amount;

        bool fromExcluded = isExcluded(from);
        bool toExcluded = isExcluded(to);
        int256 magCorrection = _toInt(magnifiedDividendPerShare * amount);
        if (!fromExcluded) magnifiedDividendCorrections[from] += magCorrection;
        if (!toExcluded) magnifiedDividendCorrections[to] -= magCorrection;
        if (fromExcluded && !toExcluded) eligibleSupply += amount;
        else if (!fromExcluded && toExcluded) eligibleSupply -= amount;

        emit Transfer(from, to, amount);
    }

    // ------------------------------------------------------------ Dividends

    function isExcluded(address account) public view returns (bool) {
        return account == poolManager || account == pad || account == router || account == address(this)
            || account == address(0) || account == DEAD;
    }

    /// @notice Spreads any quote received since the last call across current holders, pro rata.
    /// @dev Called by the pad after it forwards holder fees; anyone may call it (e.g. after a donation).
    ///      If nobody holds tokens yet, the funds wait here for the next distribution.
    function distribute() public returns (uint256 amount) {
        uint256 bal = quote.balanceOf(address(this));
        uint256 eligible = eligibleSupply;
        // Never revert: trades and claims call this, so an odd quote balance must not block them.
        if (bal <= accountedBalance || eligible < MIN_ELIGIBLE_SUPPLY) return 0;
        amount = bal - accountedBalance;
        magnifiedDividendPerShare += (amount * MAGNITUDE) / eligible;
        accountedBalance = bal;
        totalDividendsDistributed += amount;
        emit DividendsDistributed(amount, eligible);
    }

    function accumulativeDividendOf(address holder) public view returns (uint256) {
        if (isExcluded(holder)) return 0;
        int256 mag = _toInt(magnifiedDividendPerShare * balanceOf[holder]) + magnifiedDividendCorrections[holder];
        return mag <= 0 ? 0 : uint256(mag) / MAGNITUDE;
    }

    function withdrawableDividendOf(address holder) public view returns (uint256) {
        uint256 acc = accumulativeDividendOf(holder);
        uint256 done = withdrawnDividends[holder];
        return acc > done ? acc - done : 0;
    }

    /// @notice Pulls in fees from swaps made through other routers, then pays out the caller's share.
    function claim() external returns (uint256 amount) {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        IPadFlush(pad).flush(address(this));
        amount = withdrawableDividendOf(msg.sender);
        if (amount != 0) {
            withdrawnDividends[msg.sender] += amount;
            accountedBalance -= amount;
            quote.transferOut(msg.sender, amount);
            emit DividendClaimed(msg.sender, amount);
        }
        _locked = 1;
    }

    function _toInt(uint256 x) private pure returns (int256) {
        if (x > uint256(type(int256).max)) revert Overflow();
        return int256(x);
    }
}
