// PepesAgent's web API, for the Agent page on pepesdotfamily.fun. Runs in the worker (Railway) next to the bot.
//
//   GET  /agent/config     public: the agent's Privy signer and policy, presets, the fee, shadow/live
//   GET  /agent/stats      public: users running, wallets watched, recent decisions (shadow proposals included)
//   GET  /agent/me         the signed-in user's agent: settings, balance, open positions, closed history, fees
//   POST /agent/start      { preset, positionSol, maxPositions }: start (or update) the agent for the user
//   POST /agent/stop       stop entering new positions (open positions still get managed and closed by the rules)
//
// Signed-in calls carry the Privy access token (Authorization: Bearer). The user's wallets are read from Privy,
// never taken from the request: the agent wallet must be the user's Privy embedded Solana wallet with the agent's
// signer on it, limited by the agent's policy (walletOf), and withdrawals and the fee never use an address the request names.

import http from "node:http";
import { runAs } from "./context.js";
import { loadUsers, saveUsers, activeUsers, isLive } from "./users.js";
import { PrivySigner } from "./signer.js";
import { FEE_PCT, FEE_ADDRESS } from "./fee.js";
import { config } from "../config.js";
import { log } from "../logger.js";

/** The beta caps every user's settings: SOL per position and open positions. */
const MAX_POSITION_SOL = Number(process.env.MAX_POSITION_SOL ?? 1);
const MAX_POSITIONS = Number(process.env.MAX_POSITIONS ?? 3);
const ORIGINS = (process.env.CORS_ORIGINS || "https://pepesdotfamily.fun,https://www.pepesdotfamily.fun,http://127.0.0.1:5183,http://localhost:5183").split(",");

/** Risk presets: exits and range (config.js keys). Size comes from the user's own SOL per position. */
export const PRESETS = {
  safe: { label: "Safe", management: { stopLossPct: -15, takeProfitPct: 4, trailingTriggerPct: 2.5, trailingDropPct: 1, outOfRangeWaitMinutes: 15, minFeePerTvl24h: 10 } },
  balanced: { label: "Balanced", management: { stopLossPct: -25, takeProfitPct: 6, trailingTriggerPct: 3, trailingDropPct: 1.5, outOfRangeWaitMinutes: 30 } },
  degen: { label: "Degen", management: { stopLossPct: -40, takeProfitPct: 12, trailingTriggerPct: 6, trailingDropPct: 3, outOfRangeWaitMinutes: 45 } },
};

/** A user's config overrides from their choices (pepes/context.js overlay). */
export function settingsFor({ preset, positionSol, maxPositions }) {
  const p = PRESETS[preset] ? preset : "balanced";
  const sol = Math.min(MAX_POSITION_SOL, Math.max(0.1, Number(positionSol) || 0.25));
  const n = Math.min(MAX_POSITIONS, Math.max(1, Math.floor(Number(maxPositions) || 2)));
  return {
    preset: p, positionSol: sol, maxPositions: n,
    risk: { maxPositions: n, maxDeployAmount: sol },
    // a fixed size: floor = ceiling = the user's SOL per position; keep 0.05 SOL for network fees
    management: { ...PRESETS[p].management, deployAmountSol: sol, minSolToOpen: sol + 0.06, gasReserve: 0.05 },
  };
}

let _privy = null;
async function privy() {
  if (!_privy) {
    const { PrivyClient } = await import("@privy-io/node");
    _privy = new PrivyClient({ appId: process.env.PRIVY_APP_ID, appSecret: process.env.PRIVY_APP_SECRET });
  }
  return _privy;
}

/** The Privy user behind the request's access token, with their PepesAgent wallets. */
async function whoIs(req) {
  const token = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  if (!token) throw Object.assign(new Error("Sign in first"), { status: 401 });
  const p = await privy();
  let claims;
  try { claims = await p.utils().auth().verifyAccessToken(token); }
  catch { throw Object.assign(new Error("Your sign-in expired: sign in again"), { status: 401 }); }
  const user = await p.users()._get(claims.user_id);
  const sol = (user.linked_accounts || []).filter(a => a.type === "wallet" && a.chain_type === "solana");
  const agent = sol.find(a => a.connector_type === "embedded");
  const phantom = sol.find(a => a !== agent);
  return { id: claims.user_id, agent, phantom };
}

/**
 * The user's agent wallet as Privy has it, and whether they approved the agent: our key is among the wallet's signers,
 * limited by our policy. Privy's `delegated` flag on the account can't be used for this: it is not specific to our key.
 */
async function walletOf(who) {
  if (!who.agent?.address) return { walletId: null, approved: false };
  const p = await privy();
  let wallet = null;
  if (who.agent.id) wallet = await p.wallets().get(who.agent.id);
  else for await (const w of p.wallets().list({ user_id: who.id, chain_type: "solana" })) if (w.address === who.agent.address) { wallet = w; break; }
  if (!wallet) return { walletId: null, approved: false };
  const policies = (process.env.PRIVY_POLICY_IDS || "").split(",").filter(Boolean);
  const signer = (wallet.additional_signers || []).find(a => a.signer_id === process.env.PRIVY_SIGNER_ID);
  const limited = !!signer && policies.length > 0 && policies.every(id => (signer.override_policy_ids || []).includes(id));
  return { walletId: wallet.id, approved: limited };
}

const view = (u) => u && { active: !!u.active, live: isLive(u), address: u.address, owner: u.owner, settings: u.settings, startedAt: u.startedAt };

