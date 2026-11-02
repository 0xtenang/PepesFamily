// PepesAgent's signal log and public track record: every wallet-convergence signal, screened once and recorded whether
// or not anyone has funds. Its pool price is followed for 24 hours, and the real positions of the LPs who triggered it
// for 7 days, from Meteora: their profit in SOL, fees included. That is what those LPs made, not what the agent would
// have made (its range, size and exits differ), and comparing passed with rejected signals shows if screening helps.

import fs from "node:fs";
import { dataPath } from "./context.js";
import { poolDetail } from "../standalone/screening.js";
import { fetchJson } from "../standalone/rpc.js";
import { log } from "../logger.js";

const FILE = () => dataPath("signals.json");
const KEEP = 500, FOLLOW_MS = 24 * 3600_000, LP_FOLLOW_MS = 7 * 24 * 3600_000;

function load() { try { return JSON.parse(fs.readFileSync(FILE(), "utf8")); } catch { return []; } }
function save(list) {
  fs.mkdirSync(dataPath(), { recursive: true });
  fs.writeFileSync(`${FILE()}.tmp`, JSON.stringify(list.slice(-KEEP)));
  fs.renameSync(`${FILE()}.tmp`, FILE());
}

/** Records one signal and its screening result. */
export function recordSignal(signal, screened) {
  const p = screened?.pass ? screened.pool : null;
  const price = Number(p?.pool_price);
  const list = load();
  list.push({
    at: Date.now(), mint: signal.mint, wallets: signal.events.length,
    lps: signal.events.map(e => ({ wallet: e.wallet, pool: e.pool, position: e.position })),
    symbol: screened?.token?.symbol ?? null,
    pass: !!screened?.pass, reason: screened?.pass ? null : String(screened?.reason ?? "unknown").slice(0, 160),
    pool: p?.pool_address ?? null, name: p?.name ?? null, tvl: Number(p?.tvl ?? p?.active_tvl) || null,
    price: price > 0 ? price : null, priceNow: price > 0 ? price : null, high: price > 0 ? price : null, low: price > 0 ? price : null,
  });
  save(list);
}

/** Updates the price of passed signals younger than a day. */
export async function followSignals() {
  const list = load();
  let changed = false;
  for (const s of list) {
    if (!s.pass || !s.pool || !s.price || Date.now() - s.at > FOLLOW_MS) continue;
    try {
      const now = Number((await poolDetail(s.pool)).pool_price);
      if (!(now > 0)) continue;
      Object.assign(s, { priceNow: now, high: Math.max(s.high, now), low: Math.min(s.low, now) });
      changed = true;
    } catch (e) { log("signals_warn", `${s.pool.slice(0, 8)}: ${e.message}`); }
  }
  if (changed) save(list);
}

/** Updates each signal's LP positions with Meteora's result: profit in SOL including fees, and whether all are closed. */
export async function followLps(fetchPnl = (lp) => fetchJson(`https://dlmm.datapi.meteora.ag/positions/${lp.pool}/pnl?user=${lp.wallet}&status=all&pageSize=50&page=1`)) {
  const list = load();
  let changed = false;
  for (const s of list) {
    if (!s.lps?.length || s.lpClosed || Date.now() - s.at > LP_FOLLOW_MS) continue;
    const found = [];
    for (const lp of s.lps) {
      try {
        const p = (await fetchPnl(lp)).positions?.find(x => x.positionAddress === lp.position);
        const pct = Number(p?.pnlSolPctChange);
        if (p && Number.isFinite(pct)) found.push({ pct, closed: !!p.isClosed });
      } catch (e) { log("signals_warn", `LP ${String(lp.wallet).slice(0, 6)}: ${e.message}`); }
    }
    if (!found.length) continue;
    s.lpPct = Math.round(found.reduce((t, x) => t + x.pct, 0) / found.length * 10) / 10;
    s.lpClosed = found.length === s.lps.length && found.every(x => x.closed);
    changed = true;
  }
  if (changed) save(list);
}

/** Closed results of a set of signals: how many, their average, and the share that made money. */
function outcome(list) {
  const done = list.filter(s => s.lpClosed && Number.isFinite(s.lpPct));
  if (!done.length) return { closed: 0, avgPct: null, winPct: null };
  return {
    closed: done.length,
    avgPct: Math.round(done.reduce((t, s) => t + s.lpPct, 0) / done.length * 10) / 10,
    winPct: Math.round(done.filter(s => s.lpPct > 0).length / done.length * 100),
  };
}

/** The latest signals and totals, for the Agent page. */
export function signalStats(limit = 20) {
  const list = load();
  const pct = (a, b) => (a && b ? Math.round((a / b - 1) * 1000) / 10 : null);
  return {
    total: list.length,
    passed: list.filter(s => s.pass).length,
    since: list[0]?.at ?? null,
    outcomes: { passed: outcome(list.filter(s => s.pass)), rejected: outcome(list.filter(s => !s.pass)) },
    recent: list.slice(-limit).reverse().map(s => ({
      at: s.at, mint: s.mint, symbol: s.symbol, name: s.name, wallets: s.wallets, pass: s.pass, reason: s.reason, pool: s.pool,
      lpPct: s.lpPct ?? null, lpClosed: !!s.lpClosed,
      movePct: pct(s.priceNow, s.price), highPct: pct(s.high, s.price), lowPct: pct(s.low, s.price),
    })),
  };
}
