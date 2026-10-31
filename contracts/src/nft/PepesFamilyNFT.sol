// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "solmate/src/tokens/ERC721.sol";
import {SafeTransfer} from "../lib/SafeTransfer.sol";
import {NativePayout} from "../lib/NativePayout.sol";

interface IPepesFamilyArt {
    function tokenURI(uint256 id, uint256 n) external view returns (string memory);
}

/// @notice Limit Break's Creator Token transfer validator (ERC-721C), which OpenSea Studio configures.
interface ITransferValidator {
    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
}

/// @title PepesFamilyNFT (PEPES FAMILY)
/// @notice 2,000 NFTs. Every token launched on PepesFamily v6 pays 1% of each trade to the holders of this collection:
///         the launchpad on this chain sends it here, and the team moves the 1% earned on other chains here too.
///         Anything sent here in a reward asset is shared by all minted NFTs equally, and each wallet earns for the
///         NFTs it holds at the time. Like PepesFamily tokens, rewards belong to the wallet that earned them: a
///         seller keeps what its NFTs earned before the sale, the buyer earns from then on. Rewards never expire.
///         Rewards in WETH (`weth`) are paid as plain ETH, or as WETH to a wallet that can't receive ETH.
///
///         Royalties: ERC-2981 (5% at launch), editable by the owner. The collection is an ERC-721C creator token:
///         the owner can point it at a transfer validator (OpenSea Studio does this) so only marketplaces that pay
///         royalties can move NFTs; mints and the owner's own settings are never affected.
///
///         Art: fully on-chain (PepesFamilyArt). Token `id` shows entry `id - 1` of the art's fixed list of 2,000 trait
///         combinations, visible from the moment it is minted (no reveal).
/// @dev Rewards use the "magnified dividend per share" pattern of PadToken, once per reward asset, with one share per
///      NFT. Rewards are counted when someone calls `sync` (claims, mints and transfers do it first), so the NFTs
///      minted at that moment share them: an NFT minted later earns only from what arrives after its mint.
contract PepesFamilyNFT is ERC721 {
    using SafeTransfer for address;

    error NotOwner();
    error ZeroAddress();
    error MintClosed();
    error SoldOut();
    error WrongPayment();
    error BadQuantity();
    error TooManyAssets();
    error KnownAsset();
    error Frozen();
    error RoyaltyTooHigh();
    error Overflow();
    error Reentrancy();
    error EthNotAccepted();
    error TransferFailed();
    error NoArt();

    event Minted(address indexed to, uint256 firstId, uint256 quantity, uint256 paid);
    event RewardsDistributed(address indexed asset, uint256 amount, uint256 nfts);
    event RewardClaimed(address indexed holder, address indexed asset, uint256 amount);
    event RewardAssetAdded(address indexed asset);
    event MintConfigUpdated(uint256 price, bool open, uint256 maxPerTx);
    event ProceedsWithdrawn(address indexed to, uint256 amount);
    event ArtUpdated(address art);
    event MetadataFrozen();
    event RoyaltyUpdated(address receiver, uint96 bps);
    event TransferValidatorUpdated(address oldValidator, address newValidator);
    event ContractURIUpdated(string contractURI);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    uint256 public constant MAX_SUPPLY = 2000;
    uint256 public constant MAX_REWARD_ASSETS = 8;
    uint256 public constant MAX_ROYALTY_BPS = 1000;
    uint256 internal constant MAGNITUDE = 2 ** 128;

    /// @notice Wrapped ETH: rewards in it are paid out as ETH.
    address public immutable weth;

    address public owner;
    address public pendingOwner;
    /// @notice ERC-721C transfer validator (0: no transfer restrictions).
    address public transferValidator;
    /// @notice Collection metadata for marketplaces (name, image, description), see `contractURI`.
    string internal _contractURI;
    /// @notice Mint ETH not yet withdrawn (kept apart from ETH passing through while WETH rewards are unwrapped).
    uint256 public proceeds;

    /// @notice Mint price per NFT, in ETH (wei).
    uint256 public price;
    bool public mintOpen;
    /// @notice Most NFTs one mint transaction can take.
    uint256 public maxPerTx;
    /// @notice NFTs minted so far; ids are 1..totalSupply.
    uint256 public totalSupply;

    /// @notice The on-chain art (PepesFamilyArt); the owner can replace it until `freezeMetadata`.
    address public art;
    bool public metadataFrozen;
    address public royaltyReceiver;
    uint96 public royaltyBps;

    /// @notice Assets rewards are paid in (the launchpads' pair assets: IMD, wrapped ETH, ...). Added by the owner,
    ///         never removed, so accounting stays consistent.
    address[] public rewardAssets;
    mapping(address asset => bool) public isRewardAsset;

    mapping(address asset => uint256) public magnifiedRewardPerNft;
    mapping(address asset => mapping(address holder => int256)) internal magnifiedCorrections;
    mapping(address asset => mapping(address holder => uint256)) public withdrawnRewards;
    /// @notice Asset held here that is already counted as rewards (distributed, not yet claimed).
    mapping(address asset => uint256) public accountedBalance;
    mapping(address asset => uint256) public totalRewardsDistributed;

    uint256 private _locked = 1;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        address weth_,
        address owner_,
        address royaltyReceiver_,
        uint96 royaltyBps_,
        uint256 price_,
        address art_
    ) ERC721("PEPES FAMILY", "PEPES") {
        if (weth_ == address(0) || owner_ == address(0) || royaltyReceiver_ == address(0)) revert ZeroAddress();
        art = art_;
        weth = weth_;
        if (royaltyBps_ > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        owner = owner_;
        royaltyReceiver = royaltyReceiver_;
        royaltyBps = royaltyBps_;
        price = price_;
        maxPerTx = 10;
        emit OwnershipTransferred(address(0), owner_);
        emit RoyaltyUpdated(royaltyReceiver_, royaltyBps_);
        emit MintConfigUpdated(price_, false, 10);
        emit ArtUpdated(art_);
    }

    /// @dev Only WETH sends ETH here, while a reward claim unwraps it.
    receive() external payable {
        if (msg.sender != weth) revert EthNotAccepted();
    }

    // ---------------------------------------------------------------- Mint

    /// @notice Mints `quantity` NFTs to the caller for `quantity * price` ETH.
    function mint(uint256 quantity) external payable nonReentrant {
        if (!mintOpen) revert MintClosed();
        if (quantity == 0 || quantity > maxPerTx) revert BadQuantity();
        if (msg.value != quantity * price) revert WrongPayment();
        proceeds += msg.value;
        _mintMany(msg.sender, quantity, msg.value);
    }

    /// @notice Owner mints for giveaways and the team, from the same 2,000.
    function ownerMint(address to, uint256 quantity) external onlyOwner nonReentrant {
        if (quantity == 0) revert BadQuantity();
        _mintMany(to, quantity, 0);
    }

    function _mintMany(address to, uint256 quantity, uint256 paid) internal {
        uint256 first = totalSupply + 1;
        if (totalSupply + quantity > MAX_SUPPLY) revert SoldOut();
        // Everything that arrived before this mint belongs to the NFTs that already exist.
        _syncAll();
        totalSupply += quantity;
        for (uint256 i; i < quantity; ++i) {
            _mint(to, first + i);
        }
        _adjust(address(0), to, quantity);
        emit Minted(to, first, quantity, paid);
    }

    // ------------------------------------------------------------- Transfers

    /// @dev solmate's safeTransferFrom variants call this, so every transfer moves the reward accounting. Rewards
    ///      that arrived before the transfer are counted first, so they stay with the seller.
    function transferFrom(address from, address to, uint256 id) public override {
        address validator = transferValidator;
        if (validator != address(0)) ITransferValidator(validator).validateTransfer(msg.sender, from, to, id);
        _syncAll();
        super.transferFrom(from, to, id);
        _adjust(from, to, 1);
    }

    /// @dev Keeps earned rewards with `from` and starts `to` at zero for the moved NFTs (address(0) = mint).
    function _adjust(address from, address to, uint256 count) internal {
        uint256 n = rewardAssets.length;
        for (uint256 i; i < n; ++i) {
            address asset = rewardAssets[i];
            int256 c = _toInt(magnifiedRewardPerNft[asset] * count);
            if (from != address(0)) magnifiedCorrections[asset][from] += c;
            magnifiedCorrections[asset][to] -= c;
        }
    }

    // ---------------------------------------------------------------- Rewards

    /// @notice Shares everything that arrived in `asset` since the last sync among the minted NFTs.
    function sync(address asset) public returns (uint256 amount) {
        if (!isRewardAsset[asset]) return 0;
        uint256 supply = totalSupply;
        uint256 bal = asset.balanceOf(address(this));
        uint256 accounted = accountedBalance[asset];
        // Never revert: mints and claims call this. With no NFT minted yet the funds wait for the first mint.
        if (bal <= accounted || supply == 0) return 0;
        amount = bal - accounted;
        magnifiedRewardPerNft[asset] += (amount * MAGNITUDE) / supply;
        accountedBalance[asset] = bal;
        totalRewardsDistributed[asset] += amount;
        emit RewardsDistributed(asset, amount, supply);
    }

    function _syncAll() internal {
        uint256 n = rewardAssets.length;
        for (uint256 i; i < n; ++i) {
            sync(rewardAssets[i]);
        }
    }

    function accumulativeRewardOf(address asset, address holder) public view returns (uint256) {
        int256 mag = _toInt(magnifiedRewardPerNft[asset] * balanceOf(holder)) + magnifiedCorrections[asset][holder];
        return mag <= 0 ? 0 : uint256(mag) / MAGNITUDE;
    }

    /// @notice Claimable now (rewards not yet synced are not included; `pendingRewardOf` includes them).
    function withdrawableRewardOf(address asset, address holder) public view returns (uint256) {
        uint256 acc = accumulativeRewardOf(asset, holder);
        uint256 done = withdrawnRewards[asset][holder];
        return acc > done ? acc - done : 0;
    }

    /// @notice What `holder` would receive by claiming `asset` now, including rewards waiting to be synced.
    function pendingRewardOf(address asset, address holder) external view returns (uint256) {
        uint256 w = withdrawableRewardOf(asset, holder);
        uint256 supply = totalSupply;
        uint256 bal = isRewardAsset[asset] ? asset.balanceOf(address(this)) : 0;
        uint256 accounted = accountedBalance[asset];
        if (bal <= accounted || supply == 0) return w;
        return w + ((((bal - accounted) * MAGNITUDE) / supply) * balanceOf(holder)) / MAGNITUDE;
    }

    /// @notice Pays the caller everything it has earned, in every reward asset.
    function claim() external nonReentrant {
        uint256 n = rewardAssets.length;
        for (uint256 i; i < n; ++i) {
            _claim(rewardAssets[i]);
        }
    }

    /// @notice Pays the caller what it has earned in one asset.
    function claim(address asset) external nonReentrant returns (uint256) {
        return _claim(asset);
    }

    function _claim(address asset) internal returns (uint256 amount) {
        sync(asset);
        amount = withdrawableRewardOf(asset, msg.sender);
        if (amount == 0) return 0;
        withdrawnRewards[asset][msg.sender] += amount;
        accountedBalance[asset] -= amount;
        emit RewardClaimed(msg.sender, asset, amount);
        if (asset == weth) NativePayout.pay(weth, msg.sender, amount);
        else asset.transferOut(msg.sender, amount);
    }

    function rewardAssetCount() external view returns (uint256) {
        return rewardAssets.length;
    }

    // ---------------------------------------------------------------- Admin

    /// @notice Adds an asset rewards can be paid in. A balance it already has here is shared at the next sync.
    function addRewardAsset(address asset) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (isRewardAsset[asset]) revert KnownAsset();
        if (rewardAssets.length >= MAX_REWARD_ASSETS) revert TooManyAssets();
        isRewardAsset[asset] = true;
        rewardAssets.push(asset);
        emit RewardAssetAdded(asset);
    }

    function setMintConfig(uint256 price_, bool open_, uint256 maxPerTx_) external onlyOwner {
        if (maxPerTx_ == 0) revert BadQuantity();
        price = price_;
        mintOpen = open_;
        maxPerTx = maxPerTx_;
        emit MintConfigUpdated(price_, open_, maxPerTx_);
    }

    /// @notice Sends the mint proceeds to `to`.
    function withdrawProceeds(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = proceeds;
        proceeds = 0;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit ProceedsWithdrawn(to, amount);
    }

    /// @notice ERC-721C: sets the transfer validator (address(0) removes all transfer restrictions).
    function setTransferValidator(address validator) external onlyOwner {
        emit TransferValidatorUpdated(transferValidator, validator);
        transferValidator = validator;
    }

    function setContractURI(string calldata contractURI_) external onlyOwner {
        _contractURI = contractURI_;
        emit ContractURIUpdated(contractURI_);
    }

    function setArt(address art_) external onlyOwner {
        if (metadataFrozen) revert Frozen();
        art = art_;
        emit ArtUpdated(art_);
    }

    /// @notice Locks the art forever.
    function freezeMetadata() external onlyOwner {
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        if (receiver == address(0)) revert ZeroAddress();
        if (bps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        royaltyReceiver = receiver;
        royaltyBps = bps;
        emit RoyaltyUpdated(receiver, bps);
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

    // ---------------------------------------------------------------- Views

    /// @notice ERC-721C: the validator and the function it exposes for transfers.
    function getTransferValidator() external view returns (address) {
        return transferValidator;
    }

    function getTransferValidationFunction() external pure returns (bytes4 functionSignature, bool isViewFunction) {
        return (ITransferValidator.validateTransfer.selector, true);
    }

    /// @notice Collection-level metadata for marketplaces (OpenSea's contractURI).
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        ownerOf(id); // reverts NOT_MINTED
        if (art == address(0)) revert NoArt();
        return IPepesFamilyArt(art).tokenURI(id, id - 1);
    }

    /// @notice ERC-2981 royalty for marketplaces.
    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (royaltyReceiver, (salePrice * royaltyBps) / 10_000);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        // ERC-2981 royalties, ERC-721C creator token (ICreatorToken)
        return interfaceId == 0x2a55205a || interfaceId == 0xad0d7f6c || super.supportsInterface(interfaceId);
    }

    function _toInt(uint256 x) private pure returns (int256) {
        if (x > uint256(type(int256).max)) revert Overflow();
        return int256(x);
    }
}