async function me(who) {
  const record = loadUsers().find(u => u.id === who.id) || null;
  const { approved } = await walletOf(who);
  const out = { user: view(record), agentWallet: who.agent?.address || null, approved, phantom: who.phantom?.address || null };
  if (!who.agent?.address) return out;
  const user = { ...(record || {}), id: who.id, address: who.agent.address, live: false, // read-only here
    signer: new PrivySigner({ walletId: who.agent.id || "none", address: who.agent.address }) };
  const [{ getWalletBalances }, { getMyPositions }, { getPerformanceHistory }, fs, { userPath }] = await Promise.all([
    import("../tools/wallet.js"), import("../tools/dlmm.js"), import("../performance.js"), import("node:fs"), import("./context.js")]);
  await runAs(user, async () => {
    const bal = await getWalletBalances({ force: true, nativeOnly: true }).catch(() => null);
    out.balanceSol = Number.isFinite(bal?.sol) ? bal.sol : null;
    const pos = await getMyPositions({ force: true, silent: true }).catch(() => null);
    out.positions = pos?.positions ?? null;
    out.history = getPerformanceHistory({ hours: 24 * 30, limit: 50 }).positions;
    try { out.fees = JSON.parse(fs.readFileSync(userPath("fees.json"), "utf8")); } catch { out.fees = []; }
  });
  return out;
}

async function start(who, body) {
  const { walletId, approved } = await walletOf(who);
  if (!who.agent?.address || !walletId) throw Object.assign(new Error("Create your agent wallet first"), { status: 400 });
  if (!approved) throw Object.assign(new Error("Approve the agent for your agent wallet first"), { status: 400 });
  if (!who.phantom?.address) throw Object.assign(new Error("Sign in with Phantom first"), { status: 400 });
  const users = loadUsers();
  let u = users.find(x => x.id === who.id);
  if (!u) { u = { id: who.id, startedAt: new Date().toISOString() }; users.push(u); }
  Object.assign(u, { address: who.agent.address, walletId, owner: who.phantom.address, active: true,
    settings: settingsFor(body) });
  saveUsers(users);
  log("agent_user", `${who.agent.address.slice(0, 6)} started (${u.settings.preset}, ${u.settings.positionSol} SOL x ${u.settings.maxPositions}, ${isLive(u) ? "live" : "shadow"})`);
  return view(u);
}

function stop(who) {
  const users = loadUsers();
  const u = users.find(x => x.id === who.id);
  if (u) { u.active = false; saveUsers(users); log("agent_user", `${u.address.slice(0, 6)} stopped`); }
  return view(u);
}

async function stats() {
  const { listSmartWallets } = await import("../smart-wallets.js");
  const { getRecentDecisions } = await import("../decision-log.js").catch(() => ({}));
  return {
    users: activeUsers().length,
    walletsWatched: (listSmartWallets()?.wallets || []).length,
    shadow: config.standalone.shadow || process.env.AGENT_LIVE !== "true",
    decisions: typeof getRecentDecisions === "function" ? getRecentDecisions(20) : [],
  };
}

const publicConfig = () => ({
  signerId: process.env.PRIVY_SIGNER_ID || null,
  policyIds: (process.env.PRIVY_POLICY_IDS || "").split(",").filter(Boolean),
  presets: Object.fromEntries(Object.entries(PRESETS).map(([k, v]) => [k, { label: v.label, ...v.management }])),
  feePct: FEE_PCT, feeAddress: FEE_ADDRESS, maxPositionSol: MAX_POSITION_SOL, maxPositions: MAX_POSITIONS,
  shadow: config.standalone.shadow || process.env.AGENT_LIVE !== "true",
});

async function body(req) {
  let s = "";
  for await (const chunk of req) { s += chunk; if (s.length > 10_000) throw Object.assign(new Error("Too large"), { status: 413 }); }
  try { return s ? JSON.parse(s) : {}; } catch { throw Object.assign(new Error("Bad JSON"), { status: 400 }); }
}

export function startServer(port = Number(process.env.PORT || 8080)) {
  const server = http.createServer(async (req, res) => {
    const origin = req.headers.origin;
    if (origin && ORIGINS.includes(origin)) {
      res.setHeader("access-control-allow-origin", origin);
      res.setHeader("vary", "origin");
      res.setHeader("access-control-allow-headers", "authorization, content-type");
      res.setHeader("access-control-allow-methods", "GET, POST, OPTIONS");
    }
    if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
    const send = (status, data) => { res.writeHead(status, { "content-type": "application/json" }); res.end(JSON.stringify(data)); };
    try {
      const path = new URL(req.url, "http://x").pathname;
      if (req.method === "GET" && path === "/health") return send(200, { ok: true });
      if (req.method === "GET" && path === "/agent/config") return send(200, publicConfig());
      if (req.method === "GET" && path === "/agent/stats") return send(200, await stats());
      if (req.method === "GET" && path === "/agent/me") return send(200, await me(await whoIs(req)));
      if (req.method === "POST" && path === "/agent/start") { const b = await body(req); return send(200, await start(await whoIs(req), b)); }
      if (req.method === "POST" && path === "/agent/stop") return send(200, stop(await whoIs(req)));
      return send(404, { error: "Not found" });
    } catch (e) {
      if (!e.status) log("api_error", e.message);
      return send(e.status || 500, { error: e.status ? e.message : "Something went wrong" });
    }
  });
  server.listen(port, () => log("api", `Agent API on :${port}`));
  return server;
}
