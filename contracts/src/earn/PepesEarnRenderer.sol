// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LibEarnString as S} from "./LibEarnString.sol";

/// @title PepesEarnRenderer
/// @notice Draws every Pepes Earn IMD NFT on-chain: a back-facing Pepe in front of a wall of instrument panels.
///         Traits come from keccak256 of the NFT number, so an NFT always looks the same and nothing is stored
///         off-chain. #1 is "The King" and #777 is "Gold Pepe".
contract PepesEarnRenderer {
    uint256 internal constant SKIN_GOLD = 5;
    uint256 internal constant HEAD_CROWN = 6;
    uint256 internal constant ACC_CAPE = 4;
    uint256 internal constant BACK_GOLD_VAULT = 4;

    struct Traits {
        uint256 skin;
        uint256 shirt;
        uint256 shorts;
        uint256 back;
        uint256 head;
        uint256 acc;
        uint256 seed;
        string special;
    }

    // ------------------------------------------------------------ public

    function tokenURI(uint256 id) external pure returns (string memory) {
        Traits memory t = traits(id);
        string memory svg = image(id);
        string memory json = string.concat(
            '{"name":"Pepes Earn IMD #',
            S.toString(id),
            '","description":"Pepes Earn IMD: 2,000 on-chain Pepes. Every $EARN pool trade pays 3% to holders in IMD. Claim on pepesfamily.fun.","image":"data:image/svg+xml;base64,',
            S.base64(bytes(svg)),
            '","attributes":',
            _attributes(t),
            "}"
        );
        return string.concat("data:application/json;base64,", S.base64(bytes(json)));
    }

    function image(uint256 id) public pure returns (string memory) {
        Traits memory t = traits(id);
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 300" shape-rendering="geometricPrecision">',
            _wall(t),
            '<svg x="75" y="22" width="150" height="234" viewBox="0 -30 100 156">',
            _frog(t),
            "</svg></svg>"
        );
    }

    function traits(uint256 id) public pure returns (Traits memory t) {
        uint256 r = uint256(keccak256(abi.encodePacked("pepes-earn-imd", id)));
        t.skin = _pick(_roll(r, 0), _w6(80, 7, 5, 4, 3, 1));
        t.shirt = _roll(r, 1) * 8 / 65536;
        t.shorts = _roll(r, 2) * 5 / 65536;
        t.back = _roll(r, 3) * 6 / 65536;
        t.head = _pick(_roll(r, 4), _w7(30, 20, 15, 15, 8, 7, 5));
        t.acc = _pick(_roll(r, 5), _w5(40, 25, 15, 12, 8));
        t.seed = (r >> 128) & 0x7fffffff;
        if (id == 1) {
            (t.skin, t.head, t.acc, t.back, t.special) = (SKIN_GOLD, HEAD_CROWN, ACC_CAPE, BACK_GOLD_VAULT, "The King");
        } else if (id == 777) {
            (t.skin, t.special) = (SKIN_GOLD, "Gold Pepe");
        }
    }

    // ------------------------------------------------------------ traits

    function _roll(uint256 r, uint256 i) private pure returns (uint256) {
        return (r >> (i * 16)) & 0xffff;
    }

    function _pick(uint256 roll, uint256[] memory w) private pure returns (uint256) {
        uint256 total;
        for (uint256 i; i < w.length; i++) total += w[i];
        uint256 x = roll * total / 65536;
        for (uint256 i; i < w.length; i++) {
            if (x < w[i]) return i;
            x -= w[i];
        }
        return w.length - 1;
    }

    function _w5(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) private pure returns (uint256[] memory w) {
        w = new uint256[](5);
        (w[0], w[1], w[2], w[3], w[4]) = (a, b, c, d, e);
    }

    function _w6(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f)
        private
        pure
        returns (uint256[] memory w)
    {
        w = new uint256[](6);
        (w[0], w[1], w[2], w[3], w[4], w[5]) = (a, b, c, d, e, f);
    }

    function _w7(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f, uint256 g)
        private
        pure
        returns (uint256[] memory w)
    {
        w = new uint256[](7);
        (w[0], w[1], w[2], w[3], w[4], w[5], w[6]) = (a, b, c, d, e, f, g);
    }

    function _skinName(uint256 i) private pure returns (string memory) {
        return ["Classic Green", "Zombie", "Ice", "Bubblegum", "Shadow", "Gold"][i];
    }

    function _shirtName(uint256 i) private pure returns (string memory) {
        return ["Blue Tee", "Red Tee", "Black Tee", "White Tee", "Green Tee", "Purple Tee", "Orange Tee", "Grey Hoodie"][i];
    }

    function _shortsName(uint256 i) private pure returns (string memory) {
        return ["Tan", "Grey", "Denim", "Black", "Red"][i];
    }

    function _backName(uint256 i) private pure returns (string memory) {
        return ["Control Room", "Night Shift", "Sunset", "Deep Sea", "Gold Vault", "Matrix"][i];
    }

    function _headName(uint256 i) private pure returns (string memory) {
        return ["None", "Cap", "Beanie", "Headphones", "Party Hat", "Halo", "Crown"][i];
    }

    function _accName(uint256 i) private pure returns (string memory) {
        return ["None", "Backpack", "IMD Bag", "Skateboard", "Cape"][i];
    }

    function _attributes(Traits memory t) private pure returns (string memory a) {
        a = string.concat(
            '[{"trait_type":"Skin","value":"',
            _skinName(t.skin),
            '"},{"trait_type":"Shirt","value":"',
            t.acc == ACC_CAPE ? "Cape" : _shirtName(t.shirt),
            '"},{"trait_type":"Shorts","value":"',
            _shortsName(t.shorts),
            '"},{"trait_type":"Headwear","value":"',
            _headName(t.head),
            '"},{"trait_type":"Accessory","value":"',
            _accName(t.acc),
            '"},{"trait_type":"Background","value":"',
            _backName(t.back),
            '"}'
        );
        if (bytes(t.special).length != 0) a = string.concat(a, ',{"trait_type":"Special","value":"', t.special, '"}');
        a = string.concat(a, "]");
    }

    // ------------------------------------------------------------ palettes

    /// @dev wall, panel, ink, lit, floor
    function _back(uint256 i) private pure returns (string[5] memory) {
        if (i == 0) return ["#b9b9b6", "#dcdcd9", "#1b1b1b", "#1b1b1b", "#f2f2ef"];
        if (i == 1) return ["#030403", "#0d0f0d", "#8e998e", "#3ddc84", "#121412"];
        if (i == 2) return ["#2b1636", "#4a2245", "#ff9e5e", "#ffcf6e", "#1e0f26"];
        if (i == 3) return ["#06202b", "#0b3442", "#5fd4e8", "#9ff0ff", "#04161e"];
        if (i == 4) return ["#2a2208", "#3d320d", "#ffd34d", "#fff2b0", "#1a1505"];
        return ["#001a00", "#002b00", "#39ff14", "#b6ff9e", "#000d00"];
    }

    /// @dev head, outline, highlight, neck, feet
    function _skin(uint256 i) private pure returns (string[5] memory) {
        if (i == 0) return ["#64a84d", "#21451a", "#86c56c", "#4a8a37", "#4c8f3a"];
        if (i == 1) return ["#8aa86b", "#3a4a2a", "#b0c98f", "#6e8a52", "#7a9660"];
        if (i == 2) return ["#7fd3e8", "#1d5c6e", "#c4f1fb", "#5fb3c9", "#6cc2d8"];
        if (i == 3) return ["#f29bb3", "#7a2e45", "#ffd0dc", "#d9778f", "#e48aa3"];
        if (i == 4) return ["#3a3a3a", "#000000", "#5a5a5a", "#2a2a2a", "#333333"];
        return ["#e6b422", "#7a5a00", "#ffe27a", "#c9961a", "#d4a017"];
    }

    /// @dev fill, stroke, seam
    function _shirt(uint256 i) private pure returns (string[3] memory) {
        if (i == 0) return ["#2c60cc", "#11296a", "#1f4aa6"];
        if (i == 1) return ["#d23c3c", "#6e1414", "#b02a2a"];
        if (i == 2) return ["#1f1f1f", "#000000", "#333333"];
        if (i == 3) return ["#ececec", "#6b6b6b", "#cfcfcf"];
        if (i == 4) return ["#2e9d57", "#124a27", "#237d45"];
        if (i == 5) return ["#7a4fd6", "#3a2170", "#6440b8"];
        if (i == 6) return ["#f28c28", "#7a4108", "#d9761a"];
        return ["#8a8f98", "#3f434a", "#747982"];
    }

    function _shorts(uint256 i) private pure returns (string[2] memory) {
        if (i == 0) return ["#b08d5c", "#4d3a1c"];
        if (i == 1) return ["#6b6b6b", "#2e2e2e"];
        if (i == 2) return ["#3d5a80", "#1b2a3d"];
        if (i == 3) return ["#2a2a2a", "#000000"];
        return ["#a83232", "#4a1010"];
    }

    // ------------------------------------------------------------ drawing

    /// @dev Rows of instrument panels (knobs, LEDs, waves) above a floor, laid out by a seeded LCG.
    function _wall(Traits memory t) private pure returns (string memory out) {
        string[5] memory c = _back(t.back);
        uint256 s = t.seed;
        bytes memory b = abi.encodePacked('<rect width="300" height="300" fill="', c[0], '"/>');
        uint256 y = 4;
        while (y < 214) {
            s = (s * 1103515245 + 12345) % 2147483648;
            uint256 rh = 20 + (s % 3) * 14;
            if (rh > 230 - y) rh = 230 - y;
            uint256 x = 4;
            while (x < 280) {
                s = (s * 1103515245 + 12345) % 2147483648;
                uint256 rw = 24 + (s % 4) * 16;
                if (rw > 296 - x) rw = 296 - x;
                s = (s * 1103515245 + 12345) % 2147483648;
                b = abi.encodePacked(
                    b,
                    '<rect x="', S.toString(x), '" y="', S.toString(y), '" width="', S.toString(rw - 3),
                    '" height="', S.toString(rh - 3), '" fill="', c[1], '" stroke="', s % 8 == 0 ? c[3] : c[2],
                    '" stroke-width="1.2"/>'
                );
                b = abi.encodePacked(b, _detail(s >> 3, x, y, rw, rh, c));
                x += rw;
            }
            y += rh;
        }
        out = string(
            abi.encodePacked(
                b, '<rect y="234" width="300" height="6" fill="#121212"/><rect y="240" width="300" height="60" fill="', c[4], '"/>'
            )
        );
    }

    function _detail(uint256 s, uint256 x, uint256 y, uint256 rw, uint256 rh, string[5] memory c)
        private
        pure
        returns (bytes memory b)
    {
        uint256 kind = s % 4;
        uint256 cy = y + rh / 2;
        if (kind == 0) {
            for (uint256 i; i < rw / 16; i++) {
                b = abi.encodePacked(
                    b, '<circle cx="', S.toString(x + 8 + i * 15), '" cy="', S.toString(cy - 1),
                    '" r="4" fill="none" stroke="', c[2], '"/>'
                );
            }
        } else if (kind == 1) {
            for (uint256 i; i < rw / 9; i++) {
                bool on = ((s >> (i + 2)) & 3) == 0;
                b = abi.encodePacked(
                    b, '<rect x="', S.toString(x + 5 + i * 8), '" y="', S.toString(cy - 3),
                    '" width="5" height="5" fill="', on ? c[3] : "none", '" stroke="', c[2], '" stroke-width=".8"/>'
                );
            }
        } else if (kind == 2) {
            b = abi.encodePacked(
                '<path d="M', S.toString(x + 5), " ", S.toString(cy), " q", S.toString(rw / 6), " -",
                S.toString(rh / 3), " ", S.toString(rw / 3), " 0 t", S.toString(rw / 3), ' 0" fill="none" stroke="',
                c[3], '" stroke-width="1.4"/>'
            );
        }
    }

    function _frog(Traits memory t) private pure returns (string memory) {
        return string.concat(_body(t), _carry(t.acc, t.skin), _headSvg(t), _hat(t.head));
    }

    function _body(Traits memory t) private pure returns (string memory o) {
        string[5] memory k = _skin(t.skin);
        string[2] memory p = _shorts(t.shorts);
        if (t.acc == 3) {
            o = '<rect x="12" y="116" width="76" height="6" rx="3" fill="#8b5a2b" stroke="#3b2414" stroke-width="1.5"/><circle cx="22" cy="125" r="3" fill="#222"/><circle cx="78" cy="125" r="3" fill="#222"/>';
        }
        o = string.concat(
            o,
            '<path d="M34 106 L34 116 M45 106 L45 116 M55 106 L55 116 M66 106 L66 116" stroke="#3b2a14" stroke-width="2"/>',
            '<ellipse cx="39" cy="117" rx="9" ry="4" fill="', k[4], '" stroke="', k[1], '" stroke-width="2"/>',
            '<ellipse cx="61" cy="117" rx="9" ry="4" fill="', k[4], '" stroke="', k[1], '" stroke-width="2"/>',
            '<path d="M27 88 L73 88 L75 107 L52 108 L50 101 L48 108 L25 107 Z" fill="', p[0], '" stroke="', p[1],
            '" stroke-width="2.4" stroke-linejoin="round"/>'
        );
        if (t.acc != ACC_CAPE) {
            string[3] memory sh = _shirt(t.shirt);
            o = string.concat(
                o,
                '<path d="M24 50 Q15 57 16 76 Q17 88 26 90 Q50 96 74 90 Q83 88 84 76 Q85 57 76 50 Z" fill="', sh[0],
                '" stroke="', sh[1], '" stroke-width="2.6" stroke-linejoin="round"/>',
                '<path d="M30 56 Q27 70 29 87 M70 56 Q73 70 71 87" stroke="', sh[2], '" stroke-width="2" fill="none"/>',
                t.shirt == 7 ? string.concat('<path d="M34 52 Q50 46 66 52 L64 60 Q50 55 36 60 Z" fill="', sh[2], '"/>') : ""
            );
        }
    }

    /// @dev Things worn on the back or carried: cape (replaces the shirt), backpack, IMD coin bag.
    function _carry(uint256 acc, uint256 skin) private pure returns (string memory) {
        if (acc == ACC_CAPE) {
            return string.concat(
                '<path d="M22 50 Q50 58 78 50 L86 104 Q50 112 14 104 Z" fill="', skin == SKIN_GOLD ? "#6a1b9a" : "#c62828",
                '" stroke="#2a0a0a" stroke-width="2.2" stroke-linejoin="round"/><path d="M32 60 L28 100 M50 62 L50 106 M68 60 L72 100" stroke="#000" stroke-opacity=".18" stroke-width="2"/>'
            );
        }
        if (acc == 1) {
            return '<path d="M31 50 L33 66 M69 50 L67 66" stroke="#2b2b2b" stroke-width="3"/><rect x="31" y="60" width="38" height="30" rx="7" fill="#e0a526" stroke="#5a3e05" stroke-width="2.2"/><rect x="36" y="66" width="28" height="9" rx="3" fill="#c98a12" stroke="#5a3e05" stroke-width="1.6"/>';
        }
        if (acc == 2) {
            return '<path d="M84 74 Q98 76 97 92 Q96 104 86 104 Q76 104 75 92 Q75 80 84 74 Z" fill="#f5c542" stroke="#7a5a00" stroke-width="2"/><path d="M80 75 L88 71" stroke="#7a5a00" stroke-width="2"/><text x="86" y="93" font-family="monospace" font-size="7" font-weight="700" text-anchor="middle" fill="#5a3e05">IMD</text>';
        }
        return "";
    }

    function _headSvg(Traits memory t) private pure returns (string memory) {
        string[5] memory k = _skin(t.skin);
        return string.concat(
            '<path d="M8 44 Q4 28 14 16 Q22 6 34 9 Q42 11 46 17 Q50 15 54 17 Q58 11 66 9 Q78 6 86 16 Q96 28 92 44 Q88 58 50 60 Q12 58 8 44 Z" fill="',
            k[0], '" stroke="', k[1], '" stroke-width="3" stroke-linejoin="round"/>',
            '<path d="M16 22 Q24 14 34 15 M66 15 Q76 14 84 22" stroke="', k[2],
            '" stroke-width="3" fill="none" stroke-linecap="round" opacity=".8"/>',
            '<path d="M30 50 Q50 56 70 50" stroke="', k[3], '" stroke-width="2" fill="none" stroke-linecap="round"/>'
        );
    }

    function _hat(uint256 h) private pure returns (string memory) {
        if (h == 1) {
            return '<path d="M14 26 Q16 2 50 2 Q84 2 86 26 Q50 18 14 26 Z" fill="#1d4ed8" stroke="#0b1f5c" stroke-width="2.2"/><path d="M42 22 Q50 30 58 22" fill="#0b1f5c"/><rect x="45" y="16" width="10" height="4" rx="1" fill="#e5e7eb"/>';
        }
        if (h == 2) {
            return '<path d="M12 28 Q12 -2 50 -2 Q88 -2 88 28 Z" fill="#d97706" stroke="#5a2f02" stroke-width="2.2"/><rect x="11" y="22" width="78" height="9" rx="3" fill="#b45309" stroke="#5a2f02" stroke-width="2"/><circle cx="50" cy="-4" r="6" fill="#fde68a" stroke="#5a2f02" stroke-width="1.8"/>';
        }
        if (h == 3) {
            return '<path d="M10 38 Q8 -4 50 -4 Q92 -4 90 38" fill="none" stroke="#111" stroke-width="5"/><ellipse cx="9" cy="38" rx="7" ry="11" fill="#e11d48" stroke="#111" stroke-width="2.2"/><ellipse cx="91" cy="38" rx="7" ry="11" fill="#e11d48" stroke="#111" stroke-width="2.2"/>';
        }
        if (h == 4) {
            return '<path d="M38 14 L50 -24 L62 14 Z" fill="#8b5cf6" stroke="#3b1d8f" stroke-width="2"/><path d="M42 2 L58 2 M45 -8 L55 -8" stroke="#fde047" stroke-width="3"/><circle cx="50" cy="-25" r="4" fill="#fde047"/>';
        }
        if (h == 5) {
            return '<ellipse cx="50" cy="-8" rx="27" ry="6" fill="none" stroke="#fde047" stroke-width="4"/><ellipse cx="50" cy="-8" rx="27" ry="6" fill="none" stroke="#fff7c2" stroke-width="1.2"/>';
        }
        if (h == HEAD_CROWN) {
            return '<path d="M24 14 L28 -10 L39 4 L50 -16 L61 4 L72 -10 L76 14 Z" fill="#f5c542" stroke="#7a5a00" stroke-width="2.2" stroke-linejoin="round"/><circle cx="50" cy="6" r="3.5" fill="#dc2626"/><circle cx="36" cy="8" r="2.5" fill="#2563eb"/><circle cx="64" cy="8" r="2.5" fill="#16a34a"/>';
        }
        return "";
    }
}
