// PepesFamily Hall: a 3D room in the style of the IMD swarm wall, where your Pepe walks up to screens to launch,
// trade and claim. Phase 1 is single player: the other Pepes are locals watching the big screen.
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

  // ------------------------------------------------------------------ the panel wall (drawn once, like the IMD wall)
  function wallTexture() {
    const W = 2048, H = 640, c = canvas(W, H), g = c.getContext("2d"), r = rnd(4663);
    g.fillStyle = "#e9e9e6"; g.fillRect(0, 0, W, H);
    const cell = 32;
    // big modules first, then fill the gaps with small ones
    const used = new Set(), key = (x, y) => x + "," + y;
    const free = (x, y, w, h) => { for (let i = 0; i < w; i++) for (let j = 0; j < h; j++) if (used.has(key(x + i, y + j)) || x + i >= W / cell || y + j >= H / cell) return false; return true; };
    const take = (x, y, w, h) => { for (let i = 0; i < w; i++) for (let j = 0; j < h; j++) used.add(key(x + i, y + j)); };
    const mods = [];
    for (let n = 0; n < 140; n++) {
      const w = 2 + Math.floor(r() * 6), h = 2 + Math.floor(r() * 4);
      const x = Math.floor(r() * (W / cell - w)), y = Math.floor(r() * (H / cell - h));
      if (free(x, y, w, h)) { take(x, y, w, h); mods.push([x, y, w, h]); }
    }
    for (let x = 0; x < W / cell; x++) for (let y = 0; y < H / cell; y++) if (!used.has(key(x, y))) mods.push([x, y, 1, 1]);
    for (const [x, y, w, h] of mods) {
      const px = x * cell + 2, py = y * cell + 2, pw = w * cell - 4, ph = h * cell - 4;
      g.fillStyle = r() < 0.15 ? PANEL2 : PANEL; g.fillRect(px, py, pw, ph);
      g.strokeStyle = INK; g.lineWidth = 2; g.strokeRect(px, py, pw, ph);
      const kind = w * h === 1 ? Math.floor(r() * 4) : 4 + Math.floor(r() * 5);
      g.lineWidth = 2;
      if (kind === 0) { g.beginPath(); g.arc(px + pw / 2, py + ph / 2, pw * 0.32, 0, 7); g.stroke(); }
      else if (kind === 1) { g.fillStyle = INK; g.fillRect(px + pw * 0.3, py + ph * 0.3, pw * 0.4, ph * 0.4); }
      else if (kind === 2) { g.beginPath(); g.arc(px + pw / 2, py + ph / 2, pw * 0.3, 0, 7); g.stroke(); g.beginPath(); g.moveTo(px + pw / 2, py + ph / 2); g.lineTo(px + pw * 0.75, py + ph * 0.3); g.stroke(); }
      else if (kind === 3) { g.fillStyle = r() < 0.3 ? GREEN : INK; g.beginPath(); g.arc(px + pw / 2, py + ph / 2, 3, 0, 7); g.fill(); }
      else if (kind === 4 || kind === 5) {
        // a screen: black or green-framed, with a wave or bars
        g.fillStyle = "#101410"; g.fillRect(px + 6, py + 6, pw - 12, ph - 12);
        g.strokeStyle = GREEN; g.lineWidth = 2; g.beginPath();
        if (kind === 4) { for (let i = 0; i <= 20; i++) { const xx = px + 8 + (pw - 16) * i / 20, yy = py + ph / 2 + Math.sin(i * 0.9 + r() * 6) * (ph / 4 - 4); i ? g.lineTo(xx, yy) : g.moveTo(xx, yy); } g.stroke(); }
        else { g.fillStyle = GREEN; const bars = Math.floor(pw / 9); for (let i = 0; i < bars; i++) { const bh = (ph - 20) * (0.2 + r() * 0.8); g.fillRect(px + 9 + i * 8, py + ph - 10 - bh, 5, bh); } }
      } else if (kind === 6) {
        // rows of knobs
        const n = Math.max(2, Math.floor(pw / 26)), rows = Math.max(1, Math.floor(ph / 30));
        for (let j = 0; j < rows; j++) for (let i = 0; i < n; i++) { g.beginPath(); g.arc(px + 14 + i * (pw - 28) / Math.max(1, n - 1), py + 16 + j * 28, 7, 0, 7); g.stroke(); }
      } else if (kind === 7) {
        // digital readout
        g.fillStyle = "#101410"; g.fillRect(px + 6, py + ph / 2 - 14, pw - 12, 28);
        g.fillStyle = GREEN; g.font = "bold 20px monospace"; g.fillText(String(Math.floor(r() * 99999)).padStart(5, "0"), px + 10, py + ph / 2 + 7);
      } else {
        // sliders
        const n = Math.max(2, Math.floor(pw / 18));
        for (let i = 0; i < n; i++) { const xx = px + 10 + i * 16; g.beginPath(); g.moveTo(xx, py + 8); g.lineTo(xx, py + ph - 8); g.stroke(); g.fillStyle = INK; g.fillRect(xx - 5, py + 8 + r() * (ph - 24), 10, 8); }
      }
    }
    return tex(c);
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
  // Pepes Earn IMD palettes (PepesEarnRenderer), so your NFT Pepe looks the same here.
  const SKINS = [0x64a84d, 0x8aa86b, 0x7fd3e8, 0xf29bb3, 0x3a3a3a, 0xe6b422];
  const SHIRTS = [0x2c60cc, 0xd23c3c, 0x1f1f1f, 0xececec, 0x2e9d57, 0x7a4fd6, 0xf28c28, 0x8a8f98];
  const SHORTS = [0xb08d5c, 0x6b6b6b, 0x3d5a80, 0x2a2a2a, 0xa83232];
  const HATS = ["none", "cap", "beanie", "headphones", "party", "halo", "crown"];
  const CLASSIC = { skin: 0x64a84d, shirt: 0x2c60cc, shorts: 0xb08d5c, hat: "none", acc: 0 };

  /// Pepes Earn IMD #id's look, derived exactly as the on-chain renderer does (keccak of "pepes-earn-imd", id).
  function earnLook(id) {
    const r = BigInt(window.ethers.solidityPackedKeccak256(["string", "uint256"], ["pepes-earn-imd", BigInt(id)]));
    const roll = (i) => Number((r >> BigInt(i * 16)) & 0xffffn);
    const pick = (x, w) => { const tot = w.reduce((a, b) => a + b, 0); let v = Math.floor((x * tot) / 65536); for (let i = 0; i < w.length; i++) { if (v < w[i]) return i; v -= w[i]; } return w.length - 1; };
    let skin = pick(roll(0), [80, 7, 5, 4, 3, 1]);
    const shirt = Math.floor((roll(1) * 8) / 65536), shorts = Math.floor((roll(2) * 5) / 65536);
    let head = pick(roll(4), [30, 20, 15, 15, 8, 7, 5]), acc = pick(roll(5), [40, 25, 15, 12, 8]);
    if (id === 1) [skin, head, acc] = [5, 6, 4]; else if (id === 777) skin = 5;
    return { skin: SKINS[skin], shirt: acc === 4 ? 0xc62828 : SHIRTS[shirt], shorts: SHORTS[shorts], hat: HATS[head], acc, cape: acc === 4 ? (skin === 5 ? 0x6a1b9a : 0xc62828) : 0 };
  }

  /// A Pepe from simple shapes, cel-shaded and outlined; faces +z, feet at the origin, about 1.7 tall.
  function makePepe(look) {
    const root = new T.Group(), body = new T.Group();
    root.add(body);
    const mats = new Map();
    const m = (c, extra) => { const k = c + JSON.stringify(extra || {}); if (!mats.has(k)) mats.set(k, toon(c, extra)); return mats.get(k); };
    const add = (parent, geo, color, x = 0, y = 0, z = 0, extra, outline = true) => {
      const mesh = new T.Mesh(geo, m(color, extra));
      mesh.position.set(x, y, z);
      parent.add(mesh);
      if (outline) { const o = new T.Mesh(geo, OUTLINE); o.position.copy(mesh.position); o.scale.setScalar(1.06); parent.add(o); mesh.userData.outline = o; }
      return mesh;
    };
    const legs = [];
    for (const s of [-1, 1]) {
      const hip = new T.Group(); hip.position.set(s * 0.11, 0.62, 0); body.add(hip);
      add(hip, new T.CylinderGeometry(0.06, 0.055, 0.56, 8), look.skin, 0, -0.3, 0);
      const foot = add(hip, new T.SphereGeometry(0.09, 10, 8), look.skin, 0, -0.58, 0.05); foot.scale.set(1, 0.5, 1.4);
      legs.push(hip);
    }
    const shorts = add(body, new T.CylinderGeometry(0.27, 0.3, 0.3, 14), look.shorts, 0, 0.72, 0); shorts.scale.z = 0.8;
    const torso = add(body, new T.CylinderGeometry(0.25, 0.3, 0.5, 14), look.shirt, 0, 1.08, 0); torso.scale.z = 0.8;
    const arms = [];
    for (const s of [-1, 1]) {
      const sh = new T.Group(); sh.position.set(s * 0.3, 1.26, 0); sh.rotation.z = s * 0.12; body.add(sh);
      add(sh, new T.CylinderGeometry(0.075, 0.07, 0.2, 8), look.shirt, 0, -0.08, 0);
      add(sh, new T.CylinderGeometry(0.05, 0.045, 0.32, 8), look.skin, 0, -0.32, 0);
      add(sh, new T.SphereGeometry(0.06, 8, 6), look.skin, 0, -0.5, 0);
      arms.push(sh);
    }
    if (look.cape) add(body, new T.CylinderGeometry(0.24, 0.4, 0.8, 16, 1, true, Math.PI * 0.55, Math.PI * 0.9), look.cape, 0, 0.95, 0.06, { side: T.DoubleSide }, false);
    if (look.acc === 1) add(body, new T.BoxGeometry(0.34, 0.36, 0.16), 0xe0a526, 0, 1.08, -0.3);
    if (look.acc === 2) { const b = add(body, new T.SphereGeometry(0.15, 10, 8), 0xf5c542, 0.36, 0.75, 0.05); b.scale.y = 1.15; }

    // head: a wide frog skull, two bulging eyes with heavy lids, long lips
    const head = new T.Group(); head.position.set(0, 1.38, 0); body.add(head);
    const skull = add(head, new T.SphereGeometry(0.25, 22, 16), look.skin, 0, 0.12, 0); skull.scale.set(1.3, 0.82, 1.05);
    const eyes = [];
    for (const s of [-1, 1]) {
      const bulge = add(head, new T.SphereGeometry(0.13, 16, 12), look.skin, s * 0.13, 0.25, 0.07); bulge.scale.set(1, 0.95, 0.9);
      const eye = new T.Group(); eye.position.set(s * 0.13, 0.25, 0.13); head.add(eye);
      const ball = add(eye, new T.SphereGeometry(0.1, 14, 10), 0xffffff, 0, 0, 0, undefined, false); ball.scale.set(1, 0.85, 0.75);
      add(eye, new T.SphereGeometry(0.04, 10, 8), 0x161616, -s * 0.015, -0.015, 0.065, undefined, false);
      eyes.push(eye);
      const lid = add(head, new T.SphereGeometry(0.108, 16, 10, 0, Math.PI * 2, 0, Math.PI * 0.42), look.skin, s * 0.13, 0.258, 0.135, undefined, false);
      lid.rotation.x = 0.55; lid.scale.set(1.04, 1, 0.82);
    }
    for (const [y, rad, color] of [[0.05, 0.25, 0xa9503f], [0.02, 0.235, 0x8a3c30]]) {
      const g = new T.Group(); g.position.set(0, y, 0); g.rotation.y = -Math.PI * 0.2; g.scale.set(1.12, 1, 1); head.add(g);
      const lip = new T.Mesh(new T.TorusGeometry(rad, 0.026, 6, 24, Math.PI * 0.6), m(color)); lip.rotation.x = Math.PI / 2; g.add(lip);
    }
    const hat = (h) => {
      if (h === "cap") { const c = add(head, new T.SphereGeometry(0.27, 18, 10, 0, Math.PI * 2, 0, Math.PI * 0.42), 0x1d4ed8, 0, 0.22, -0.06); c.scale.set(1.2, 0.9, 1.05); const b = add(head, new T.CylinderGeometry(0.16, 0.16, 0.02, 16), 0x1d4ed8, 0, 0.32, 0.17); b.scale.z = 0.8; }
      else if (h === "beanie") { const c = add(head, new T.SphereGeometry(0.28, 18, 10, 0, Math.PI * 2, 0, Math.PI * 0.45), 0xd97706, 0, 0.22, -0.06); c.scale.set(1.2, 1, 1.05); }
      else if (h === "headphones") { const b = add(head, new T.TorusGeometry(0.3, 0.025, 6, 20, Math.PI), 0x111111, 0, 0.16, -0.04); b.scale.x = 1.15; for (const s of [-1, 1]) { const c = add(head, new T.CylinderGeometry(0.08, 0.08, 0.06, 14), 0xe11d48, s * 0.34, 0.14, -0.04); c.rotation.z = Math.PI / 2; } }
      else if (h === "party") { add(head, new T.ConeGeometry(0.12, 0.36, 14), 0x8b5cf6, 0, 0.5, -0.06); }
      else if (h === "halo") { const r = add(head, new T.TorusGeometry(0.2, 0.022, 6, 24), 0xfde047, 0, 0.58, -0.04, { emissive: 0x4a3b00 }, false); r.rotation.x = Math.PI / 2; }
      else if (h === "crown") { add(head, new T.CylinderGeometry(0.17, 0.17, 0.1, 16, 1, true), 0xf5c542, 0, 0.38, -0.04, { emissive: 0x3a2800, side: T.DoubleSide }); for (let i = 0; i < 6; i++) { const a = (i / 6) * Math.PI * 2; add(head, new T.ConeGeometry(0.035, 0.1, 6), 0xf5c542, Math.sin(a) * 0.17, 0.47, Math.cos(a) * 0.17 - 0.04, undefined, false); } }
    };
    hat(look.hat);

    let phase = Math.random() * 6, blink = 2 + Math.random() * 3;
    return {
      root, head,
      update(dt, speed, t) {
        phase += dt * (3 + 8 * speed);
        const s = Math.sin(phase);
        legs[0].rotation.x = s * 0.7 * speed; legs[1].rotation.x = -s * 0.7 * speed;
        arms[0].rotation.x = -s * 0.6 * speed; arms[1].rotation.x = s * 0.6 * speed;
        body.position.y = Math.abs(Math.cos(phase)) * 0.05 * speed + Math.sin(t * 2.1 + phase) * 0.006 * (1 - speed);
        blink -= dt;
        for (const e of eyes) e.scale.y = blink < 0.12 ? 0.15 : 1;
        if (blink < 0) blink = 2 + Math.random() * 4;
      },
    };
  }

  // ------------------------------------------------------------------ the hall
  let state = null;

  function mount(container, api) {
    unmount();
    const W = 60, D = 18, WALL_H = 13; // room width, depth, wall height
    const el = document.createElement("div");
    el.className = "hall";
    el.innerHTML = `
      <canvas class="hall-c" aria-label="PepesFamily Hall: walk your Pepe to a screen to launch, trade or claim"></canvas>
      <div class="hall-top"><b>PEPESFAMILY HALL</b><span class="hall-live" id="hlive">reading the chain…</span></div>
      <div class="hall-prompt" id="hprompt" hidden></div>
      <div class="hall-help" id="hhelp">WASD / arrows to walk · Shift to run · drag to look · E to use a screen</div>
      <div class="hall-btns"><button type="button" id="hshot" title="Take a picture (C)">📸 Picture</button><button type="button" id="hhelpbtn" aria-label="Help">?</button></div>
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
    scene.add(new T.HemisphereLight(0xffffff, 0x888888, 1.6));
    const sun = new T.DirectionalLight(0xffffff, 1.4); sun.position.set(6, 14, 12); scene.add(sun);

    // floor, wall, the black skirting band with its little labels (as in the IMD picture)
    const floor = new T.Mesh(new T.PlaneGeometry(W, D), new T.MeshBasicMaterial({ map: floorTexture() }));
    floor.rotation.x = -Math.PI / 2; floor.position.set(0, 0, D / 2); scene.add(floor);
    const wt = wallTexture(); wt.wrapS = T.RepeatWrapping; wt.repeat.set(2, 1);
    const wall = new T.Mesh(new T.PlaneGeometry(W, WALL_H - 1.4), new T.MeshBasicMaterial({ map: wt }));
    wall.position.set(0, 1.4 + (WALL_H - 1.4) / 2, 0); scene.add(wall);
    const band = new T.Mesh(new T.PlaneGeometry(W, 1.4), new T.MeshBasicMaterial({ color: 0x050505 })); band.position.set(0, 0.7, 0.01); scene.add(band);
    for (let x = -27; x <= 27; x += 6) { const tick = new T.Mesh(new T.PlaneGeometry(0.08, 0.22), new T.MeshBasicMaterial({ color: 0xdddddd })); tick.position.set(x, 0.8, 0.02); scene.add(tick); }
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
    const big = screen(20, 7, 0, 6.6, 1600, 560);
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
      kiosks.push({ x, z: 1.6, r: 2.3, label: `${label.toLowerCase().replace(/^./, (c) => c.toUpperCase())}: ${sub}`, go: () => api.go(hash) });
    }
    kiosk(-16, "LAUNCH", "launch a token", "#/create");
    kiosk(-10.5, "TOKENS", "browse every token", "#/");
    kiosk(10.5, "REWARDS", "claim your IMD", "#/rewards");
    kiosk(16, "NFT", "Pepes Earn IMD", "#/nft");

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

    // the locals: Pepes watching the big screen
    const crowd = [];
    const cr = rnd(91);
    for (let i = 0; i < 7; i++) {
      const look = { skin: cr() < 0.85 ? 0x64a84d : SKINS[1 + Math.floor(cr() * 3)], shirt: cr() < 0.6 ? 0x2c60cc : SHIRTS[Math.floor(cr() * SHIRTS.length)], shorts: SHORTS[Math.floor(cr() * 3)], hat: cr() < 0.3 ? HATS[1 + Math.floor(cr() * 3)] : "none", acc: 0 };
      const p = makePepe(look);
      p.root.position.set(-7 + i * 2.3 + (cr() - 0.5), 0, 5.5 + cr() * 3);
      p.root.rotation.y = Math.PI + (cr() - 0.5) * 0.5; // facing the wall
      scene.add(p.root);
      crowd.push({ p, turn: 3 + cr() * 8, base: p.root.rotation.y });
    }

    // you
    let player = makePepe(CLASSIC);
    scene.add(player.root);
    let pos = new T.Vector3(0, 0, 11), heading = Math.PI; // facing the wall (-z)
    try { const s = JSON.parse(sessionStorage.getItem("hall:pos") || "null"); if (s) { pos.set(s.x, 0, s.z); heading = s.h; } } catch {}
    let camYaw = heading, camPitch = 0.12;
    api.myLook().then((look) => {
      if (!look || !state) return;
      scene.remove(player.root);
      player = makePepe(look);
      scene.add(player.root);
    }).catch(() => {});

    // ---------------- input
    const keys = new Set();
    const onKey = (e) => {
      if (e.target.closest?.("input, textarea, select") || !$("hmodal").hidden) return;
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
      g.fillStyle = "#fff"; g.textAlign = "right"; g.fillText("pepesfamily.fun", 1180, 658);
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
        if (a === "x") window.open("https://x.com/intent/tweet?text=" + encodeURIComponent("Hanging out in the PepesFamily Hall 🐸\nhttps://pepesfamily.fun/#/hall"), "_blank", "noopener,noreferrer");
        if (a === "launch") { api.useAsLaunchImage(url); }
      };
      m.onkeydown = (e) => { if (e.key === "Escape") { m.hidden = true; m.innerHTML = ""; } };
    }

    // ---------------- live data on the screens
    let feedLines = [], stats = "";
    function drawBig() {
      const g = big.g, w = big.c.width, h = big.c.height;
      g.fillStyle = "#050605"; g.fillRect(0, 0, w, h);
      g.strokeStyle = "#1d261d"; g.lineWidth = 2; g.beginPath(); g.moveTo(0, 56); g.lineTo(w, 56); g.stroke();
      g.font = "26px monospace"; g.textAlign = "left";
      g.fillStyle = GREEN; g.fillText("#", 24, 38);
      g.fillStyle = "#cfd8cf"; g.fillText(stats || "reading the chain…", 54, 38);
      g.fillStyle = "#6f7d6f"; g.textAlign = "right"; g.fillText("★ launch  ★ buy  ★ sell", w - 24, 38); g.textAlign = "left";
      const rows = feedLines.slice(-11);
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
    let near = null, last = performance.now(), raf = 0, t0 = 0;
    const tmp = new T.Vector3();
    function resize() {
      const w = el.clientWidth, h = el.clientHeight;
      renderer.setSize(w, h, false); camera.aspect = w / h; camera.fov = w < h ? 72 : 55; camera.updateProjectionMatrix(); // portrait phones need a wider view
    }
    const ro = new ResizeObserver(resize); ro.observe(el); resize();
    function frame(now) {
      raf = requestAnimationFrame(frame);
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
        for (const k of kiosks) { const ox = pos.x - k.x, oz = pos.z - k.z; if (Math.abs(ox) < 1.1 && Math.abs(oz) < 0.75) pos.z = k.z + 0.75 * Math.sign(oz || 1); }
        const want = Math.atan2(dx, dz);
        let d = want - heading; d = Math.atan2(Math.sin(d), Math.cos(d)); heading += d * Math.min(1, dt * 10);
        // the camera swings in behind you as you walk away from it
        let cd = heading - camYaw; cd = Math.atan2(Math.sin(cd), Math.cos(cd));
        if (!drag && fz < -0.3) camYaw += cd * Math.min(1, dt * 1.5); // only when walking forward: strafing keeps the view
      }
      player.root.position.copy(pos); player.root.rotation.y = heading;
      player.update(dt, Math.min(1, speed), t0);
      for (const c of crowd) {
        c.turn -= dt;
        if (c.turn < 0) { c.p.root.rotation.y = c.base + (Math.random() - 0.5) * 1.2; c.turn = 3 + Math.random() * 8; }
        c.p.update(dt, 0, t0);
      }
      // camera: behind and above
      const dist = 7, flat = dist * Math.cos(camPitch);
      camera.position.set(pos.x - Math.sin(camYaw) * flat, 2.1 + dist * Math.sin(camPitch), Math.min(D + 4, pos.z - Math.cos(camYaw) * flat));
      // look past your Pepe and a little up, so the wall's screens stay in view
      camera.lookAt(tmp.set(pos.x + Math.sin(camYaw) * 4, 2.6, pos.z + Math.cos(camYaw) * 4));
      // what is within reach
      const targets = [...kiosks, ...booths.map((b) => b.target).filter(Boolean), { x: 0, z: 1.2, r: 4, label: "The big screen: every launch and trade", go: () => api.go("#/") }];
      let best = null, bd = Infinity;
      for (const tg of targets) { const d = Math.hypot(pos.x - tg.x, pos.z - tg.z); if (d < tg.r && d < bd) { best = tg; bd = d; } }
      if (best !== near) {
        near = best;
        const p = $("hprompt");
        p.hidden = !near;
        if (near) p.textContent = `${matchMedia("(pointer: coarse)").matches ? "Tap" : "E"} · ${near.label}`;
      }
      renderer.render(scene, camera);
      if ((t0 % 2) < dt) { try { sessionStorage.setItem("hall:pos", JSON.stringify({ x: pos.x, z: pos.z, h: heading })); } catch {} }
    }
    raf = requestAnimationFrame(frame);

    state = {
      el,
      stop() {
        cancelAnimationFrame(raf); clearInterval(dataTimer); ro.disconnect();
        removeEventListener("keydown", onKey); removeEventListener("keyup", onKey); removeEventListener("blur", onBlur);
        try { sessionStorage.setItem("hall:pos", JSON.stringify({ x: pos.x, z: pos.z, h: heading })); } catch {}
        renderer.dispose();
        scene.traverse((o) => { o.geometry?.dispose?.(); const mt = o.material; (Array.isArray(mt) ? mt : [mt]).forEach((x) => { x?.map?.dispose?.(); x?.dispose?.(); }); });
        el.remove();
      },
    };
  }

  function unmount() {
    if (!state) return;
    const s = state; state = null; s.stop();
  }

  window.Hall = { mount, unmount, earnLook };
})();
