// PepesFamily Hall: a 3D room in the style of the IMD swarm wall, where your Pepe walks up to screens to launch,
// trade and claim. Laid out like imd.fun (the instrument wall, the big screen, the man at his desk and his dog),
// with a crowd of Pepes watching.
// Classic script (no modules): uses the THREE global from /js/three-0.160.0.min.js and exposes window.Hall.
(() => {
  "use strict";
  const T = window.THREE;

  // ------------------------------------------------------------------ helpers
  const rnd = (seed) => () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296);
  const canvas = (w, h) => { const c = document.createElement("canvas"); c.width = w; c.height = h; return c; };
  const tex = (c) => { const t = new T.CanvasTexture(c); t.colorSpace = T.SRGBColorSpace; t.anisotropy = 4; return t; };
  const GREEN = "#3ddc84", INK = "#151515", PANEL = "#dcdcd8", PANEL2 = "#c9c9c4";
  const GRADIENT = (() => {
    const d = new Uint8Array([90, 170, 255]);
    const g = new T.DataTexture(d, 3, 1, T.RedFormat);
    g.minFilter = g.magFilter = T.NearestFilter; g.needsUpdate = true;
    return g;
  })();
  const toon = (color, extra = {}) => new T.MeshToonMaterial({ color, gradientMap: GRADIENT, ...extra });
  const OUTLINE = new T.MeshBasicMaterial({ color: 0x111111, side: T.BackSide });

  // ------------------------------------------------------------------ the instrument wall (as on imd.fun)
  // A packed patchwork of instrument modules (knob banks, patch bays, scopes, meters, readouts, dials, LEDs, small
  // buttons), big ones above and small ones below, some lit green. Seeded, so it is the same wall on every visit;
  // tick() redraws the moving parts (needles, waves, bars, counters, LEDs, which modules are lit) a few times a second.
  function makeWall(WW, WH) {
    const c = canvas(WW, WH), g = c.getContext("2d"), r = rnd(4663);
    const CELL = 16, COLS = Math.floor(WW / CELL), ROWS = Math.floor(WH / CELL);
    const DARK = "#0d110d", PANEL_A = "#dcdcd8", PANEL_B = "#cfcfca", DIM = "#2c3a2c";
    // pack the grid row by row: every free cell starts a module as big as fits (bigger towards the top)
    const used = new Uint8Array(COLS * ROWS);
    const mods = [];
    for (let y = 0; y < ROWS; y++) for (let x = 0; x < COLS; x++) {
      if (used[y * COLS + x]) continue;
      const top = 1 - y / ROWS; // 1 at the top, 0 at the bottom
      const big = r() < 0.18 + top * 0.5;
      let w = big ? 4 + Math.floor(r() * (6 + top * 10)) : 1 + Math.floor(r() * (r() < 0.6 ? 2 : 4));
      let h = big ? 3 + Math.floor(r() * (3 + top * 6)) : 1 + Math.floor(r() * (r() < 0.7 ? 1 : 3));
      w = Math.min(w, COLS - x); h = Math.min(h, ROWS - y);
      for (let i = 1; i < w; i++) if (used[y * COLS + x + i]) { w = i; break; }
      for (let j = 1; j < h; j++) { let ok = true; for (let i = 0; i < w; i++) if (used[(y + j) * COLS + x + i]) { ok = false; break; } if (!ok) { h = j; break; } }
      for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) used[(y + j) * COLS + x + i] = 1;
      const m = { x: x * CELL, y: y * CELL, w: w * CELL, h: h * CELL, seed: Math.floor(r() * 1e9), panel: r() < 0.18 ? PANEL_B : PANEL_A, lit: r() < 0.06 };
      const small = w * h <= 3;
      const KINDS_BIG = ["knobs", "patch", "scope", "bars", "seg", "sliders", "leds", "gauge", "keys", "vent", "label", "radar", "mixer", "matrix"];
      const KINDS_SMALL = ["ring", "dot", "square", "plus", "diamond", "dial", "led", "switch", "sun", "grid4", "bar1", "wave1"];
      m.kind = small ? KINDS_SMALL[Math.floor(r() * KINDS_SMALL.length)] : KINDS_BIG[Math.floor(r() * KINDS_BIG.length)];
      m.moves = ["scope", "bars", "seg", "leds", "gauge", "radar", "dial", "led", "wave1", "bar1", "matrix", "sliders"].includes(m.kind) && r() < 0.75;
      mods.push(m);
    }
    const line = (x1, y1, x2, y2) => { g.beginPath(); g.moveTo(x1, y1); g.lineTo(x2, y2); g.stroke(); };
    const circ = (x, y, rad, fill) => { g.beginPath(); g.arc(x, y, rad, 0, 7); fill ? g.fill() : g.stroke(); };
    const screenBox = (x, y, w, h) => { g.fillStyle = DARK; g.fillRect(x, y, w, h); g.strokeStyle = "#111"; g.lineWidth = 2; g.strokeRect(x, y, w, h); };
    const LABELS = ["ACTIVE", "AUTO", "REMOTE", "RUN", "LOAD", "SWARM", "LIVE", "SYNC", "MANUAL", "LEVEL", "NORMAL"];
    function draw(m, t) {
      const rr = rnd(m.seed), { x, y, w, h } = m;
      const px = x + 2, py = y + 2, pw = w - 4, ph = h - 4, cx = px + pw / 2, cy = py + ph / 2;
      g.fillStyle = "#e9e9e6"; g.fillRect(x, y, w, h);
      g.fillStyle = m.panel; g.fillRect(px, py, pw, ph);
      g.strokeStyle = "#151515"; g.lineWidth = 2; g.strokeRect(px, py, pw, ph);
      g.strokeStyle = "#151515"; g.fillStyle = "#151515"; g.lineWidth = 2;
      const k = m.kind, live = m.moves ? t : 0;
      if (k === "ring") circ(cx, cy, Math.min(pw, ph) * 0.3);
      else if (k === "dot") circ(cx, cy, Math.min(pw, ph) * 0.22, true);
      else if (k === "square") g.strokeRect(cx - pw * 0.25, cy - ph * 0.25, pw * 0.5, ph * 0.5);
      else if (k === "plus") { line(cx - pw * 0.25, cy, cx + pw * 0.25, cy); line(cx, cy - ph * 0.25, cx, cy + ph * 0.25); }
      else if (k === "diamond") { g.beginPath(); g.moveTo(cx, cy - ph * 0.3); g.lineTo(cx + pw * 0.3, cy); g.lineTo(cx, cy + ph * 0.3); g.lineTo(cx - pw * 0.3, cy); g.closePath(); g.stroke(); }
      else if (k === "dial") { const rad = Math.min(pw, ph) * 0.34; circ(cx, cy, rad); const a = -2.2 + rr() * 4.4 + Math.sin(live * (0.6 + rr()) + rr() * 6) * 0.8; line(cx, cy, cx + Math.sin(a) * rad, cy - Math.cos(a) * rad); }
      else if (k === "led") { g.fillStyle = (Math.sin(live * (1 + rr() * 3) + rr() * 6) > 0.3 || (!m.moves && rr() < 0.3)) ? GREEN : "#151515"; circ(cx, cy, Math.min(pw, ph) * 0.2, true); }
      else if (k === "switch") { g.strokeRect(cx - pw * 0.15, cy - ph * 0.3, pw * 0.3, ph * 0.6); g.fillRect(cx - pw * 0.15, rr() < 0.5 ? cy - ph * 0.3 : cy, pw * 0.3, ph * 0.3); }
      else if (k === "sun") { for (let i = 0; i < 8; i++) { const a = i * Math.PI / 4, r1 = Math.min(pw, ph) * 0.12, r2 = Math.min(pw, ph) * 0.32; line(cx + Math.cos(a) * r1, cy + Math.sin(a) * r1, cx + Math.cos(a) * r2, cy + Math.sin(a) * r2); } }
      else if (k === "grid4") { const s = Math.min(pw, ph) * 0.2; for (let i = 0; i < 2; i++) for (let j = 0; j < 2; j++) g.strokeRect(cx - s * 1.1 + i * s * 1.2, cy - s * 1.1 + j * s * 1.2, s, s); }
      else if (k === "bar1") { screenBox(px + 4, py + 4, pw - 8, ph - 8); g.fillStyle = GREEN; const n = Math.max(1, Math.floor((pw - 12) / 6)); for (let i = 0; i < n; i++) { const v = 0.3 + 0.6 * Math.abs(Math.sin(live * 2 + i * 1.3 + m.seed)); g.fillRect(px + 7 + i * 6, py + ph - 7 - (ph - 14) * v, 4, (ph - 14) * v); } }
      else if (k === "wave1") { screenBox(px + 4, py + 4, pw - 8, ph - 8); g.strokeStyle = GREEN; g.beginPath(); for (let i = 0; i <= 12; i++) { const xx = px + 6 + (pw - 12) * i / 12, yy = cy + Math.sin(i * 1.1 + live * 3 + m.seed) * (ph / 2 - 8); i ? g.lineTo(xx, yy) : g.moveTo(xx, yy); } g.stroke(); }
      else if (k === "knobs" || k === "mixer") {
        const n = Math.max(2, Math.floor(pw / 30)), rows = Math.max(1, Math.floor(ph / 34));
        for (let j = 0; j < rows; j++) for (let i = 0; i < n; i++) {
          const kx = px + 16 + i * (pw - 32) / Math.max(1, n - 1), ky = py + 18 + j * (ph - 36) / Math.max(1, rows - 1);
          if (k === "mixer" && j === rows - 1 && rows > 1) { line(kx, ky - 10, kx, ky + 10); g.fillRect(kx - 5, ky - 6 + rr() * 8, 10, 6); continue; }
          circ(kx, ky, 9); const a = rr() * 6; line(kx, ky, kx + Math.sin(a) * 9, ky - Math.cos(a) * 9);
        }
      } else if (k === "patch") {
        const n = Math.max(2, Math.floor(pw / 26)), rows = Math.max(2, Math.floor(ph / 26)), pts = [];
        for (let j = 0; j < rows; j++) for (let i = 0; i < n; i++) { const kx = px + 14 + i * (pw - 28) / Math.max(1, n - 1), ky = py + 14 + j * (ph - 28) / Math.max(1, rows - 1); pts.push([kx, ky]); circ(kx, ky, 6); }
        g.lineWidth = 3;
        for (let q = 0; q < Math.max(1, pts.length / 5); q++) { const A = pts[Math.floor(rr() * pts.length)], B = pts[Math.floor(rr() * pts.length)]; g.beginPath(); g.moveTo(A[0], A[1]); g.quadraticCurveTo((A[0] + B[0]) / 2, Math.max(A[1], B[1]) + 18, B[0], B[1]); g.stroke(); circ(A[0], A[1], 4, true); circ(B[0], B[1], 4, true); }
        g.lineWidth = 2;
      } else if (k === "scope") {
        screenBox(px + 6, py + 6, pw - 12, ph - 12);
        g.strokeStyle = DIM; g.lineWidth = 1; for (let i = 1; i < 4; i++) { line(px + 6 + (pw - 12) * i / 4, py + 6, px + 6 + (pw - 12) * i / 4, py + ph - 6); line(px + 6, py + 6 + (ph - 12) * i / 4, px + pw - 6, py + 6 + (ph - 12) * i / 4); }
        g.strokeStyle = GREEN; g.lineWidth = 2.5; g.beginPath(); const f = 0.5 + rr() * 1.5, kind = Math.floor(rr() * 3);
        for (let i = 0; i <= 40; i++) { const u = i / 40, xx = px + 8 + (pw - 16) * u, ph2 = u * 12 * f + live * 2.5; const v = kind === 0 ? Math.sin(ph2) : kind === 1 ? (Math.sin(ph2) > 0 ? 0.7 : -0.7) : ((ph2 / Math.PI) % 2) - 1; const yy = cy + v * (ph / 2 - 12); i ? g.lineTo(xx, yy) : g.moveTo(xx, yy); }
        g.stroke(); g.lineWidth = 2;
      } else if (k === "bars") {
        screenBox(px + 6, py + 6, pw - 12, ph - 12); g.fillStyle = GREEN;
        const n = Math.max(3, Math.floor((pw - 16) / 9));
        for (let i = 0; i < n; i++) { const v = 0.15 + 0.8 * Math.abs(Math.sin(live * (1.2 + (i % 3) * 0.4) + i * 0.7 + m.seed % 7)) * (0.5 + rr() * 0.5); const bh = (ph - 20) * v; g.fillRect(px + 10 + i * 9, py + ph - 10 - bh, 6, bh); }
      } else if (k === "seg") {
        screenBox(px + 6, py + 6, pw - 12, ph - 12);
        const digits = Math.max(2, Math.min(8, Math.floor((pw - 16) / 18))), size = Math.min(ph - 18, 34);
        const n = Math.floor((m.seed % 99991) + live * (1 + (m.seed % 5)) * 3) % Math.pow(10, digits);
        g.fillStyle = GREEN; g.font = `bold ${size}px monospace`; g.textBaseline = "middle"; g.fillText(String(n).padStart(digits, "0"), px + 12, cy + 1); g.textBaseline = "alphabetic";
      } else if (k === "sliders") {
        const n = Math.max(2, Math.floor((pw - 12) / 16));
        for (let i = 0; i < n; i++) { const xx = px + 12 + i * 16; line(xx, py + 10, xx, py + ph - 10); const v = rr() * 0.8 + Math.sin(live * 0.7 + i + m.seed) * 0.1; g.fillRect(xx - 5, py + 10 + v * (ph - 28), 10, 8); }
      } else if (k === "leds" || k === "matrix") {
        const s = k === "matrix" ? 9 : 14, n = Math.max(1, Math.floor((pw - 10) / s)), rows = Math.max(1, Math.floor((ph - 10) / s));
        if (k === "matrix") screenBox(px + 3, py + 3, pw - 6, ph - 6);
        for (let j = 0; j < rows; j++) for (let i = 0; i < n; i++) {
          const on = Math.sin(live * (0.8 + rr() * 2.5) + rr() * 6.28) > (k === "matrix" ? 0.2 : 0.5);
          g.fillStyle = on ? GREEN : k === "matrix" ? DIM : "#151515";
          if (k === "matrix") g.fillRect(px + 6 + i * s, py + 6 + j * s, s - 3, s - 3); else circ(px + 12 + i * s, py + 12 + j * s, 4, true);
        }
      } else if (k === "gauge" || k === "radar") {
        const rad = Math.min(pw, ph) * 0.4;
        if (k === "radar") { screenBox(cx - rad - 4, cy - rad - 4, rad * 2 + 8, rad * 2 + 8); g.strokeStyle = DIM; circ(cx, cy, rad); circ(cx, cy, rad * 0.6); g.strokeStyle = GREEN; const a = live * 1.6 + m.seed; g.lineWidth = 3; line(cx, cy, cx + Math.cos(a) * rad, cy + Math.sin(a) * rad); g.lineWidth = 2; g.fillStyle = GREEN; circ(cx + Math.cos(m.seed) * rad * 0.5, cy + Math.sin(m.seed) * rad * 0.4, 3, true); }
        else { circ(cx, cy, rad); for (let i = 0; i <= 10; i++) { const a = -2.3 + i * 0.46; line(cx + Math.sin(a) * rad * 0.82, cy - Math.cos(a) * rad * 0.82, cx + Math.sin(a) * rad, cy - Math.cos(a) * rad); } const a = -2 + rr() * 4 + Math.sin(live * (0.4 + rr()) + m.seed) * 0.9; g.lineWidth = 3; line(cx, cy, cx + Math.sin(a) * rad * 0.8, cy - Math.cos(a) * rad * 0.8); g.lineWidth = 2; circ(cx, cy, 4, true); }
      } else if (k === "keys") {
        const s = 18, n = Math.max(1, Math.floor((pw - 8) / s)), rows = Math.max(1, Math.floor((ph - 8) / s));
        for (let j = 0; j < rows; j++) for (let i = 0; i < n; i++) { const kx = px + 6 + i * s, ky = py + 6 + j * s; if (rr() < 0.15) { g.fillStyle = rr() < 0.4 ? GREEN : "#151515"; g.fillRect(kx, ky, s - 5, s - 5); } else g.strokeRect(kx, ky, s - 5, s - 5); }
      } else if (k === "vent") { for (let yy = py + 8; yy < py + ph - 6; yy += 6) line(px + 8, yy, px + pw - 8, yy); }
      else if (k === "label") {
        const bw = Math.min(pw - 12, 120), bh = Math.min(ph - 12, 32);
        screenBox(cx - bw / 2, cy - bh / 2, bw, bh); g.fillStyle = GREEN; g.font = `bold ${Math.min(18, bh - 10)}px monospace`; g.textAlign = "center"; g.textBaseline = "middle";
        g.fillText(LABELS[m.seed % LABELS.length].slice(0, Math.floor(bw / 11)), cx, cy + 1); g.textAlign = "left"; g.textBaseline = "alphabetic";
        if (ph > 60) for (let i = 0; i < Math.floor(pw / 24); i++) circ(px + 14 + i * 24, py + ph - 14, 6);
      }
      if (m.lit) { g.strokeStyle = GREEN; g.lineWidth = 3; g.strokeRect(px + 1, py + 1, pw - 2, ph - 2); g.lineWidth = 2; }
    }
    for (const m of mods) draw(m, 0);
    const texture = tex(c);
    const moving = mods.filter((m) => m.moves);
    let lastTick = -1, nextSwap = 0;
    return {
      texture,
      /// Redraws what moves; `t` in seconds. Every few seconds a different handful of modules lights up green.
      tick(t) {
        if (t >= nextSwap) {
          nextSwap = t + 4 + Math.random() * 4;
          for (let i = 0; i < 6; i++) { const m = mods[Math.floor(Math.random() * mods.length)]; if (m.w * m.h > 64 * 9) { m.lit = !m.lit; draw(m, t); } }
        }
        for (const m of moving) draw(m, t);
        texture.needsUpdate = true;
        lastTick = t;
      },
      /// Something happened (a trade or a launch): a burst of green across the wall.
      pulse(t) {
        const picked = [];
        for (let i = 0; i < 10; i++) { const m = mods[Math.floor(Math.random() * mods.length)]; if (m.w * m.h > 64 * 6 && !m.lit) { m.lit = true; picked.push(m); draw(m, t); } }
        texture.needsUpdate = true;
        setTimeout(() => { for (const m of picked) { m.lit = false; draw(m, lastTick); } texture.needsUpdate = true; }, 2500);
      },
    };
  }

  function floorTexture() {
    const c = canvas(1024, 1024), g = c.getContext("2d"), r = rnd(7);
    g.fillStyle = "#f4f4f1"; g.fillRect(0, 0, 1024, 1024);
    g.fillStyle = "#1a1a1a";
    for (let i = 0; i < 2600; i++) { const s = r() < 0.92 ? 1.5 : 3.5; g.fillRect(r() * 1024, r() * 1024, s, s * (0.5 + r())); }
    g.strokeStyle = "rgba(0,0,0,.35)"; g.lineWidth = 2;
    for (let i = 0; i < 9; i++) { g.beginPath(); const y = r() * 1024; g.moveTo(0, y); g.lineTo(1024, y + (r() - 0.5) * 300); g.stroke(); }
    const t = tex(c); t.wrapS = t.wrapT = T.RepeatWrapping; t.repeat.set(6, 2);
    return t;
  }

  // ------------------------------------------------------------------ Pepes
  // The Pepe is IMD's own character art (imd.fun's sprite sheet, used at the IMD team's request): 19 frames of
  // 240 x 284 in one image, shown on a camera-facing card that picks the frame for the view and the motion.
  const SHEET = "/img/imd-pepe.webp", SHEET_FRAMES = 19, FW = 240, FH = 284;
  // IMD's sheet has no walking frames for the front views, so four are made from its front (14) and front
  // three-quarter (13) frames: one foot raised (that leg tucked up under the shorts), then the other.
  const STEPS = [[14, 0, 120], [14, 120, 240], [13, 0, 128], [13, 128, 240]]; // frame, the leg's columns
  const HEM = 261, LIFT = 6; // where the legs come out of the shorts; how far a foot rises
  const FRAMES = SHEET_FRAMES + STEPS.length, COLS = 12, ROWS = Math.ceil(FRAMES / COLS); // an atlas of 12 x 2
  const F = {
    back: 3, backAlt: 4, backWalk: [1, 2], backScratch: [5, 6], cheer: [17, 18],
    backQuarter: 12, backQuarterWalk: [9, 11],   // back three-quarter, facing right
    side: 7, sideWalk: [8, 9, 10, 11],           // profile facing right
    frontQuarter: 13, frontQuarterWalk: [21, 13, 22, 13], // front three-quarter, facing right
    front: 14, frontWalk: [19, 14, 20, 14], frontUp: 15, frontScratch: 16,
  };
  let sheet = null, sheetDone = null;
  const sheetMaps = []; // the sheet and every Pepe's copy of it, refreshed once the image has loaded
  const sheetReady = new Promise((res) => { sheetDone = res; }); // the atlas canvas, once drawn
  const sheetTexture = () => {
    if (!sheet) {
      const c = canvas(COLS * FW, ROWS * FH), g = c.getContext("2d");
      sheet = new T.CanvasTexture(c); sheet.colorSpace = T.SRGBColorSpace; sheetMaps.push(sheet);
      const img = new Image();
      img.onload = () => {
        const cell = (i) => [(i % COLS) * FW, Math.floor(i / COLS) * FH];
        for (let i = 0; i < SHEET_FRAMES; i++) g.drawImage(img, i * FW, 0, FW, FH, ...cell(i), FW, FH);
        STEPS.forEach(([f, x0, x1], k) => {
          const [sx, sy] = cell(f), [dx, dy] = cell(SHEET_FRAMES + k);
          g.drawImage(c, sx, sy, FW, FH, dx, dy, FW, FH);
          g.clearRect(dx + x0, dy + HEM, x1 - x0, FH - HEM); // that leg, gone
          g.drawImage(c, sx + x0, sy + HEM + LIFT, x1 - x0, FH - HEM - LIFT, dx + x0, dy + HEM, x1 - x0, FH - HEM - LIFT); // and back, raised
        });
        for (const m of sheetMaps) m.needsUpdate = true;
        sheetDone(c);
      };
      img.src = SHEET;
    }
    return sheet;
  };
  let activeCamera = null;

  // ------------------------------------------------------------------ wearing a Pepes Family NFT
  // A revealed Pepes Family NFT's look (skin, shirt, shorts, extra) put on the Hall's Pepe, the way the NFT contract
  // draws it (github.com/0xtenang/PepesFamilyNFT, tools/gen_imd_art.py): colour-keyed masks pick out the skin, the
  // shirt and the shorts (the shorts only below y 175, so the lips are never caught), and each is retinted from the
  // pixel's lightness, keeping IMD's lines and shading; headphones, a halo or shades go on as the contract places
  // them. The atlas cells are the sheet's 240 x 284 frames, the same space the contract draws in.
  const LOOK = {
    skin: [null, "8aa86b", "7fd3e8", "f29bb3", "4a4a4a", "9b7fe0", "e6b422"],
    shirt: [null, "d23c3c", "1f1f1f", "ececec", "3ddc84", "7a4fd6", "f28c28", "8a8f98", "f5d33b"],
    shorts: [null, "6b6b6b", "3d5a80", "2a2a2a", "a83232", "e8e8e8"],
    base: { skin: 124, shirt: 71, shorts: 145 },
    shortsFrom: 175,
  };
  /// The look in an NFT's trait spec (32 bits: pose 5, skin 3, shirt 4, shorts 3, background 4, extra 4, 1/1 3).
  const lookOf = (v) => ({ skin: (v >>> 5) & 7, shirt: (v >>> 8) & 15, shorts: (v >>> 12) & 7, extra: (v >>> 19) & 15 });
  const EXTRA_NONE = 0, EXTRA_HEADPHONES = 1, EXTRA_SHADES = 2, EXTRA_HALO = 3;
  const XLINE = 'stroke="#1c1c1c" stroke-width="2.6" stroke-linejoin="round" stroke-linecap="round"';
  const HP_FRONT = '<g transform="translate(0 16)"><path d="M-64 42C-66-22 66-22 64 42" fill="none" stroke-width="7"/><path d="M-64 42C-66-22 66-22 64 42" fill="none" stroke="#4b5563" stroke-width="3"/><ellipse cx="-64" cy="46" rx="10" ry="16" fill="#e11d48"/><ellipse cx="64" cy="46" rx="10" ry="16" fill="#e11d48"/></g>';
  const XSVG = {
    [EXTRA_HEADPHONES]: { back: HP_FRONT, front: HP_FRONT, side: '<g transform="translate(0 10)"><path d="M-48 40C-56-16 4-24 14 30" fill="none" stroke-width="7"/><path d="M-48 40C-56-16 4-24 14 30" fill="none" stroke="#4b5563" stroke-width="3"/><ellipse cx="-22" cy="44" rx="12" ry="17" fill="#e11d48"/></g>' },
    [EXTRA_HALO]: { all: '<g transform="translate(0 4)"><ellipse cy="-26" rx="40" ry="9" fill="none" stroke-width="7"/><ellipse cy="-26" rx="40" ry="9" fill="none" stroke="#fde047" stroke-width="3.5"/></g>' },
    [EXTRA_SHADES]: { front: '<path d="M-50-12h42c3 0 4 2 4 5v8c0 10-6 15-16 15h-18c-10 0-16-5-16-15v-8c0-3 1-5 4-5Z" fill="#111"/><path d="M50-12h-42c-3 0-4 2-4 5v8c0 10 6 15 16 15h18c10 0 16-5 16-15v-8c0-3-1-5-4-5Z" fill="#111"/><path d="M-4-6h8" fill="none"/><path d="M-40-6h8M16-6h8" stroke="#fff" stroke-width="2.5" opacity=".75"/>' },
  };
  // per sheet frame: where head extras go (x, y, scale %, tilt), and the view; the eyes on the front frames
  const XHAT = [[129, 67, 102, 0], [129, 67, 98, 0], [130, 60, 103, 0], [122, 79, 92, 0], [123, 80, 96, 0], [130, 74, 104, 0], [127, 72, 104, 0], [129, 68, 94, 0], [130, 66, 94, 0], [128, 65, 88, 0], [134, 71, 85, 0], [128, 68, 85, 0], [121, 71, 99, 0], [121, 89, 98, 0], [119, 79, 100, 0], [122, 66, 94, -6], [118, 79, 104, 0], [120, 24, 104, 0], [122, 68, 104, 0]];
  const XEYES = { 13: [159, 118, 71], 14: [121, 110, 101], 15: [121, 79, 63], 16: [122, 110, 100] };
  const XVIEW = (f) => (f < 7 || f > 16 ? "back" : f < 13 ? "side" : "front");
  const sourceFrame = (cellIndex) => (cellIndex < SHEET_FRAMES ? cellIndex : STEPS[cellIndex - SHEET_FRAMES][0]); // step frames copy 14 / 13
  const hexRgb = (h) => [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
  const clamp01 = (x) => (x < 0 ? 0 : x > 1 ? 1 : x);
  const looks = new Map(); // look key -> Promise of its texture

  /// The atlas recoloured (and dressed) for `look`, as a texture; built once per look.
  function lookTexture(look) {
    const key = `${look.skin}.${look.shirt}.${look.shorts}.${look.extra}`;
    if (!looks.has(key)) looks.set(key, sheetReady.then(async (base) => {
      const c = canvas(base.width, base.height), g = c.getContext("2d");
      g.drawImage(base, 0, 0);
      const img = g.getImageData(0, 0, c.width, c.height), d = img.data, W = c.width;
      const tint = (name) => { const h = LOOK[name][look[name]]; if (!h) return null; const b = LOOK.base[name]; return hexRgb(h).map((v) => v / b); };
      const tSkin = tint("skin"), tShirt = tint("shirt"), tShorts = tint("shorts");
      if (tSkin || tShirt || tShorts) for (let i = 0; i < d.length; i += 4) {
        const A = d[i + 3] / 255; if (A === 0) continue;
        const R = d[i] / 255, G = d[i + 1] / 255, B = d[i + 2] / 255, L = 0.2126 * R + 0.7152 * G + 0.0722 * B;
        let r = d[i], gg = d[i + 1], b = d[i + 2];
        const mix = (t, w) => { if (w <= 0) return; r += (clamp01(L * t[0]) * 255 - r) * w; gg += (clamp01(L * t[1]) * 255 - gg) * w; b += (clamp01(L * t[2]) * 255 - b) * w; };
        if (tSkin) mix(tSkin, clamp01(-10 * R + 20 * G - 10 * B - 0.8) * A);
        if (tShirt) mix(tShirt, clamp01(-6 * R - 3 * G + 6 * B - 0.4) * A);
        if (tShorts && ((i / 4 / W) | 0) % FH >= LOOK.shortsFrom) mix(tShorts, clamp01(14 * R - 14 * G - 0.45) * clamp01(-27.2 * R + 40 * G + 0.05) * A);
        d[i] = r; d[i + 1] = gg; d[i + 2] = b;
      }
      g.putImageData(img, 0, 0);
      const designs = XSVG[look.extra];
      if (designs) {
        let parts = "";
        for (let k = 0; k < FRAMES; k++) {
          const f = sourceFrame(k), view = XVIEW(f), x0 = (k % COLS) * FW, y0 = Math.floor(k / COLS) * FH;
          const art = designs.all || designs[view];
          if (!art) continue;
          let at;
          if (look.extra === EXTRA_SHADES) { const e = XEYES[f]; if (!e) continue; at = `translate(${x0 + e[0]} ${y0 + e[1]}) scale(${e[2] / 100})`; }
          else { const [hx, hy, hs, hr] = XHAT[f]; at = `translate(${x0 + hx} ${y0 + hy}) rotate(${hr}) scale(${hs / 100})`; }
          parts += `<g transform="${at}" ${XLINE}>${art}</g>`;
        }
        const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${c.width}" height="${c.height}">${parts}</svg>`;
        const im = new Image(); im.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);
        try { await im.decode(); g.drawImage(im, 0, 0); } catch {}
      }
      const t = new T.CanvasTexture(c); t.colorSpace = T.SRGBColorSpace;
      return t;
    }));
    return looks.get(key);
  }

  /// A Pepe in the room, feet at the origin. root.rotation.y is the way it faces; update() picks the frame.
  function makePepe(opts = {}) {
    let map = sheetTexture().clone(); // shares the image; its own frame offset
    map.repeat.set(1 / COLS, 1 / ROWS); sheetMaps.push(map);
    const root = new T.Group();
    const H = 2.05, Wd = H * FW / FH;
    const mat = new T.MeshBasicMaterial({ map, transparent: true, alphaTest: 0.4, side: T.DoubleSide });
    const card = new T.Mesh(new T.PlaneGeometry(Wd, H), mat);
    card.position.y = H / 2 - 0.04;
    root.add(card);
    const shadow = new T.Mesh(new T.CircleGeometry(0.45, 24), new T.MeshBasicMaterial({ color: 0x000000, transparent: true, opacity: 0.16, depthWrite: false }));
    shadow.rotation.x = -Math.PI / 2; shadow.position.y = 0.012; shadow.scale.y = 0.45; root.add(shadow);
    if (opts.you) {
      const ring = new T.Mesh(new T.RingGeometry(0.48, 0.58, 32), new T.MeshBasicMaterial({ color: 0x3ddc84, transparent: true, opacity: 0.9, depthWrite: false }));
      ring.rotation.x = -Math.PI / 2; ring.position.y = 0.015; ring.scale.y = 0.55; root.add(ring);
    }
    let phase = Math.random() * 4, idle = 3 + Math.random() * 6, act = null, actT = 0;
    const wp = new T.Vector3();
    const show = (i) => { map.offset.set((i % COLS) / COLS, 1 - (Math.floor(i / COLS) + 1) / ROWS); };
    return {
      root,
      /// Wear a look's texture (from lookTexture), or IMD's own Pepe again with null.
      wear(tex) {
        const m = (tex || sheetTexture()).clone();
        m.repeat.set(1 / COLS, 1 / ROWS); m.offset.copy(map.offset); m.needsUpdate = true;
        if (!tex) sheetMaps.push(m); // IMD's sheet may still be loading
        mat.map = m; mat.needsUpdate = true; map = m;
      },
      /// Arms up for a couple of seconds (when a trade or launch lands on the big screen).
      cheer() { act = "cheer"; actT = 2.2; },
      update(dt, speed) {
        phase += dt * (speed > 0.05 ? 5 + 5 * speed : 1);
        // which side of this Pepe the camera sees
        root.getWorldPosition(wp);
        const cam = activeCamera ? activeCamera.position : wp;
        let rel = Math.atan2(cam.x - wp.x, cam.z - wp.z) - root.rotation.y;
        rel = Math.atan2(Math.sin(rel), Math.cos(rel));
        card.rotation.y = rel; // the card always turns to the camera
        const a = Math.abs(rel), deg = (a * 180) / Math.PI;
        // the sheet's side views face right: mirror them when the Pepe faces the camera's left
        card.scale.x = rel > 0 && deg > 22.5 && deg < 157.5 ? -1 : 1;
        const moving = speed > 0.05;
        const cycle = (frames) => frames[Math.floor(phase) % frames.length];
        // little idle acts now and then: scratching the head, looking up
        if (!moving && !act) { idle -= dt; if (idle < 0) { act = Math.random() < 0.5 ? "scratch" : "look"; actT = 1.6; idle = 5 + Math.random() * 8; } }
        if (moving && act !== "cheer") act = null;
        if (act) { actT -= dt; if (actT < 0) act = null; }
        let f;
        if (act === "cheer" && deg > 112.5) f = cycle(F.cheer);
        else if (deg < 22.5) f = moving ? cycle(F.frontWalk) : act === "scratch" ? F.frontScratch : act === "look" ? F.frontUp : F.front;
        else if (deg < 67.5) f = moving ? cycle(F.frontQuarterWalk) : F.frontQuarter;
        else if (deg < 112.5) f = moving ? cycle(F.sideWalk) : F.side;
        else if (deg < 157.5) f = moving ? cycle(F.backQuarterWalk) : F.backQuarter;
        else f = moving ? cycle(F.backWalk) : act === "scratch" ? cycle(F.backScratch) : act === "look" ? F.backAlt : F.back;
        show(f);
        card.position.y = H / 2 - 0.04 + (moving ? Math.abs(Math.sin(phase * Math.PI)) * 0.03 : 0);
      },
    };
  }

  // ------------------------------------------------------------------ the crew and the dog (IMD's art, from imd.fun)
  // A one-row sprite sheet on a card; `show(i)` picks the frame.
  function spriteCard(url, frames, wUnits, hUnits) {
    const map = new T.TextureLoader().load(url); map.colorSpace = T.SRGBColorSpace; map.repeat.set(1 / frames, 1);
    const mesh = new T.Mesh(new T.PlaneGeometry(wUnits, hUnits), new T.MeshBasicMaterial({ map, transparent: true, alphaTest: 0.35, side: T.DoubleSide }));
    return { mesh, show(i) { map.offset.x = i / frames; } };
  }
  // the scale of imd.fun's scene: its Pepe is 86 px tall, ours 2.05 units
  const PX = 2.05 / 86;

  /// The man at the desk, in his chair, watching the big screen (seen from behind, as on imd.fun). Mostly still;
  /// now and then he looks around, stretches or scratches his head; he cheers when something lands on the big screen.
  function makeCrew() {
    const root = new T.Group();
    const man = spriteCard("/img/imd-crew.webp", 14, 85 * PX, 111.6 * PX);
    man.mesh.position.y = (746 - 707.6) * PX + (111.6 * PX) / 2; root.add(man.mesh);
    const chair = spriteCard("/img/imd-chair.webp", 1, 85 * PX, 64 * PX);
    chair.mesh.position.set(0, (64 * PX) / 2, 0.02); root.add(chair.mesh);
    const LOOK = [1, 2, 3, 4, 6, 7, 13];
    let f = 0, until = 4, act = null;
    man.show(0);
    return {
      root,
      cheer() { act = "cheer"; until = 0; },
      update(dt, t) {
        if (act === "cheer") { man.show(Math.floor(t * 3) % 2 ? 12 : 11); until -= dt; if (until < -2.2) { act = null; until = 2; man.show(0); } return; }
        until -= dt;
        if (until > 0) return;
        const r = Math.random();
        if (f !== 0) { f = 0; until = 4 + Math.random() * 8; }
        else if (r < 0.55) { f = LOOK[Math.floor(Math.random() * LOOK.length)]; until = 1 + Math.random() * 2; }
        else if (r < 0.7) { f = 5; until = 1.8; }
        else if (r < 0.85) { f = Math.random() < 0.5 ? 8 : 9; until = 1.6; }
        else { f = 10; until = 3 + Math.random() * 3; }
        man.show(f);
      },
    };
  }

  /// The dog: lies by the chair breathing; now and then sits up, gets up and trots around, and comes back.
  function makeDog(home) {
    const root = new T.Group();
    const dog = spriteCard("/img/imd-dog.webp", 23, 63 * PX, 45 * PX);
    dog.mesh.position.y = (45 * PX) / 2; root.add(dog.mesh);
    root.position.copy(home);
    const WALK = [6, 7, 8, 9, 10, 11, 12, 13];
    let state = "lie", until = 10 + Math.random() * 10, target = null, step = 0;
    const right = new T.Vector3(), vel = new T.Vector3();
    return {
      root,
      update(dt, t, camera) {
        until -= dt;
        dog.mesh.scale.set(1, 1, 1);
        if (state === "lie") {
          dog.show(0);
          const b = (Math.sin(t * (2 * Math.PI / 3.8)) + 1) / 2; dog.mesh.scale.set(1 + b * 0.012, 1 + b * 0.045, 1); // breathing
          if (until < 0) { state = "sit"; until = 2 + Math.random() * 4; }
        } else if (state === "sit") {
          dog.show(until > 1.5 ? 3 : until > 1.2 ? 2 : 1);
          if (until < 0) {
            if (Math.random() < 0.6) { state = "walk"; target = new T.Vector3(home.x + (Math.random() - 0.5) * 12, 0, 2.2 + Math.random() * 5); }
            else { state = "lie"; until = 12 + Math.random() * 14; }
          }
        } else if (state === "walk" || state === "home") {
          const to = state === "home" ? home : target;
          vel.subVectors(to, root.position); vel.y = 0;
          const d = vel.length();
          if (d < 0.08) {
            if (state === "home") { state = "lie"; until = 12 + Math.random() * 14; }
            else { state = "look"; until = 1.5 + Math.random() * 2.5; }
          } else {
            vel.multiplyScalar(Math.min(d, 1.6 * dt) / d); root.position.add(vel);
            step += dt * 10; dog.show(WALK[Math.floor(step) % WALK.length]);
            right.setFromMatrixColumn(camera.matrixWorld, 0);
            dog.mesh.scale.x = vel.dot(right) < 0 ? -1 : 1; // the sheet walks to the right
          }
        } else if (state === "look") {
          dog.show(until > 1 ? 22 : 19);
          if (until < 0) { state = "home"; }
        }
      },
    };
  }

  // ------------------------------------------------------------------ the hall
  let state = null;

  function mount(container, api) {
    unmount();
    const W = 60, D = 18, WALL_H = 15.5; // room width, depth, wall height (about seven Pepes, as on imd.fun)
    const el = document.createElement("div");
    el.className = "hall";
    el.innerHTML = `
      <canvas class="hall-c" aria-label="PepesFamily: walk your Pepe to a screen to launch, trade or claim"></canvas>
      <div class="hall-top"><b>PEPESFAMILY</b><span class="hall-live" id="hlive">reading the chain…</span><span class="hall-online" id="honline" hidden></span></div>
      <div class="hall-prompt" id="hprompt" hidden></div>
      <div class="hall-help" id="hhelp">WASD / arrows to walk · Shift to run · drag to look · E to use a screen</div>
      <div class="hall-btns"><button type="button" id="hwear" hidden title="Walk the Hall as one of your Pepes Family NFTs"></button><button type="button" id="hshot" title="Take a picture (C)">📸 Picture</button><button type="button" id="hhelpbtn" aria-label="Help">?</button></div>
      <div class="hall-joy" id="hjoy" hidden><div class="hall-knob" id="hknob"></div></div>
      <div class="hall-modal" id="hmodal" hidden></div>`;
    container.appendChild(el);
    const $ = (id) => el.querySelector("#" + id);
    const cv = el.querySelector("canvas");
    const renderer = new T.WebGLRenderer({ canvas: cv, antialias: true, preserveDrawingBuffer: true });
    renderer.setPixelRatio(Math.min(2, devicePixelRatio));
    renderer.outputColorSpace = T.SRGBColorSpace;
    const scene = new T.Scene();
    scene.background = new T.Color(0x0b0b0b);
    const camera = new T.PerspectiveCamera(55, 1, 0.1, 200);
    activeCamera = camera;
    scene.add(new T.HemisphereLight(0xffffff, 0x888888, 1.6));
    const sun = new T.DirectionalLight(0xffffff, 1.4); sun.position.set(6, 14, 12); scene.add(sun);

    // floor, wall, the black skirting band with its little labels (as in the IMD picture)
    const floor = new T.Mesh(new T.PlaneGeometry(W, D), new T.MeshBasicMaterial({ map: floorTexture() }));
    floor.rotation.x = -Math.PI / 2; floor.position.set(0, 0, D / 2); scene.add(floor);
    const wallFx = makeWall(4096, 976);
    const wall = new T.Mesh(new T.PlaneGeometry(W, WALL_H - 1.4), new T.MeshBasicMaterial({ map: wallFx.texture }));
    wall.position.set(0, 1.4 + (WALL_H - 1.4) / 2, 0); scene.add(wall);
    // the black band of desks under the wall, and the floor's edge, from IMD's own desk picture
    const bandMat = new T.MeshBasicMaterial({ color: 0x050505 }), edgeMat = new T.MeshBasicMaterial({ color: 0xf4f4f1, transparent: true });
    const band = new T.Mesh(new T.PlaneGeometry(W, 1.4), bandMat); band.position.set(0, 0.7, 0.01); scene.add(band);
    const edge = new T.Mesh(new T.PlaneGeometry(W, 1.12), edgeMat); edge.rotation.x = -Math.PI / 2; edge.position.set(0, 0.006, 0.56); scene.add(edge);
    const desk = new Image();
    desk.onload = () => {
      if (!state) return;
      // rows 12-173 are the desks, 174-303 the floor in front of them; both repeat at the desks' scale (1.4 tall)
      const tile = 1.4 * desk.naturalWidth / (174 - 12);
      const crop = (y0, y1) => { const c = canvas(desk.naturalWidth, y1 - y0); c.getContext("2d").drawImage(desk, 0, -y0); const t = tex(c); t.wrapS = T.RepeatWrapping; t.repeat.set(W / tile, 1); return t; };
      bandMat.map = crop(12, 174); bandMat.color.set(0xffffff); bandMat.needsUpdate = true;
      edgeMat.map = crop(174, 304); edgeMat.needsUpdate = true;
    };
    desk.src = "/img/imd-desk.webp";
    for (const s of [-1, 1]) { const side = new T.Mesh(new T.PlaneGeometry(D, WALL_H), new T.MeshBasicMaterial({ color: 0x0b0b0b })); side.rotation.y = -s * Math.PI / 2; side.position.set(s * W / 2, WALL_H / 2, D / 2); scene.add(side); }

    // screens: a canvas texture on a plane in front of the wall, with a dark frame
    const screens = [];
    function screen(w, h, x, y, cw, ch) {
      const c = canvas(cw, ch), t = tex(c);
      const frame = new T.Mesh(new T.PlaneGeometry(w + 0.3, h + 0.3), new T.MeshBasicMaterial({ color: 0x1a1a1a })); frame.position.set(x, y, 0.03); scene.add(frame);
      const mesh = new T.Mesh(new T.PlaneGeometry(w, h), new T.MeshBasicMaterial({ map: t })); mesh.position.set(x, y, 0.05); scene.add(mesh);
      const s = { c, g: c.getContext("2d"), t, mesh, x, y, w, h };
      screens.push(s);
      return s;
    }
    // the big screen: live launches and trades, IMD-terminal style
    const big = screen(15, 6.2, 0, 4.95, 1600, 660); // low in the middle of the wall, just above the desks
    // kiosks: standing terminals on the floor
    const kiosks = [];
    function kiosk(x, label, sub, hash) {
      const g = new T.Group(); g.position.set(x, 0, 1.6); scene.add(g);
      const base = new T.Mesh(new T.BoxGeometry(1.5, 1.1, 0.8), toon(0xdcdcd8)); base.position.y = 0.55; g.add(base);
      const ob = new T.Mesh(base.geometry, OUTLINE); ob.position.copy(base.position); ob.scale.setScalar(1.03); g.add(ob);
      const c = canvas(512, 300), cg = c.getContext("2d");
      cg.fillStyle = "#0a0f0a"; cg.fillRect(0, 0, 512, 300);
      cg.strokeStyle = GREEN; cg.lineWidth = 6; cg.strokeRect(8, 8, 496, 284);
      cg.fillStyle = GREEN; cg.font = "bold 64px monospace"; cg.textAlign = "center"; cg.fillText(label, 256, 130);
      cg.fillStyle = "#9fb09f"; cg.font = "26px monospace"; cg.fillText(sub, 256, 200);
      const sc = new T.Mesh(new T.PlaneGeometry(1.6, 0.95), new T.MeshBasicMaterial({ map: tex(c) })); sc.position.set(0, 1.62, 0.12); sc.rotation.x = -0.25; g.add(sc);
      const back = new T.Mesh(new T.BoxGeometry(1.75, 1.1, 0.12), toon(0x2a2a2a)); back.position.set(0, 1.6, 0.04); back.rotation.x = -0.25; g.add(back);
      const k = { x, z: 1.6, r: 2.3, g, label: `${label.toLowerCase().replace(/^./, (c) => c.toUpperCase())}: ${sub}`, go: () => api.go(hash) };
      kiosks.push(k);
      return k;
    }
    kiosk(-5, "MINT", "Pepes Family NFT", "#/mint");
    kiosk(-10, "LAUNCH", "launch a token", "#/create");
    kiosk(-15, "TOKENS", "browse every token", "#/tokens");
    kiosk(8, "REWARDS", "claim your IMD", "#/rewards");
    // the admin terminal only stands there for the launchpad's owner or fee recipient (see setAdmin)
    const admin = kiosk(14, "ADMIN", "collect fees", "#/admin");
    admin.g.visible = false; admin.off = true;

    // token booths: the top tokens by market cap, each on its own screen along the wall
    const booths = [];
    const BOOTH_X = [-24, -20.5, 20.5, 24, -24, 24];
    const BOOTH_Y = [4.8, 4.8, 4.8, 4.8, 8.6, 8.6];
    function drawBooth(s, t, img) {
      const g = s.g, w = s.c.width, h = s.c.height;
      g.fillStyle = "#0a0f0a"; g.fillRect(0, 0, w, h);
      g.strokeStyle = GREEN; g.lineWidth = 6; g.strokeRect(6, 6, w - 12, h - 12);
      if (img) { const S = 200; const k = Math.max(S / img.naturalWidth, S / img.naturalHeight); g.save(); g.beginPath(); g.rect(w / 2 - S / 2, 34, S, S); g.clip(); g.drawImage(img, w / 2 - img.naturalWidth * k / 2, 34 + S / 2 - img.naturalHeight * k / 2, img.naturalWidth * k, img.naturalHeight * k); g.restore(); }
      else { g.fillStyle = "#16301a"; g.fillRect(w / 2 - 100, 34, 200, 200); g.fillStyle = GREEN; g.font = "bold 90px monospace"; g.textAlign = "center"; g.fillText(t.symbol.slice(0, 2).toUpperCase(), w / 2, 166); }
      g.textAlign = "center"; g.fillStyle = "#ffffff"; g.font = "bold 46px monospace"; g.fillText("$" + t.symbol.slice(0, 10), w / 2, 296);
      g.fillStyle = GREEN; g.font = "34px monospace"; g.fillText("MC " + t.mc, w / 2, 344);
      s.t.needsUpdate = true;
    }

    // the locals: Pepes all over the floor watching the wall, clear of the man, his dog and the kiosks
    const crowd = [];
    const cr = rnd(91);
    const SPOTS = [[-11, 4.2], [-6.8, 4.6], [-8.6, 7.2], [-4.8, 6.4], [4.8, 4.4], [7.4, 6.6], [10.8, 4.2], [-13.8, 6.4], [13.4, 6.2], [-17.5, 4.8], [17.5, 5], [5.4, 8.6]];
    for (const [x, z] of SPOTS) {
      const p = makePepe();
      p.root.position.set(x + (cr() - 0.5) * 0.8, 0, z + (cr() - 0.5) * 0.8);
      p.root.rotation.y = Math.PI + (cr() - 0.5) * 0.6; // facing the wall
      scene.add(p.root);
      crowd.push({ p, turn: 3 + cr() * 8, base: p.root.rotation.y });
    }
    // the man at the desk and his dog, in front of the big screen (where imd.fun has them)
    const crew = makeCrew(); crew.root.position.set(1.1, 0, 2.4); scene.add(crew.root);
    const dog = makeDog(new T.Vector3(2.35, 0, 2.6)); scene.add(dog.root);
    const facing = (o) => { o.rotation.y = Math.atan2(camera.position.x - o.position.x, camera.position.z - o.position.z); }; // turn a card to the camera

    // you
    const player = makePepe({ you: true });
    scene.add(player.root);
    // beside the man, facing the wall (-z), as on imd.fun; a little apart from whoever came in before you
    let pos = new T.Vector3(-1.2 + (Math.random() - 0.5) * 3, 0, 3.4 + Math.random() * 1.6), heading = Math.PI;
    try { const s = JSON.parse(sessionStorage.getItem("hall:pos") || "null"); if (s) { pos.set(s.x, 0, s.z); heading = s.h; } } catch {}
    let camYaw = heading, camPitch = 0.06;

    // ---------------- your Pepes Family NFTs: walk the Hall as one of them
    let mine = [], wearer = "", wearing = null, wearGen = 0;
    const wearKey = () => "hall:wear:" + wearer.toLowerCase();
    const savedWear = () => { try { return localStorage.getItem(wearKey()); } catch { return null; } };
    function applyWear(id) {
      wearing = id;
      try { localStorage.setItem(wearKey(), String(id)); } catch {}
      const b = $("hwear");
      if (id === "default") { player.wear(null); b.textContent = "🐸 Wear your Pepe"; net.sendLook(); return; }
      const p = mine.find((x) => String(x.id) === String(id));
      if (!p) return;
      b.textContent = `🐸 #${p.id}`;
      net.sendLook();
      lookTexture(lookOf(p.spec)).then((t) => { if (state && wearing === id) player.wear(t); }).catch(() => {});
    }
    async function wearRefresh() {
      const gen = ++wearGen;
      let r = null;
      try { r = await api.myPepes?.(); } catch {}
      if (!state || gen !== wearGen) return;
      const b = $("hwear");
      mine = r?.list || []; wearer = r?.account || "";
      if (!mine.length) { b.hidden = true; wearing = null; player.wear(null); net.sendLook(); return; }
      b.hidden = false;
      if (!r.revealed) { b.textContent = `🐸 ${mine.length} sealed`; wearing = null; player.wear(null); b.dataset.sealed = "1"; net.sendLook(); return; }
      delete b.dataset.sealed;
      const saved = savedWear();
      applyWear(saved === "default" || mine.some((x) => String(x.id) === saved) ? saved : String(mine[0].id));
    }
    function wearPicker() {
      const m = $("hmodal"), b = $("hwear");
      if (b.dataset.sealed) {
        m.innerHTML = `<div class="hall-card" role="dialog" aria-modal="true" aria-label="Your Pepes"><b>Your ${mine.length} Pepe${mine.length > 1 ? "s are" : " is"} sealed</b>
          <p class="stat">Pepes Family NFTs show their looks at the reveal, after the mint. Then you can walk the Hall as one of yours: its skin, shirt, shorts and headphones, halo or shades.</p>
          <div class="hall-row"><button type="button" data-a="close">Close</button></div></div>`;
      } else {
        m.innerHTML = `<div class="hall-card" role="dialog" aria-modal="true" aria-label="Wear a Pepe"><b>Walk the Hall as…</b>
          <div class="hall-wear">${[{ id: "default" }, ...mine.slice(0, 120)].map((p) => `<button type="button" data-wear="${p.id}" class="${String(p.id) === String(wearing) ? "on" : ""}">${p.id === "default" ? `<span class="hw-img hw-def"></span>IMD's Pepe` : `<img data-id="${p.id}" alt="" />#${p.id}`}</button>`).join("")}</div>
          <div class="hall-row"><button type="button" data-a="close">Close</button></div></div>`;
        for (const p of mine.slice(0, 120)) api.pepeImage?.(p.id).then((src) => { const im = m.querySelector(`img[data-id="${p.id}"]`); if (im && src) im.src = src; }).catch(() => {});
      }
      m.hidden = false;
      m.querySelector('[data-a="close"]').focus();
      m.onclick = (e) => {
        const w = e.target.closest("[data-wear]")?.dataset.wear;
        if (w) { applyWear(w); m.hidden = true; m.innerHTML = ""; return; }
        if (e.target === m || e.target.closest('[data-a="close"]')) { m.hidden = true; m.innerHTML = ""; }
      };
      m.onkeydown = (e) => { if (e.key === "Escape") { m.hidden = true; m.innerHTML = ""; } };
    }
    // ---------------- multiplayer: the other players walking around (hall-server/, a Cloudflare Durable Object).
    // No nicknames and no chat: you join under a throwaway name only the server sees. Without a server set
    // (api.server) the Hall stays single player.
    const myLook = () => { const p = wearing && wearing !== "default" ? mine.find((x) => String(x.id) === String(wearing)) : null; return p ? lookOf(p.spec) : null; };
    const others = new Map(); // id -> { pepe, to: {x, z, h, s, a} }
    function addOther(p) {
      if (others.has(p.id)) return;
      const pepe = makePepe();
      pepe.root.position.set(p.x, 0, p.z); pepe.root.rotation.y = p.h;
      scene.add(pepe.root);
      const o = { pepe, to: { x: p.x, z: p.z, h: p.h, s: p.s || 0, a: p.a || "" } };
      others.set(p.id, o); setLook(o, p.look);
    }
    function setLook(o, look) {
      o.lookKey = look ? JSON.stringify(look) : "";
      const key = o.lookKey;
      if (!look) { o.pepe.wear(null); return; }
      lookTexture(look).then((t) => { if (state && o.lookKey === key) o.pepe.wear(t); }).catch(() => {});
    }
    function dropOther(id) {
      const o = others.get(id); if (!o) return;
      scene.remove(o.pepe.root);
      others.delete(id);
    }
    const joinName = "Pepe" + Math.floor(1000 + Math.random() * 9000); // the server wants a name; nobody sees it
    const net = (() => {
      let ws = null, joined = false, room = 1, backoff = 1500, retry = 0, last = { x: 1e9, z: 0, h: 0, s: -1 }, sentAt = 0, closed = false;
      const online = () => { const el = $("honline"); el.hidden = !joined; el.textContent = `● ${others.size + 1} online`; };
      const send = (m) => { if (ws && ws.readyState === 1) ws.send(JSON.stringify(m)); };
      function open() {
        if (closed || !api.server) return;
        try { ws = new WebSocket(api.server + "?room=" + room); } catch { return later(); }
        ws.onopen = () => { backoff = 1500; send({ t: "hello", name: joinName, look: myLook() }); };
        ws.onmessage = (e) => {
          let m; try { m = JSON.parse(e.data); } catch { return; }
          if (m.t === "welcome") {
            joined = true; room = m.room || room;
            for (const id of [...others.keys()]) dropOther(id);
            m.players.forEach(addOther);
            last.x = 1e9; online();
          } else if (m.t === "join") { addOther(m.p); online(); }
          else if (m.t === "leave") { dropOther(m.id); online(); }
          else if (m.t === "move") { const o = others.get(m.id); if (o) o.to = { x: m.x, z: m.z, h: m.h, s: m.s, a: m.a }; }
          else if (m.t === "look") { const o = others.get(m.id); if (o) setLook(o, m.look); }
          else if (m.t === "full") { room = room % 20 + 1; }
        };
        ws.onclose = () => {
          joined = false; ws = null;
          for (const id of [...others.keys()]) dropOther(id);
          online();
          later();
        };
      }
      function later() { if (closed || !state) return; clearTimeout(retry); retry = setTimeout(open, backoff); backoff = Math.min(30000, backoff * 1.7); }
      return {
        start() { if (api.server) open(); },
        sendLook() { if (joined) send({ t: "look", look: myLook() }); },
        /// Where you are, at most 5 times a second and only when something changed.
        tick(now, x, z, h, s) {
          if (!joined || now - sentAt < 0.2) return;
          h = Math.atan2(Math.sin(h), Math.cos(h));
          const q = s > 0.05 ? Math.round(s * 10) / 10 : 0;
          if (Math.abs(x - last.x) < 0.03 && Math.abs(z - last.z) < 0.03 && Math.abs(h - last.h) < 0.05 && q === last.s) return;
          sentAt = now; last = { x, z, h, s: q };
          send({ t: "move", x, z, h, s: q, a: "" });
        },
        stop() { closed = true; clearTimeout(retry); try { ws?.close(1000, "bye"); } catch {} },
      };
    })();

    // ---------------- input
    const keys = new Set();
    let paused = false, drawn = 0;
    const onKey = (e) => {
      if (paused || e.target.closest?.("input, textarea, select") || !$("hmodal").hidden) return;
      const k = e.key.toLowerCase();
      if (e.type === "keydown") {
        if (k === "e" || k === "enter") { near?.go(); return; }
        if (k === "c") { shot(); return; }
        if (["arrowup", "arrowdown", "arrowleft", "arrowright", " "].includes(k)) e.preventDefault();
        keys.add(k);
      } else keys.delete(k);
    };
    addEventListener("keydown", onKey); addEventListener("keyup", onKey);
    const onBlur = () => keys.clear(); addEventListener("blur", onBlur);
    // drag to look (mouse, or a finger outside the joystick)
    let drag = null;
    cv.addEventListener("pointerdown", (e) => { drag = { id: e.pointerId, x: e.clientX, y: e.clientY }; cv.setPointerCapture(e.pointerId); });
    cv.addEventListener("pointermove", (e) => {
      if (!drag || drag.id !== e.pointerId) return;
      camYaw -= (e.clientX - drag.x) * 0.006; camPitch = Math.max(-0.05, Math.min(0.7, camPitch + (e.clientY - drag.y) * 0.004));
      drag.x = e.clientX; drag.y = e.clientY;
    });
    const endDrag = (e) => { if (drag?.id === e.pointerId) drag = null; };
    cv.addEventListener("pointerup", endDrag); cv.addEventListener("pointercancel", endDrag);
    // touch joystick
    const joy = { x: 0, y: 0, id: null };
    if (matchMedia("(pointer: coarse)").matches) {
      $("hjoy").hidden = false; $("hhelp").textContent = "Left pad to walk · drag to look · tap the button to use a screen";
      const pad = $("hjoy"), knob = $("hknob");
      const move = (e) => { const r = pad.getBoundingClientRect(); let dx = (e.clientX - r.left - r.width / 2) / (r.width / 2), dy = (e.clientY - r.top - r.height / 2) / (r.height / 2); const l = Math.hypot(dx, dy); if (l > 1) { dx /= l; dy /= l; } joy.x = dx; joy.y = dy; knob.style.transform = `translate(${dx * 34}px, ${dy * 34}px)`; };
      pad.addEventListener("pointerdown", (e) => { joy.id = e.pointerId; pad.setPointerCapture(e.pointerId); move(e); e.stopPropagation(); });
      pad.addEventListener("pointermove", (e) => { if (joy.id === e.pointerId) move(e); });
      const end = () => { joy.id = null; joy.x = joy.y = 0; knob.style.transform = ""; };
      pad.addEventListener("pointerup", end); pad.addEventListener("pointercancel", end);
    }
    $("hprompt").onclick = () => near?.go();
    $("hshot").onclick = () => shot();
    $("hwear").onclick = () => wearPicker();
    $("hhelpbtn").onclick = () => { const h = $("hhelp"); h.hidden = !h.hidden; };
    setTimeout(() => { if (state) $("hhelp").hidden = true; }, 9000); // the ? button brings it back

    // ---------------- picture: the current frame, with a caption strip
    function shot() {
      renderer.render(scene, camera);
      const src = cv, c = canvas(1200, 675), g = c.getContext("2d");
      const k = Math.max(1200 / src.width, 675 / src.height);
      g.drawImage(src, (1200 - src.width * k) / 2, (675 - src.height * k) / 2, src.width * k, src.height * k);
      g.fillStyle = "rgba(0,0,0,.72)"; g.fillRect(0, 627, 1200, 48);
      g.fillStyle = GREEN; g.font = "600 20px monospace"; g.fillText("PEPESFAMILY HALL", 20, 658);
      g.fillStyle = "#fff"; g.textAlign = "right"; g.fillText("pepesimd.fun", 1180, 658);
      const url = c.toDataURL("image/png");
      const m = $("hmodal");
      m.hidden = false;
      m.innerHTML = `<div class="hall-card" role="dialog" aria-modal="true" aria-label="Your picture">
        <img src="${url}" alt="Picture from the PepesFamily Hall">
        <div class="hall-row">
          <button type="button" class="primary" data-a="launch">Use as a token image</button>
          <button type="button" data-a="dl">Download</button>
          <button type="button" data-a="x">Post on X</button>
          <button type="button" data-a="close">Close</button>
        </div>
        <p class="stat">Pictures stay on your device until you use one: "Use as a token image" uploads it to IPFS on the Launch page.</p></div>`;
      m.querySelector('[data-a="close"]').focus();
      m.onclick = (e) => {
        const a = e.target.closest("[data-a]")?.dataset.a;
        if (e.target === m || a === "close") { m.hidden = true; m.innerHTML = ""; return; }
        if (a === "dl") { const l = document.createElement("a"); l.href = url; l.download = "pepesfamily-hall.png"; l.click(); }
        if (a === "x") window.open("https://x.com/intent/tweet?text=" + encodeURIComponent("Hanging out in the PepesFamily Hall 🐸\nhttps://pepesimd.fun/"), "_blank", "noopener,noreferrer");
        if (a === "launch") { api.useAsLaunchImage(url); }
      };
      m.onkeydown = (e) => { if (e.key === "Escape") { m.hidden = true; m.innerHTML = ""; } };
    }

    // ---------------- live data on the screens
    let feedLines = [], stats = "", seenKey = "";
    function drawBig() {
      const g = big.g, w = big.c.width, h = big.c.height;
      g.fillStyle = "#050605"; g.fillRect(0, 0, w, h);
      g.strokeStyle = "#1d261d"; g.lineWidth = 2; g.beginPath(); g.moveTo(0, 56); g.lineTo(w, 56); g.stroke();
      g.font = "26px monospace"; g.textAlign = "left";
      g.fillStyle = GREEN; g.fillText("#", 24, 38);
      g.fillStyle = "#cfd8cf"; g.fillText(stats || "reading the chain…", 54, 38);
      g.fillStyle = "#6f7d6f"; g.textAlign = "right"; g.fillText("★ launch  ★ buy  ★ sell", w - 24, 38); g.textAlign = "left";
      const rows = feedLines.slice(-13);
      rows.forEach((l, i) => {
        const y = 96 + i * 38;
        g.fillStyle = "#3a4a3a"; g.fillText("└", 24, y);
        g.fillStyle = "#8e9b8e"; g.fillText(l.time, 56, y);
        g.fillStyle = l.kind === "buy" ? GREEN : l.kind === "sell" ? "#ff7b72" : "#ffffff"; g.fillText(l.kind.padEnd(7), 160, y);
        g.fillStyle = "#e6ede6"; g.fillText(l.sym.slice(0, 14).padEnd(15), 300, y);
        g.fillStyle = "#8e9b8e"; g.fillText(l.detail.slice(0, 48), 560, y);
      });
      g.strokeStyle = "#1f5e35"; g.strokeRect(24, h - 60, w - 48, 40);
      g.fillStyle = GREEN; g.fillText("> walk to a screen and press E", 40, h - 32);
      big.t.needsUpdate = true;
    }
    drawBig();
    async function refresh() {
      try {
        const d = await api.data();
        if (!state) return;
        const lastKey = d.events.length ? JSON.stringify(d.events[d.events.length - 1]) : "";
        if (seenKey && lastKey !== seenKey) { player.cheer(); crowd.forEach((c, i) => setTimeout(() => c.p.cheer(), i * 120)); crew.cheer(); wallFx.pulse(t0); } // something new: everyone cheers
        seenKey = lastKey;
        feedLines = d.events; stats = d.stats;
        $("hlive").textContent = d.stats;
        drawBig();
        // booths for the top tokens (built once, then redrawn)
        d.top.slice(0, BOOTH_X.length).forEach((t, i) => {
          let b = booths[i];
          if (!b) { b = { s: screen(3, 3.2, BOOTH_X[i], BOOTH_Y[i], 360, 384) }; booths.push(b); }
          b.t = t;
          b.target = { x: BOOTH_X[i], z: 1.2, r: 2.2, label: `Trade $${t.symbol}`, go: () => api.go("#/t/" + t.token) };
          drawBooth(b.s, t, null);
          if (t.image && b.img !== t.image) {
            b.img = t.image;
            const im = new Image(); im.crossOrigin = "anonymous"; im.referrerPolicy = "no-referrer";
            im.onload = () => { if (state && b.t === t) drawBooth(b.s, t, im); };
            im.src = t.image;
          }
        });
      } catch (e) { $("hlive").textContent = "couldn't read the chain"; }
    }
    refresh();
    const dataTimer = setInterval(refresh, 20000);

    // ---------------- loop
    let near = null, last = performance.now(), raf = 0, t0 = 0, wallAt = 0;
    const coarse = matchMedia("(pointer: coarse)").matches, still = matchMedia("(prefers-reduced-motion: reduce)").matches;
    const tmp = new T.Vector3();
    function resize() {
      const w = el.clientWidth, h = el.clientHeight;
      renderer.setSize(w, h, false); camera.aspect = w / h; camera.fov = w < h ? 72 : 55; camera.updateProjectionMatrix(); // portrait phones need a wider view
    }
    const ro = new ResizeObserver(resize); ro.observe(el); resize();
    function frame(now) {
      raf = requestAnimationFrame(frame);
      if (paused && drawn > 30) { last = now; return; } // a window is open over the Hall: hold still (once it has been drawn)
      const dt = Math.min(0.05, (now - last) / 1000); last = now; t0 += dt;
      // movement, relative to where the camera looks
      let fx = 0, fz = 0;
      if (keys.has("w") || keys.has("arrowup")) fz -= 1;
      if (keys.has("s") || keys.has("arrowdown")) fz += 1;
      if (keys.has("a") || keys.has("arrowleft")) fx -= 1;
      if (keys.has("d") || keys.has("arrowright")) fx += 1;
      fx += joy.x; fz += joy.y;
      const len = Math.hypot(fx, fz);
      let speed = 0;
      if (len > 0.05) {
        const run = keys.has("shift") ? 2 : 1;
        // camYaw is where the camera looks: forward = (sin, cos), right = (-cos, sin)
        const sin = Math.sin(camYaw), cos = Math.cos(camYaw), n = Math.max(1, len);
        const dx = (sin * -fz - cos * fx) / n, dz = (cos * -fz + sin * fx) / n;
        speed = Math.min(1, len) * run;
        pos.x = Math.max(-W / 2 + 1, Math.min(W / 2 - 1, pos.x + dx * 4.2 * speed * dt));
        pos.z = Math.max(1, Math.min(D - 1, pos.z + dz * 4.2 * speed * dt));
        // kiosks are solid
        for (const k of kiosks) { if (k.off) continue; const ox = pos.x - k.x, oz = pos.z - k.z; if (Math.abs(ox) < 1.1 && Math.abs(oz) < 0.75) pos.z = k.z + 0.75 * Math.sign(oz || 1); }
        // so are the man in his chair and the dog
        for (const [o, rad] of [[crew.root.position, 1.0], [dog.root.position, 0.55]]) {
          const ox = pos.x - o.x, oz = pos.z - o.z, d = Math.hypot(ox, oz);
          if (d < rad && d > 1e-4) { pos.x = o.x + (ox / d) * rad; pos.z = o.z + (oz / d) * rad; }
        }
        const want = Math.atan2(dx, dz);
        let d = want - heading; d = Math.atan2(Math.sin(d), Math.cos(d)); heading += d * Math.min(1, dt * 10);
        // the camera swings in behind you as you walk away from it
        let cd = heading - camYaw; cd = Math.atan2(Math.sin(cd), Math.cos(cd));
        if (!drag && fz < -0.3) camYaw += cd * Math.min(1, dt * 1.5); // only when walking forward: strafing keeps the view
      }
      player.root.position.copy(pos); player.root.rotation.y = heading;
      player.update(dt, Math.min(1, speed));
      for (const c of crowd) {
        c.turn -= dt;
        if (c.turn < 0) { c.p.root.rotation.y = c.base + (Math.random() - 0.5) * 1.2; c.turn = 3 + Math.random() * 8; }
        c.p.update(dt, 0);
      }
      crew.update(dt, t0); dog.update(dt, t0, camera);
      // the wall's moving parts, a few times a second (once a second on phones; never with reduced motion)
      if (!still && t0 - wallAt > (coarse ? 1 : 0.33)) { wallAt = t0; wallFx.tick(t0); }
      // camera: behind and above
      // far enough back to see the whole wall, as on imd.fun (your Pepe small at the bottom of the picture)
      const dist = 12, flat = dist * Math.cos(camPitch);
      camera.position.set(pos.x - Math.sin(camYaw) * flat, 2.4 + dist * Math.sin(camPitch), Math.min(D + 6, pos.z - Math.cos(camYaw) * flat));
      // look past your Pepe and up at the big screen
      camera.lookAt(tmp.set(pos.x + Math.sin(camYaw) * 4, 4.6, pos.z + Math.cos(camYaw) * 4));
      facing(crew.root); facing(dog.root);
      // the other players glide to where they are
      for (const o of others.values()) {
        const r = o.pepe.root, k = Math.min(1, dt * 8);
        const far = Math.hypot(o.to.x - r.position.x, o.to.z - r.position.z);
        if (far > 6) r.position.set(o.to.x, 0, o.to.z); else { r.position.x += (o.to.x - r.position.x) * k; r.position.z += (o.to.z - r.position.z) * k; }
        let dh = o.to.h - r.rotation.y; dh = Math.atan2(Math.sin(dh), Math.cos(dh)); r.rotation.y += dh * k;
        o.pepe.update(dt, Math.min(1, Math.max(o.to.s, far > 0.15 ? 0.6 : 0)));
      }
      net.tick(t0, Math.round(pos.x * 100) / 100, Math.round(pos.z * 100) / 100, heading, speed);
      // what is within reach
      const targets = [...kiosks.filter((k) => !k.off), ...booths.map((b) => b.target).filter(Boolean), { x: 0, z: 1.2, r: 4, label: "The big screen: every launch and trade", go: () => api.go("#/tokens") }];
      let best = null, bd = Infinity;
      for (const tg of targets) { const d = Math.hypot(pos.x - tg.x, pos.z - tg.z); if (d < tg.r && d < bd) { best = tg; bd = d; } }
      if (best !== near) {
        near = best;
        const p = $("hprompt");
        p.hidden = !near;
        if (near) p.textContent = `${matchMedia("(pointer: coarse)").matches ? "Tap" : "E"} · ${near.label}`;
      }
      renderer.render(scene, camera); drawn++;
      if ((t0 % 2) < dt) { try { sessionStorage.setItem("hall:pos", JSON.stringify({ x: pos.x, z: pos.z, h: heading })); } catch {} }
    }
    raf = requestAnimationFrame(frame);

    state = {
      el,
      pause(p) { paused = !!p; keys.clear(); joy.x = joy.y = 0; drag = null; drawn = Math.min(drawn, 25); }, // a few more frames: the textures that just loaded
      setAdmin(on) { admin.off = !on; admin.g.visible = !!on; },
      wearRefresh,
      stop() {
        cancelAnimationFrame(raf); clearInterval(dataTimer); ro.disconnect(); net.stop();
        removeEventListener("keydown", onKey); removeEventListener("keyup", onKey); removeEventListener("blur", onBlur);
        try { sessionStorage.setItem("hall:pos", JSON.stringify({ x: pos.x, z: pos.z, h: heading })); } catch {}
        renderer.dispose();
        scene.traverse((o) => { o.geometry?.dispose?.(); const mt = o.material; (Array.isArray(mt) ? mt : [mt]).forEach((x) => { x?.map?.dispose?.(); x?.dispose?.(); }); });
        el.remove();
      },
    };
    wearRefresh(); // a wallet already connected: put on its Pepe
    net.start(); // multiplayer, when a Hall server is set
  }

  /// Holds the Hall still (no input, no drawing) while a window is open over it, and lets it go again.
  function pause(p) { state?.pause(p); }
  /// Shows or hides the admin terminal.
  function setAdmin(on) { state?.setAdmin(on); }
  /// The wallet (or what it holds) changed: look again for its Pepes Family NFTs.
  function walletChanged() { state?.wearRefresh(); }

  function unmount() {
    if (!state) return;
    const s = state; state = null; s.stop();
  }

  window.Hall = { mount, unmount, pause, setAdmin, walletChanged };
})();
