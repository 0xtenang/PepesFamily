// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PepesFamilyArt} from "../src/nft/PepesFamilyArt.sol";

/// @notice Uploads the real PEPES FAMILY art (art/pieces, made by pepes-nft/pieces.py) and checks the contract builds
///         exactly the pictures the generator built.
contract PepesFamilyArtTest is Test {
    PepesFamilyArt art;
    address uploader = makeAddr("uploader");
    string constant DIR = "art/pieces/";
    string[6] KINDS = ["swirl", "body", "shirt", "pants", "hat", "acc"];
    uint8[6] COUNTS = [1, 6, 12, 8, 6, 10];

    function setUp() public {
        art = new PepesFamilyArt(uploader);
    }

    function _upload(uint8 kind, uint8 index, bytes memory data) internal {
        uint256 max = art.MAX_CHUNK();
        uint256 n = (data.length + max - 1) / max;
        bytes[] memory parts = new bytes[](n);
        for (uint256 i; i < n; ++i) {
            uint256 end = (i + 1) * max < data.length ? (i + 1) * max : data.length;
            uint256 len = end - i * max;
            bytes memory p = new bytes(len);
            uint256 from = i * max;
            assembly ("memory-safe") {
                mcopy(add(p, 0x20), add(add(data, 0x20), from), len)
            }
            parts[i] = p;
        }
        vm.prank(uploader);
        art.upload(kind, index, parts);
    }

    function _uploadAll() internal {
        for (uint8 k; k < 6; ++k) {
            for (uint8 i; i < COUNTS[k]; ++i) {
                _upload(k, i, vm.readFileBinary(string.concat(DIR, KINDS[k], "-", vm.toString(i), ".b64")));
            }
        }
        _upload(art.TRAITS(), 0, vm.readFileBinary(string.concat(DIR, "traits.bin")));
    }

    function test_uploadSealAndPicturesMatchTheGenerator() public {
        _uploadAll();
        vm.expectRevert(PepesFamilyArt.NotSealed.selector);
        art.encodedPicture(0);
        vm.prank(uploader);
        art.seal();
        uint16[7] memory ns = [uint16(1), 27, 44, 72, 118, 160, 2000];
        for (uint256 i; i < ns.length; ++i) {
            string memory want = vm.readFile(string.concat(DIR, "expected-", vm.toString(ns[i]), ".svg"));
            assertEq(art.picture(ns[i] - 1), want, "picture");
        }
        // traits as generated: entry 27 is a Gold skin, Gold shirt, Shades + Chain Legendary
        uint8[7] memory t = art.traits(26);
        assertEq(t[1], 5, "Gold skin");
        assertEq(t[6], 3, "Legendary");
        string memory attrs = art.attributes(26);
        assertEq(
            attrs,
            '[{"trait_type":"Hat","value":"Elysium"},{"trait_type":"Background","value":"Sky"},{"trait_type":"Skin","value":"Gold"},{"trait_type":"Shirt","value":"Gold"},{"trait_type":"Pants","value":"Red"},{"trait_type":"Accessory","value":"Shades + Chain"},{"trait_type":"Rarity","value":"Legendary"}]'
        );
    }

    function test_tokenURIIsValidBase64JsonAndFitsAnEthCall() public {
        _uploadAll();
        vm.prank(uploader);
        art.seal();
        uint256 g = gasleft();
        string memory uri = art.tokenURI(7, 117);
        uint256 used = g - gasleft();
        emit log_named_uint("tokenURI gas (largest preview entry)", used);
        emit log_named_uint("tokenURI bytes", bytes(uri).length);
        assertLt(used, 50_000_000, "fits public RPC eth_call limits");
        bytes memory u = bytes(uri);
        bytes memory prefix = "data:application/json;base64,";
        bytes memory b64 = new bytes(u.length - prefix.length);
        for (uint256 i; i < b64.length; ++i) b64[i] = u[prefix.length + i];
        string memory json = string(vm.parseBytes(string.concat("0x", _hexOf(_decode(b64)))));
        assertEq(vm.parseJsonString(json, ".name"), "PEPES FAMILY #7");
        string memory image = vm.parseJsonString(json, ".image");
        assertTrue(_startsWith(bytes(image), "data:image/svg+xml;base64,PHN2Zy"), "svg data uri");
        assertEq(vm.parseJsonString(json, ".attributes[6].value"), "Legendary");
    }

    function test_onlyUploaderAndSealRules() public {
        bytes[] memory parts = new bytes[](1);
        parts[0] = "abcdefghijklmnop";
        vm.expectRevert(PepesFamilyArt.NotUploader.selector);
        art.upload(0, 0, parts);
        vm.startPrank(uploader);
        vm.expectRevert(PepesFamilyArt.BadLayer.selector);
        art.upload(1, 6, parts); // 6 skins: 0..5
        vm.expectRevert(abi.encodeWithSelector(PepesFamilyArt.MissingLayer.selector, 0, 0));
        art.seal();
        vm.stopPrank();
        _uploadAll();
        vm.startPrank(uploader);
        art.clear(5, 9);
        parts[0] = "abcdefghij"; // not a multiple of 16
        art.upload(5, 9, parts);
        vm.expectRevert(abi.encodeWithSelector(PepesFamilyArt.BadEncoding.selector, 5, 9));
        art.seal();
        art.clear(5, 9);
        vm.stopPrank();
        _upload(5, 9, vm.readFileBinary(string.concat(DIR, "acc-9.b64")));
        vm.startPrank(uploader);
        art.seal();
        vm.expectRevert(PepesFamilyArt.IsSealed.selector);
        art.upload(0, 0, parts);
        vm.expectRevert(PepesFamilyArt.IsSealed.selector);
        art.clear(0, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ helpers

    function _startsWith(bytes memory a, bytes memory p) internal pure returns (bool) {
        if (a.length < p.length) return false;
        for (uint256 i; i < p.length; ++i) if (a[i] != p[i]) return false;
        return true;
    }

    function _hexOf(bytes memory b) internal pure returns (string memory) {
        bytes memory h = "0123456789abcdef";
        bytes memory o = new bytes(b.length * 2);
        for (uint256 i; i < b.length; ++i) {
            o[2 * i] = h[uint8(b[i]) >> 4];
            o[2 * i + 1] = h[uint8(b[i]) & 15];
        }
        return string(o);
    }

    function _decode(bytes memory s) internal pure returns (bytes memory out) {
        uint256 n = s.length;
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

    function _v(bytes1 c) internal pure returns (uint256) {
        uint8 x = uint8(c);
        if (x >= 65 && x <= 90) return x - 65;
        if (x >= 97 && x <= 122) return x - 71;
        if (x >= 48 && x <= 57) return x + 4;
        if (x == 43) return 62;
        if (x == 47) return 63;
        return 0;
    }
}
