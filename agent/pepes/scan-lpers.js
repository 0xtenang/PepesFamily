// PepesAgent starter list: Meteora LP wallets worth watching for convergence signals.
//
//   node pepes/scan-lpers.js [--pools 30] [--top 25] [--write] [--rerank]
//
// 1. Pools: the day's highest-fee Meteora DLMM memecoin pools the agent itself can trade (token/SOL, bin step
//    80-125, TVL $10k-$500k: config.js screening defaults).
// 2. Owners: every open position in those pools, read on-chain (DLMM Position accounts: lb_pair at offset 8,
//    owner at 40). Wallets LPing in at least 2 of them are candidates.
// 3. Track record from Meteora's portfolio API: the last 30 days per pool (SOL deposited, profit in SOL, last
//    close) and the all-time total. Kept: >= 5 pools and >= 2 SOL deposited in 30 days, 30-day profit > 1% of
//    deposits, >= 50% of pools profitable, all-time profit > 0, a close in the last 3 days. Ranked by 30-day profit.
//    (Nearly every wallet LPing today's hot pools is up over 30 days, so the profit bar matters more than the count.)
// 4. Operators: wallets that share nearly all their pools (overlap / the larger list >= 75%) are treated as one
//    operator and get the same `group`, so two of them agreeing isn't a signal (config.js walletGroups).
// --write saves pepes/smart-wallets.starter.json (used when no smart-wallets.json exists). Every rated wallet goes to
// data/scan-lpers.json; --rerank re-applies the filters to that file without scanning again.

import fs from "node:fs";
import bs58 from "bs58";
import { repoPath } from "../repo-root.js";
import { dataPath } from "./context.js";

const args = process.argv.slice(2);
const flag = (name, dflt) => { const i = args.indexOf(`--${name}`); return i >= 0 ? Number(args[i + 1]) : dflt; };
const POOLS = flag("pools", 30), TOP = flag("top", 45);
const RPC = process.env.RPC_URL || "https://api.mainnet-beta.solana.com";
const API = "https://dlmm.datapi.meteora.ag";
const DLMM = "LBUZKhRxPF3XUpBCjp4YzTKgLccjZhTSDM9YuVaPwxo";
const SOL = "So11111111111111111111111111111111111111112";
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function json(url, init, tries = 4) {
  for (let i = 0; ; i++) {
    try {
      const r = await fetch(url, init);
      if (r.status === 429 && i < tries) { await sleep(1500 * (i + 1)); continue; }
      if (!r.ok) throw new Error(`${r.status} ${url.slice(0, 80)}`);
      return await r.json();
    } catch (e) { if (i >= tries) throw e; await sleep(1000 * (i + 1)); }
  }
}

async function topPools() {
  const filter = encodeURIComponent("tvl>10000 && tvl<500000");
  const d = await json(`${API}/pools?page=1&page_size=200&sort_by=fee_24h:desc&filter_by=${filter}`);
  return d.data
    .filter(p => p.token_y?.address === SOL && p.pool_config.bin_step >= 80 && p.pool_config.bin_step <= 125)
    .slice(0, POOLS)
    .map(p => ({ address: p.address, name: p.name, fees24h: p.fees?.["24h"] ?? 0 }));
}

async function owners(pool) {
  const j = await json(RPC, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({
    jsonrpc: "2.0", id: 1, method: "getProgramAccounts",
    params: [DLMM, { encoding: "base64", dataSlice: { offset: 40, length: 32 }, filters: [{ memcmp: { offset: 8, bytes: pool } }] }],
  }) });
  if (j.error) throw new Error(j.error.message);
  return new Set(j.result.map(a => bs58.encode(Buffer.from(a.account.data[0], "base64"))));
}

async function record(wallet) {
  const pools = [];
  for (let page = 1; page <= 10; page++) {
    const d = await json(`${API}/portfolio?user=${wallet}&page=${page}&page_size=50&days_back=30`);
    pools.push(...(d.pools || []));
    if (!d.hasNext) break;
  }
  const sol = pools.filter(p => p.tokenYMint === SOL);
  const deposit = sol.reduce((s, p) => s + Number(p.totalDepositSol || 0), 0);
  const pnl = sol.reduce((s, p) => s + Number(p.pnlSol || 0), 0);
  const wins = sol.filter(p => Number(p.pnlSol) > 0).length;
  const last = Math.max(0, ...sol.map(p => Number(p.lastClosedAt || 0)));
  const total = await json(`${API}/portfolio/total?user=${wallet}`);
  return { wallet, allTimePnlSol: Number(total.totalPnlSol || 0), allTimeClosed: Number(total.totalClosedPositions || 0), pools: sol.length, depositSol: deposit, pnlSol: pnl, roiPct: deposit > 0 ? pnl / deposit * 100 : 0,
    winPct: sol.length ? wins / sol.length * 100 : 0, lastClosedAt: last };
}

