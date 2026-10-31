// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LibEarnString as S} from "../earn/LibEarnString.sol";
import {PepesFamilyArtData as D} from "./PepesFamilyArtData.sol";

/// @title PepesFamilyArt: the PEPES FAMILY pictures, fully on-chain.
/// @notice Holds the collection's art as layers cut from the original drawing, all in the same 856 x 1200 frame: the
///         swirl background (one picture, recoloured per background by an SVG colour table), a body per skin, and the
///         shirts, pants, chain hats and accessories (transparent PNGs). A picture is an SVG stacking a token's
///         background, body, shirt, pants, hat and accessory, with the art's grain added back by an SVG filter.
///         The data lives in the code of small data contracts (SSTORE2), as the Messenger art does.
///
///         Each layer is stored ready to drop into a tokenURI: its SVG `<image>` element, padded with spaces to a
///         multiple of 9 bytes, then base64-encoded twice (once for the SVG data URI, once for the JSON data URI).
///         Base64 of joined pieces equals the joined pieces' base64 when each piece's length is a multiple of 3, so
///         a picture is put together without encoding anything large on-chain.
///
///         The 2,000 trait combinations are stored too (7 bytes each: background, skin, shirt, pants, hat, accessory
///         (0 = none), rarity), so the on-chain collection is exactly the one generated and previewed.
///
///         The uploader stores everything, then seals. Sealing needs every layer present, and after it nothing can
///         change: there is no owner.
contract PepesFamilyArt {
    uint8 public constant SWIRL = 0; // index 0
    uint8 public constant BODY = 1; // index = skin
    uint8 public constant SHIRT = 2;
    uint8 public constant PANTS = 3;
    uint8 public constant HAT = 4;
    uint8 public constant ACC = 5; // index = accessory - 1
    uint8 public constant TRAITS = 6; // index 0: the raw trait table
    uint256 public constant SUPPLY = 2000;
    uint256 public constant TRAIT_BYTES = 7;
    /// @notice The most bytes one data contract holds (the code size limit minus the leading STOP byte).
    uint256 public constant MAX_CHUNK = 24_575;

    string public constant SVG_HEAD =
        "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' viewBox='0 0 856 1200' width='856' height='1200'><defs><filter id='g' x='0' y='0' width='100%' height='100%'><feTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='3' seed='7' stitchTiles='stitch'/><feColorMatrix values='0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 -4 1.7'/><feComposite in2='SourceGraphic' operator='in' result='d'/><feMerge><feMergeNode in='SourceGraphic'/><feMergeNode in='d'/></feMerge></filter></defs><g filter='url(#g)'>";
    string public constant SVG_TAIL = "</g></svg>";

    address public immutable uploader;
    bool public isSealed;
    mapping(uint256 key => address[] chunks) private _chunks;

    event LayerUploaded(uint8 indexed kind, uint8 indexed index, uint256 size);
    event LayerCleared(uint8 indexed kind, uint8 indexed index);
    event Sealed();

    error NotUploader();
    error IsSealed();
    error NotSealed();
    error BadLayer();
    error BadChunk();
    error WriteFailed();
    error MissingLayer(uint8 kind, uint8 index);
    error BadEncoding(uint8 kind, uint8 index);
    error BadTraits();
    error ZeroAddress();

    constructor(address uploader_) {
        if (uploader_ == address(0)) revert ZeroAddress();
        uploader = uploader_;
    }

    modifier onlyUploaderBeforeSeal() {
        if (msg.sender != uploader) revert NotUploader();
        if (isSealed) revert IsSealed();
        _;
    }

    // ---------------------------------------------------------------- upload (before the seal)

    /// @notice Appends bytes to a layer, one data contract per part (each at most `MAX_CHUNK`).
    function upload(uint8 kind, uint8 index, bytes[] calldata parts) external onlyUploaderBeforeSeal {
        if (!isLayer(kind, index)) revert BadLayer();
        address[] storage chunks = _chunks[_key(kind, index)];
        uint256 size;
        for (uint256 i; i < parts.length; ++i) {
            if (parts[i].length == 0 || parts[i].length > MAX_CHUNK) revert BadChunk();
            chunks.push(_write(parts[i]));
            size += parts[i].length;
        }
        emit LayerUploaded(kind, index, size);
    }

    /// @notice Drops a layer's data (to re-upload it after a mistake).
    function clear(uint8 kind, uint8 index) external onlyUploaderBeforeSeal {
        if (!isLayer(kind, index)) revert BadLayer();
        delete _chunks[_key(kind, index)];
        emit LayerCleared(kind, index);
    }

    /// @notice Freezes the art. Every layer must be present, each encoded piece a multiple of 16 characters (a
    ///         multiple of 9 bytes before encoding), and the trait table complete and in range.
    function seal() external onlyUploaderBeforeSeal {
        for (uint8 kind; kind <= ACC; ++kind) {
            uint8 last = _last(kind);
            for (uint8 i; i <= last; ++i) {
                uint256 size = _size(_key(kind, i));
                if (size == 0) revert MissingLayer(kind, i);
                if (size % 16 != 0) revert BadEncoding(kind, i);
            }
        }
        bytes memory t = layer(TRAITS, 0);
        if (t.length != SUPPLY * TRAIT_BYTES) revert BadTraits();
        for (uint256 i; i < t.length; i += TRAIT_BYTES) {
            if (
                uint8(t[i]) >= D.BACKGROUNDS || uint8(t[i + 1]) >= D.SKINS || uint8(t[i + 2]) >= D.SHIRTS
                    || uint8(t[i + 3]) >= D.PANTS || uint8(t[i + 4]) >= D.HATS || uint8(t[i + 5]) > D.ACCESSORIES
                    || uint8(t[i + 6]) > 3
            ) revert BadTraits();
        }
        isSealed = true;
        emit Sealed();
    }

    // ---------------------------------------------------------------- views

    function isLayer(uint8 kind, uint8 index) public pure returns (bool) {
        return kind <= TRAITS && index <= _last(kind);
    }

    /// @notice A layer as stored.
    function layer(uint8 kind, uint8 index) public view returns (bytes memory out) {
        if (!isLayer(kind, index)) revert BadLayer();
        address[] storage chunks = _chunks[_key(kind, index)];
        out = new bytes(_size(_key(kind, index)));
        uint256 at;
        for (uint256 i; i < chunks.length; ++i) {
            address p = chunks[i];
            uint256 size = p.code.length - 1;
            assembly ("memory-safe") {
                extcodecopy(p, add(add(out, 0x20), at), 1, size)
            }
            at += size;
        }
    }

    function layerSize(uint8 kind, uint8 index) external view returns (uint256) {
        return _size(_key(kind, index));
    }

    /// @notice The traits of entry `n` (0..1999) of the collection: background, skin, shirt, pants, hat,
    ///         accessory (0 = none, else 1 + index), rarity (0 Common .. 3 Legendary).
    function traits(uint256 n) public view returns (uint8[7] memory t) {
        if (n >= SUPPLY) revert BadTraits();
        address[] storage chunks = _chunks[_key(TRAITS, 0)];
        uint256 off = n * TRAIT_BYTES;
        // the table may span data contracts: find the one holding this entry
        for (uint256 c; c < chunks.length; ++c) {
            uint256 size = chunks[c].code.length - 1;
            if (off + TRAIT_BYTES <= size) {
                bytes memory b = new bytes(TRAIT_BYTES);
                address p = chunks[c];
                assembly ("memory-safe") {
                    extcodecopy(p, add(b, 0x20), add(off, 1), 7)
                }
                for (uint256 i; i < TRAIT_BYTES; ++i) t[i] = uint8(b[i]);
                return t;
            }
            if (off < size) break; // an entry split across chunks: the uploader never does this
            off -= size;
        }
        revert BadTraits();
    }

    /// @notice The picture of entry `n` as an SVG data URI, base64-encoded once more: exactly what follows the JSON
    ///         text before it in a base64 tokenURI.
    function encodedPicture(uint256 n) public view returns (bytes memory out) {
        if (!isSealed) revert NotSealed();
        uint8[7] memory t = traits(n);
        // one concatenation, so every layer is copied once
        out = bytes.concat(
            _twice(SVG_HEAD),
            _twice(D.background(t[0])),
            D.isSwirl(t[0]) ? layer(SWIRL, 0) : bytes(""),
            layer(BODY, t[1]),
            layer(SHIRT, t[2]),
            layer(PANTS, t[3]),
            layer(HAT, t[4]),
            t[5] != 0 ? layer(ACC, t[5] - 1) : bytes(""),
            _twice(SVG_TAIL)
        );
    }

    /// @notice The picture of entry `n` as plain SVG (decoded; for checking, heavy).
    function picture(uint256 n) external view returns (string memory) {
        return string(_decode(_decode(encodedPicture(n))));
    }

    /// @notice The attributes of entry `n` as a JSON array.
    function attributes(uint256 n) public view returns (string memory) {
        uint8[7] memory t = traits(n);
        return string.concat(
            '[{"trait_type":"Hat","value":"', D.hatName(t[4]),
            '"},{"trait_type":"Background","value":"', D.bgName(t[0]),
            '"},{"trait_type":"Skin","value":"', D.skinName(t[1]),
            '"},{"trait_type":"Shirt","value":"', D.shirtName(t[2]),
            '"},{"trait_type":"Pants","value":"', D.pantsName(t[3]),
            '"},{"trait_type":"Accessory","value":"', D.accName(t[5]),
            '"},{"trait_type":"Rarity","value":"', D.rarityName(t[6]), '"}]'
        );
    }

    /// @notice Full metadata of token `id` showing entry `n`, as a base64 JSON data URI.
    function tokenURI(uint256 id, uint256 n) external view returns (string memory) {
        bytes memory head = bytes(
            string.concat(
                '{"name":"PEPES FAMILY #', S.toString(id),
                '","description":"One of 2,000 PEPES FAMILY, drawn fully on-chain. Every token launched on PepesFamily v6 pays 1% of each trade to the holders of this collection, in ETH. https://pepesdotfamily.fun","attributes":',
                attributes(n), ","
            )
        );
        bytes memory key = '"image":"data:image/svg+xml;base64,';
        // JSON whitespace before "image" makes head + key a multiple of 3, so the picture's base64 joins on.
        uint256 extra = (3 - (head.length + key.length) % 3) % 3;
        head = bytes.concat(head, extra == 0 ? bytes("") : extra == 1 ? bytes(" ") : bytes("  "), key);
        return string(
            bytes.concat("data:application/json;base64,", bytes(S.base64(head)), encodedPicture(n), bytes(S.base64('"}')))
        );
    }

    /// @notice How an image element is stored as a layer: padded to a multiple of 9 bytes, base64 twice. Anyone can
    ///         check a stored layer against the original picture with this.
    function pieceFor(bytes memory element) external pure returns (bytes memory) {
        return _twice(string(element));
    }

    // ---------------------------------------------------------------- internals

    function _twice(string memory s) private pure returns (bytes memory) {
        bytes memory b = bytes(s);
        uint256 extra = (9 - b.length % 9) % 9;
        bytes memory spaces = new bytes(extra);
        for (uint256 i; i < extra; ++i) spaces[i] = " ";
        return bytes(S.base64(bytes(S.base64(bytes.concat(b, spaces)))));
    }

    function _last(uint8 kind) private pure returns (uint8) {
        if (kind == SWIRL || kind == TRAITS) return 0;
        if (kind == BODY) return uint8(D.SKINS - 1);
        if (kind == SHIRT) return uint8(D.SHIRTS - 1);
        if (kind == PANTS) return uint8(D.PANTS - 1);
        if (kind == HAT) return uint8(D.HATS - 1);
        if (kind == ACC) return uint8(D.ACCESSORIES - 1);
        return 0;
    }

    function _key(uint8 kind, uint8 index) private pure returns (uint256) {
        return uint256(kind) << 8 | index;
    }

    function _size(uint256 key) private view returns (uint256 size) {
        address[] storage chunks = _chunks[key];
        for (uint256 i; i < chunks.length; ++i) size += chunks[i].code.length - 1;
    }

    /// @dev Deploys `data` as the code of a new contract, behind a STOP byte so it can never be called.
    function _write(bytes calldata data) private returns (address pointer) {
        bytes memory code = bytes.concat(hex"00", data);
        // PUSH2 len, DUP1, PUSH1 10, RETURNDATASIZE, CODECOPY, RETURNDATASIZE, RETURN: returns the code after the
        // 10-byte prefix.
        bytes memory init = bytes.concat(hex"61", bytes2(uint16(code.length)), hex"80600a3d393df3", code);
        assembly ("memory-safe") {
            pointer := create(0, add(init, 0x20), mload(init))
        }
        if (pointer == address(0)) revert WriteFailed();
    }

    function _read(address pointer) private view returns (bytes memory data) {
        uint256 size = pointer.code.length - 1;
        data = new bytes(size);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 0x20), 1, size)
        }
    }

    /// @dev Base64 decoder (standard alphabet, padded input), only for `picture`.
    function _decode(bytes memory s) private pure returns (bytes memory out) {
        uint256 n = s.length;
        if (n == 0) return out;
        uint256 padding = s[n - 1] == "=" ? (s[n - 2] == "=" ? 2 : 1) : 0;
        out = new bytes((n / 4) * 3 - padding);
        uint256 o;
        for (uint256 i; i < n; i += 4) {
            uint256 v = (_v(s[i]) << 18) | (_v(s[i + 1]) << 12) | (_v(s[i + 2]) << 6) | _v(s[i + 3]);
            if (o < out.length) out[o++] = bytes1(uint8(v >> 16));
            if (o < out.length) out[o++] = bytes1(uint8(v >> 8));
            if (o < out.length) out[o++] = bytes1(uint8(v));
        }
    }

    function _v(bytes1 c) private pure returns (uint256) {
        uint8 x = uint8(c);
        if (x >= 65 && x <= 90) return x - 65;
        if (x >= 97 && x <= 122) return x - 71;
        if (x >= 48 && x <= 57) return x + 4;
        if (x == 43) return 62;
        if (x == 47) return 63;
        return 0; // "="
    }
}
