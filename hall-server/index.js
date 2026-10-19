// PepesFamily Hall server: the shared Hall (who is there, where they stand, what they look like), for
// the multiplayer Hall on pepesfamily.fun. A Cloudflare Worker with one Durable Object per room ("hall-1",
// "hall-2", ...; a room holds MAX_PLAYERS, the next one takes the rest). WebSocket hibernation: idle players cost
// nothing. No accounts, no wallets, nothing stored. (Nicknames and chat were removed: names are never shown.)
//
// Protocol (JSON text frames, client -> server):
//   {t:"hello", name, look}          join (name 2-16 chars; look: {skin, shirt, shorts, extra} small ints, or null)
//   {t:"move", x, z, h, s, a}        where you are: position, heading, speed 0-2, act ("" or "cheer")
//   {t:"look", look}                 you put on another Pepe (or null)
// Server -> client:
//   {t:"welcome", id, name, players:[{id,name,look,x,z,h,s,a}], chat:[{id,name,text,ts}], room}
//   {t:"join", p}  {t:"leave", id}  {t:"move", id, x, z, h, s, a}  {t:"look", id, look}  {t:"name", id, name}
//   {t:"full"}   {t:"error", text}

const MAX_PLAYERS = 60;
const CHAT_KEEP = 40;
const ORIGINS = [
  /^https:\/\/(www\.)?pepesfamily\.fun$/,
  /^https:\/\/pepesfamily(-[a-z0-9-]+)?\.vercel\.app$/,
  /^https:\/\/pepesfamily[a-z0-9-]*\.sites\.imd\.fun$/,
  /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/,
];

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (url.pathname === "/") return new Response("PepesFamily Hall server", { headers: { "content-type": "text/plain" } });
    if (url.pathname !== "/hall") return new Response("Not found", { status: 404 });
    if (req.headers.get("Upgrade") !== "websocket") return new Response("WebSocket only", { status: 426 });
    const origin = req.headers.get("Origin") || "";
    if (!ORIGINS.some((r) => r.test(origin))) return new Response("Forbidden", { status: 403 });
    const room = Math.min(20, Math.max(1, parseInt(url.searchParams.get("room") || "1", 10) || 1));
    const stub = env.HALL.get(env.HALL.idFromName("hall-" + room));
    return stub.fetch(new Request(url.toString() + (url.search ? "&" : "?") + "n=" + room, req));
  },
};

// ---------------------------------------------------------------- validation
// names that pass for staff, or bait (impersonation is how scams start in a crypto chat)
const RESERVED = /admin|moderat|official|support|pepes ?family|giveaway|airdrop|announce|\b(mods?|team|staff|owner|devs?|imd|system|bot)\b/i;
const SLUR = "\\b(nigg\\w*|fagg?\\w*|retard\\w*|kike\\w*|chink\\w*|spic\\w*|tranny\\w*)\\b";
const SLURS = new RegExp(SLUR, "gi"), HAS_SLUR = new RegExp(SLUR, "i");
const ctrl = (s) => s.replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁠-⁯﻿]/g, "");

function cleanName(raw) {
  if (typeof raw !== "string") return null;
  const s = ctrl(raw).replace(/\s+/g, " ").trim();
  if (s.length < 2 || s.length > 16) return null;
  if (!/^[\p{L}\p{N} _.\-]+$/u.test(s) || !/[\p{L}\p{N}]/u.test(s)) return null;
  if (RESERVED.test(s) || HAS_SLUR.test(s)) return null;
  return s;
}
function cleanText(raw) {
  if (typeof raw !== "string") return null;
  let s = ctrl(raw).replace(/\s+/g, " ").trim().slice(0, 200);
  if (!s) return null;
  // no links or wallet addresses in chat: the usual way scams travel
  s = s.replace(/\b(?:https?:\/\/|www\.)\S+/gi, "[link]")
    .replace(/\b[\w-]+(?:\.[\w-]+)*\.(?:com|net|org|io|xyz|fun|app|gg|link|me|co|site|online|top|vip|club|finance|pro|dev|info|biz|ly|to|sh|cc|tv)\b\S*/gi, "[link]")
    .replace(/\b0x[0-9a-fA-F]{20,}\b/g, "[address]")
    .replace(/\b(?:t\.me|discord\.gg)\/\S+/gi, "[link]");
  s = s.replace(SLURS, (w) => "*".repeat(w.length));
  return s;
}
const int = (v, max) => (Number.isInteger(v) && v >= 0 && v <= max ? v : 0);
function cleanLook(l) {
  if (!l || typeof l !== "object") return null;
  return { skin: int(l.skin, 6), shirt: int(l.shirt, 8), shorts: int(l.shorts, 5), extra: int(l.extra, 3) };
}
const num = (v, lo, hi, d) => (typeof v === "number" && Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : d);
const round = (v) => Math.round(v * 100) / 100;

