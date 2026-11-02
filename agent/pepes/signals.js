// PepesAgent's signal log: every wallet-convergence signal, screened once and recorded whether or not anyone has
// funds, then its pool price followed for 24 hours. This is what shadow mode shows: which picks the agent would have
// made and how the price went afterwards. It says nothing about fees earned or a real position's result.

import fs from "node:fs";
import { dataPath } from "./context.js";
import { poolDetail } from "../standalone/screening.js";
import { log } from "../logger.js";

const FILE = () => dataPath("signals.json");
const KEEP = 500, FOLLOW_MS = 24 * 3600_000;

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

/** The latest signals and totals, for the Agent page. */
export function signalStats(limit = 20) {
  const list = load();
  const pct = (a, b) => (a && b ? Math.round((a / b - 1) * 1000) / 10 : null);
  return {
    total: list.length,
    passed: list.filter(s => s.pass).length,
    since: list[0]?.at ?? null,
    recent: list.slice(-limit).reverse().map(s => ({
      at: s.at, mint: s.mint, symbol: s.symbol, name: s.name, wallets: s.wallets, pass: s.pass, reason: s.reason, pool: s.pool,
      movePct: pct(s.priceNow, s.price), highPct: pct(s.high, s.price), lowPct: pct(s.low, s.price),
    })),
  };
}
