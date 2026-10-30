// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ILevExchange, ILevNav, IFeeSource} from "./interfaces/ILevPool.sol";

/// @title LevPool
/// @notice The ETH pool on the other side of every position. LPs hold transferable shares.
/// @dev NAV = cash - what open positions are worth to traders at slow prices. Creator fees arrive through
///      `donate` and raise the share price without minting shares. A seed deposit at deployment mints shares
///      to a dead address, so the first LP can't capture fees donated before anyone joined: while only dead
///      shares exist, donations mint more dead shares at the current price. That money stays in the pool for
///      good as house money and earns its share like any LP.
contract LevPool is ERC20, Ownable2Step, ReentrancyGuard {
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_COOLDOWN = 7 days;
    uint256 public constant MIN_COOLDOWN = 1 hours;
    uint256 public constant MIN_SEED = 0.001 ether;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct WithdrawRequest {
        uint256 shares;
        uint256 assets; // value when requested; the payout is the lower of this and the value at withdrawal
        uint64 unlockAt;
    }

    ILevExchange public exchange;
    /// @notice LevLens: values open positions for share pricing.
    ILevNav public navSource;
    /// @notice Creator-fee router. Pending fees are delivered before shares are priced, so a new LP can't buy in
    ///         just before fees that built up earlier land.
    IFeeSource public feeSource;
    uint256 public cash;
    uint256 public totalDonated;
    uint256 public withdrawCooldown = 1 days;
    uint256 public withdrawWindow = 2 days; // a matured request must be used within this, or cancelled and redone
    uint256 public minDeposit = 0.001 ether;
    mapping(address => WithdrawRequest) public withdrawRequests;

    event Deposited(address indexed lp, uint256 assets, uint256 shares);
    event Donated(address indexed from, uint256 amount);
    event WithdrawRequested(address indexed lp, uint256 shares, uint64 unlockAt);
    event WithdrawCancelled(address indexed lp, uint256 shares);
    event Withdrawn(address indexed lp, uint256 shares, uint256 assets);
    event WithdrawFeeKept(address indexed lp, uint256 fee);

    error AlreadySet();
    error OnlyExchange();
    error DepositTooSmall();
    error NoRequest();
    error StillLocked();
    error NotEnoughFreeCash();
    error TransferFailed();
    error BadValue();
    error PoolEmpty();
    error ValuationPaused();
    error RequestExpired();
    error BelowMinimum();

    modifier onlyExchange() {
        if (msg.sender != address(exchange)) revert OnlyExchange();
        _;
    }

    /// @dev Send at least MIN_SEED with the deployment. Its shares go to DEAD and can never be withdrawn.
    constructor(address owner_) payable ERC20("MemeLev LP", "mlETH") Ownable(owner_) {
        if (msg.value < MIN_SEED) revert DepositTooSmall();
        cash = msg.value;
        _mint(DEAD, msg.value);
        emit Deposited(DEAD, msg.value, msg.value);
    }

    /// @notice Creator fees, or anyone topping up the pool. Raises the share price.
    receive() external payable {
        _donate();
    }

    function donate() external payable {
        _donate();
    }

    function deposit() external payable nonReentrant returns (uint256 shares) {
        if (msg.value < minDeposit) revert DepositTooSmall();
        _harvest();
        (, uint256 high) = _valuation();
        if (high == 0) revert PoolEmpty();
        shares = (msg.value * totalSupply()) / high;
        if (shares == 0) revert DepositTooSmall();
        cash += msg.value;
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, msg.value, shares);
    }

    /// @notice Lock shares now and withdraw them once the cooldown ends, at the lower of their value now and
    ///         their value then. Locked shares still take losses but give up gains, so a request is never a free
    ///         option on the pool. Adding to a pending request restarts its cooldown.
    function requestWithdraw(uint256 shares) external {
        if (shares == 0) revert BadValue();
        _harvest();
        (uint256 low,) = _valuation();
        uint256 value = (shares * low) / totalSupply();
        _transfer(msg.sender, address(this), shares);
        WithdrawRequest storage r = withdrawRequests[msg.sender];
        r.shares += shares;
        r.assets += value;
        r.unlockAt = uint64(block.timestamp + withdrawCooldown);
        emit WithdrawRequested(msg.sender, r.shares, r.unlockAt);
    }

    function cancelWithdraw() external {
        uint256 shares = withdrawRequests[msg.sender].shares;
        if (shares == 0) revert NoRequest();
        delete withdrawRequests[msg.sender];
        _transfer(address(this), msg.sender, shares);
        emit WithdrawCancelled(msg.sender, shares);
    }

    /// @notice Withdraw a matured request, at the lower of its value then and now, less the stress fee.
    /// @param minAssets The least the LP accepts. The value now marks open positions at the coin's live price too,
    ///        so a price pushed in this block could lower it: the LP's floor makes such a withdrawal fail instead
    ///        (IMD audit 964f33f1, M-3). Pass about the quoted payout less the stress fee and a little slack.
    function withdraw(uint256 minAssets) external nonReentrant returns (uint256 assets) {
        WithdrawRequest memory r = withdrawRequests[msg.sender];
        if (r.shares == 0) revert NoRequest();
        if (block.timestamp < r.unlockAt) revert StillLocked();
        if (block.timestamp > uint256(r.unlockAt) + withdrawWindow) revert RequestExpired();
        (uint256 low,) = _valuation();
        assets = (r.shares * low) / totalSupply();
        if (assets > r.assets) assets = r.assets;
        uint256 fee = (assets * _withdrawFeeBps(low)) / BPS;
        assets -= fee;
        if (assets < minAssets) revert BelowMinimum();
        if (assets > freeCash()) revert NotEnoughFreeCash();
        delete withdrawRequests[msg.sender];
        _burn(address(this), r.shares);
        cash -= assets;
        _send(msg.sender, assets);
        if (fee > 0) emit WithdrawFeeKept(msg.sender, fee);
        emit Withdrawn(msg.sender, r.shares, assets);
    }

    // --------------------------------------------------------------- exchange

    function receiveFromExchange() external payable onlyExchange {
        cash += msg.value;
    }

    function payToExchange(uint256 amount) external onlyExchange {
        cash -= amount;
        _send(msg.sender, amount);
    }

    // ------------------------------------------------------------------ views

    /// @notice What the pool is worth if open positions are marked at the price worse for the pool: what LPs
    ///         could take out right now.
    function nav() public view returns (uint256 low) {
        (low,) = navRange();
    }

    /// @notice Pool value with open positions marked at whichever of the slow and fast price is worse (`low`) or
    ///         better (`high`) for the pool. Withdrawals pay out at `low`; deposits buy in at `high`.
    function navRange() public view returns (uint256 low, uint256 high) {
        if (address(navSource) == address(0)) return (cash, cash);
        (int256 owedLow, int256 owedHigh,) = navSource.liabilityRange();
        return (_floor(int256(cash) - owedHigh), _floor(int256(cash) - owedLow));
    }

    /// @notice False while open positions can't be valued fairly (a feed is down or a rug is unsettled).
    function valuationOk() public view returns (bool) {
        if (address(navSource) == address(0)) return true;
        (,, bool blocked) = navSource.liabilityRange();
        return !blocked;
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        (, uint256 high) = navRange();
        if (high == 0) revert PoolEmpty();
        return (assets * totalSupply()) / high;
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        (uint256 low,) = navRange();
        return (shares * low) / totalSupply();
    }

    /// @notice Fee on withdrawals while traders are winning against the pool, kept by the pool for the LPs who
    ///         stay (Veranta's buffer-ratio fee). Ratio = pool value at the worst price / cash: 1.0 or more is free,
    ///         0.5% down to 0.95, 1.5% down to 0.90, 2.5% below. It slows a run on the pool when it can least afford one.
    function withdrawFeeBps() public view returns (uint256) {
        (uint256 low,) = navRange();
        return _withdrawFeeBps(low);
    }

    function _withdrawFeeBps(uint256 low) internal view returns (uint256) {
        if (cash == 0) return 0;
        uint256 ratio = (low * BPS) / cash;
        return ratio >= BPS ? 0 : ratio >= 9500 ? 50 : ratio >= 9000 ? 150 : 250;
    }

    /// @notice ETH per 1e18 shares.
    function sharePrice() external view returns (uint256) {
        return previewRedeem(1e18);
    }

    /// @notice Cash not reserved for open max wins. LPs can always take this out; the 50% coverage rule limits
    ///         new positions, not LP exits.
    function freeCash() public view returns (uint256) {
        if (address(exchange) == address(0)) return cash;
        uint256 reserved = exchange.totalMaxWin();
        return cash > reserved ? cash - reserved : 0;
    }

    // ------------------------------------------------------------------ admin

    function setExchange(ILevExchange exchange_) external onlyOwner {
        if (address(exchange) != address(0)) revert AlreadySet();
        exchange = exchange_;
    }

    function setNavSource(ILevNav navSource_) external onlyOwner {
        if (address(navSource) != address(0)) revert AlreadySet();
        navSource = navSource_;
    }

    function setFeeSource(IFeeSource feeSource_) external onlyOwner {
        if (address(feeSource) != address(0)) revert AlreadySet();
        feeSource = feeSource_;
    }

    function setWithdrawCooldown(uint256 seconds_) external onlyOwner {
        if (seconds_ < MIN_COOLDOWN || seconds_ > MAX_COOLDOWN) revert BadValue();
        withdrawCooldown = seconds_;
    }

    function setWithdrawWindow(uint256 seconds_) external onlyOwner {
        if (seconds_ < 1 hours || seconds_ > MAX_COOLDOWN) revert BadValue();
        withdrawWindow = seconds_;
    }

    function setMinDeposit(uint256 amount) external onlyOwner {
        if (amount == 0) revert BadValue();
        minDeposit = amount;
    }

    // --------------------------------------------------------------- internal

    function _donate() internal {
        // Before any LP has joined, book creator fees as more house shares at today's price instead of
        // raising the price of the tiny seed, so the share price stays readable for the first LP.
        uint256 supply = totalSupply();
        if (supply == balanceOf(DEAD)) {
            uint256 v = nav();
            _mint(DEAD, v == 0 ? msg.value : (msg.value * supply) / v);
        }
        cash += msg.value;
        totalDonated += msg.value;
        emit Donated(msg.sender, msg.value);
    }

    function _harvest() internal {
        if (address(feeSource) != address(0)) {
            try feeSource.harvest() {} catch {}
        }
    }

    /// @dev navRange in one valuation, reverting while it is paused: the valuation reads every open position.
    function _valuation() internal view returns (uint256 low, uint256 high) {
        if (address(navSource) == address(0)) return (cash, cash);
        (int256 owedLow, int256 owedHigh, bool blocked) = navSource.liabilityRange();
        if (blocked) revert ValuationPaused();
        return (_floor(int256(cash) - owedHigh), _floor(int256(cash) - owedLow));
    }

    function _floor(int256 v) internal pure returns (uint256) {
        return v > 0 ? uint256(v) : 0;
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