// ---------------------------------------------------------------- the room
export class Hall {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.chat = null;
    this.nextId = null;
  }

  async loadChat() {
    if (!this.chat) this.chat = (await this.ctx.storage.get("chat")) || [];
    return this.chat;
  }

  players(except) {
    const out = [];
    for (const ws of this.ctx.getWebSockets()) {
      const p = ws.deserializeAttachment();
      if (p && p.joined && ws !== except) out.push({ ws, p });
    }
    return out;
  }

  send(ws, msg) { try { ws.send(JSON.stringify(msg)); } catch {} }
  broadcast(msg, except) {
    const s = JSON.stringify(msg);
    for (const { ws } of this.players(except)) { try { ws.send(s); } catch {} }
  }

  async fetch(req) {
    const room = parseInt(new URL(req.url).searchParams.get("n") || "1", 10);
    if (this.players().length >= MAX_PLAYERS) {
      const [c, s] = Object.values(new WebSocketPair());
      s.accept(); s.send(JSON.stringify({ t: "full" })); s.close(4000, "full");
      return new Response(null, { status: 101, webSocket: c });
    }
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server);
    if (this.nextId == null) this.nextId = ((await this.ctx.storage.get("nextId")) || 0) + 1000;
    const id = ++this.nextId;
    this.ctx.storage.put("nextId", this.nextId);
    server.serializeAttachment({ id, room, joined: false, name: "", look: null, x: 0, z: 10, h: Math.PI, s: 0, a: "", lastChat: 0, chats: [], win: 0, n: 0 });
    return new Response(null, { status: 101, webSocket: client });
  }

  uniqueName(name, me) {
    const taken = new Set(this.players(me).map(({ p }) => p.name.toLowerCase()));
    if (!taken.has(name.toLowerCase())) return name;
    for (let i = 2; i < 100; i++) { const n = (name.slice(0, 13) + "#" + i); if (!taken.has(n.toLowerCase())) return n; }
    return name.slice(0, 11) + "#" + Math.floor(Math.random() * 9999);
  }

  async webSocketMessage(ws, data) {
    const p = ws.deserializeAttachment();
    if (!p) return;
    // flood guard: at most 30 messages a second, and nothing bigger than 1 KB
    const now = Date.now();
    if (now - p.win > 1000) { p.win = now; p.n = 0; }
    if (++p.n > 30 || typeof data !== "string" || data.length > 1024) { ws.close(4008, "too much"); return; }
    // keep the count: the attachment is a copy, and the paths below that return early never save it
    ws.serializeAttachment(p);
    let m;
    try { m = JSON.parse(data); } catch { return; }
    if (!m || typeof m !== "object") return;

    if (m.t === "hello" && !p.joined) {
      const name = cleanName(m.name);
      if (!name) { this.send(ws, { t: "error", text: "That nickname can't be used: 2-16 letters, numbers, spaces, . _ or -, and not a staff-like name." }); ws.serializeAttachment(p); return; }
      p.name = this.uniqueName(name, ws); p.look = cleanLook(m.look); p.joined = true;
      ws.serializeAttachment(p);
      const others = this.players(ws).map(({ p: o }) => ({ id: o.id, name: o.name, look: o.look, x: o.x, z: o.z, h: o.h, s: o.s, a: o.a }));
      this.send(ws, { t: "welcome", id: p.id, name: p.name, room: p.room, players: others, chat: [] });
      this.broadcast({ t: "join", p: { id: p.id, name: p.name, look: p.look, x: p.x, z: p.z, h: p.h, s: 0, a: "" } }, ws);
      return;
    }
    if (!p.joined) return;

    if (m.t === "move") {
      p.x = round(num(m.x, -29.5, 29.5, p.x)); p.z = round(num(m.z, 0.5, 17.5, p.z)); p.h = round(num(m.h, -100, 100, p.h));
      p.s = round(num(m.s, 0, 2, 0)); p.a = m.a === "cheer" ? "cheer" : "";
      ws.serializeAttachment(p);
      this.broadcast({ t: "move", id: p.id, x: p.x, z: p.z, h: p.h, s: p.s, a: p.a }, ws);
    } else if (m.t === "look") {
      p.look = cleanLook(m.look); ws.serializeAttachment(p);
      this.broadcast({ t: "look", id: p.id, look: p.look }, ws);
    }
    // (nicknames and chat were removed on 2026-10-18: "name" and "chat" messages are ignored)
  }

  async webSocketClose(ws) { this.left(ws); }
  async webSocketError(ws) { this.left(ws); }
  left(ws) {
    const p = ws.deserializeAttachment();
    try { ws.close(1000, "bye"); } catch {}
    if (p && p.joined) this.broadcast({ t: "leave", id: p.id }, ws);
  }
}