const SAVED = process.env.DATA_DIR ? dataPath("scan-lpers.json") : repoPath("data", "scan-lpers.json");
const rated = args.includes("--rerank") ? JSON.parse(fs.readFileSync(SAVED, "utf8")) : await scan();

async function scan() {
const pools = await topPools();
console.error(`${pools.length} pools: ${pools.map(p => p.name).join(", ")}`);
const seen = new Map();
for (const p of pools) {
  try {
    for (const o of await owners(p.address)) seen.set(o, (seen.get(o) || 0) + 1);
  } catch (e) { console.error(`owners ${p.name}: ${e.message}`); }
  await sleep(400);
}
const candidates = [...seen].filter(([, n]) => n >= 2).sort((a, b) => b[1] - a[1]).slice(0, 300);
console.error(`${seen.size} LP wallets, ${candidates.length} in 2+ pools`);
const out = [];
for (const [w, n] of candidates) {
  try { out.push({ ...(await record(w)), livePools: n }); } catch (e) { console.error(`record ${w.slice(0, 6)}: ${e.message}`); }
  await sleep(150);
}
fs.mkdirSync(SAVED.replace(/[^/]+$/, ""), { recursive: true });
fs.writeFileSync(SAVED, JSON.stringify(out, null, 1));
return out;
}

const now = Date.now() / 1000;
const keep = rated
  .filter(r => r.pools >= 5 && r.depositSol >= 2 && r.roiPct > 1 && r.winPct >= 50 && r.allTimePnlSol > 0 && now - r.lastClosedAt < 3 * 86400)
  .sort((a, b) => b.pnlSol - a.pnlSol)
  .slice(0, TOP);
/** The pools a wallet used in the last 30 days (its most recent 200). */
async function poolsOf(wallet) {
  const out = new Set();
  for (let page = 1; page <= 4; page++) {
    const d = await json(`${API}/portfolio?user=${wallet}&page=${page}&page_size=50&days_back=30`);
    for (const p of d.pools || []) out.add(p.poolAddress);
    if (!d.hasNext) break;
  }
  return out;
}

/** wallet -> operator group, joining wallets whose pool lists nearly coincide. */
export function operatorGroups(poolsByWallet, minOverlap = 0.75) {
  const parent = new Map([...poolsByWallet.keys()].map(w => [w, w]));
  const find = w => (parent.get(w) === w ? w : find(parent.get(w)));
  const wallets = [...poolsByWallet.keys()];
  for (let i = 0; i < wallets.length; i++) for (let j = i + 1; j < wallets.length; j++) {
    const a = poolsByWallet.get(wallets[i]), b = poolsByWallet.get(wallets[j]);
    const larger = Math.max(a.size, b.size);
    if (larger < 5) continue;
    let shared = 0;
    for (const p of a) if (b.has(p)) shared++;
    if (shared / larger >= minOverlap) parent.set(find(wallets[i]), find(wallets[j]));
  }
  return new Map(wallets.map(w => [w, find(w)]));
}

const poolsByWallet = new Map();
for (const r of keep) { poolsByWallet.set(r.wallet, await poolsOf(r.wallet)); await sleep(100); }
const groups = operatorGroups(poolsByWallet);
const operators = new Set(groups.values()).size;
console.error(`${keep.length} wallets, ${operators} operators`);

const round = (x, d = 2) => Math.round(x * 10 ** d) / 10 ** d;
console.table(keep.map(r => ({ wallet: r.wallet, pools: r.pools, live: r.livePools, depositSol: round(r.depositSol, 1),
  pnlSol: round(r.pnlSol), roiPct: round(r.roiPct, 1), winPct: round(r.winPct, 0), allTimeSol: round(r.allTimePnlSol) })));
if (args.includes("--write")) {
  const out = {
    generatedAt: new Date().toISOString(),
    method: "pepes/scan-lpers.js: open LPs in the day's top-fee Meteora SOL memecoin pools, filtered and ranked by their 30-day Meteora profit",
    wallets: keep.map((r, i) => ({ name: `starter-${String(i + 1).padStart(2, "0")}`, address: r.wallet, category: "starter", type: "lp", group: groups.get(r.wallet),
      stats: { pools30d: r.pools, depositSol30d: round(r.depositSol, 1), pnlSol30d: round(r.pnlSol), roiPct30d: round(r.roiPct, 1), winPct30d: round(r.winPct, 0), allTimePnlSol: round(r.allTimePnlSol) } })),
  };
  fs.writeFileSync(repoPath("pepes", "smart-wallets.starter.json"), JSON.stringify(out, null, 2) + "\n");
  console.error(`wrote ${keep.length} wallets to pepes/smart-wallets.starter.json`);
}
