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
  let sheet = null;
  const sheetMaps = []; // the sheet and every Pepe's copy of it, refreshed once the image has loaded
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
      };
      img.src = SHEET;
    }
    return sheet;
  };
  let activeCamera = null;

  /// A Pepe in the room, feet at the origin. root.rotation.y is the way it faces; update() picks the frame.
  function makePepe(opts = {}) {
    const map = sheetTexture().clone(); // shares the image; its own frame offset
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
      /// Arms up for a couple of seconds (the crowd does this when a trade or launch lands on the big screen).
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

  // ------------------------------------------------------------------ the hall
  let state = null;

  function mount(container, api) {
    unmount();
    const W = 60, D = 18, WALL_H = 13; // room width, depth, wall height
    const el = document.createElement("div");
    el.className = "hall";
    el.innerHTML = `
      <canvas class="hall-c" aria-label="PepesFamily: walk your Pepe to a screen to launch, trade or claim"></canvas>
      <div class="hall-top"><b>PEPESFAMILY</b><span class="hall-live" id="hlive">reading the chain…</span></div>
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
    activeCamera = camera;
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
      const k = { x, z: 1.6, r: 2.3, g, label: `${label.toLowerCase().replace(/^./, (c) => c.toUpperCase())}: ${sub}`, go: () => api.go(hash) };
      kiosks.push(k);
      return k;
    }
    kiosk(-16, "LAUNCH", "launch a token", "#/create");
    kiosk(-10.5, "TOKENS", "browse every token", "#/tokens");
    kiosk(10.5, "REWARDS", "claim your IMD", "#/rewards");
    kiosk(16, "NFT", "Pepes Earn IMD", "#/nft");
    kiosk(5.5, "WORLD", "enter Pepes World", "/world/");
    // the admin terminal only stands there for the launchpad's owner or fee recipient (see setAdmin)
    const admin = kiosk(-5.5, "ADMIN", "collect fees", "#/admin");
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

    // the locals: Pepes watching the big screen
    const crowd = [];
    const cr = rnd(91);
    for (let i = 0; i < 7; i++) {
      const p = makePepe();
      p.root.position.set(-7 + i * 2.3 + (cr() - 0.5), 0, 5.5 + cr() * 3);
      p.root.rotation.y = Math.PI + (cr() - 0.5) * 0.5; // facing the wall
      scene.add(p.root);
      crowd.push({ p, turn: 3 + cr() * 8, base: p.root.rotation.y });
    }

    // you
    const player = makePepe({ you: true });
    scene.add(player.root);
    let pos = new T.Vector3(0, 0, 11), heading = Math.PI; // facing the wall (-z)
    try { const s = JSON.parse(sessionStorage.getItem("hall:pos") || "null"); if (s) { pos.set(s.x, 0, s.z); heading = s.h; } } catch {}
    let camYaw = heading, camPitch = 0.12;
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
        if (a === "x") window.open("https://x.com/intent/tweet?text=" + encodeURIComponent("Hanging out in the PepesFamily Hall 🐸\nhttps://pepesfamily.fun/"), "_blank", "noopener,noreferrer");
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
        // something new on the big screen: the crowd cheers
        const lastKey = d.events.length ? JSON.stringify(d.events[d.events.length - 1]) : "";
        if (seenKey && lastKey !== seenKey) crowd.forEach((c, i) => setTimeout(() => c.p.cheer(), i * 120));
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
    let near = null, last = performance.now(), raf = 0, t0 = 0;
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
      // camera: behind and above
      const dist = 7, flat = dist * Math.cos(camPitch);
      camera.position.set(pos.x - Math.sin(camYaw) * flat, 2.1 + dist * Math.sin(camPitch), Math.min(D + 4, pos.z - Math.cos(camYaw) * flat));
      // look past your Pepe and a little up, so the wall's screens stay in view
      camera.lookAt(tmp.set(pos.x + Math.sin(camYaw) * 4, 2.6, pos.z + Math.cos(camYaw) * 4));
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

  /// Holds the Hall still (no input, no drawing) while a window is open over it, and lets it go again.
  function pause(p) { state?.pause(p); }
  /// Shows or hides the admin terminal.
  function setAdmin(on) { state?.setAdmin(on); }

  function unmount() {
    if (!state) return;
    const s = state; state = null; s.stop();
  }

  window.Hall = { mount, unmount, pause, setAdmin };
})();
