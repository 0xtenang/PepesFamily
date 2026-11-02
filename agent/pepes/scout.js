// PepesAgent scout: learns what to LP from Meteora itself. Every 5 minutes it reads the Top Performers, Trending and
// New Tokens feeds behind meteora.ag, records each new DLMM token/SOL pool's stats, then follows the pool for 24 hours.
// The edge report compares outcomes by trait (age, market cap, fee rate, volatility...).
//
// Outcomes are estimates of a single-sided SOL position opened below the price when the pool was first seen, spot shape,
// 69 bins: the pool's fee rate counted only while the price is in that range, minus the loss on SOL converted to the
// token as the price falls. Real results differ: no stop loss or trailing exit is modelled, and fee rates are pool
// averages. Good for comparing kinds of pool, not for promising a return.

import fs from "node:fs";
import { dataPath } from "./context.js";
import { fetchJson } from "../standalone/rpc.js";
import { log } from "../logger.js";

const DISCOVERY = "https://pool-discovery-api.datapi.meteora.ag/pools";
const SOL = "So11111111111111111111111111111111111111112";
const CATEGORIES = ["top", "trending", "new"];
const FLOOR = "pool_type=dlmm&&active_tvl>=1000&&volume>=500";
const KEEP = 5000, FOLLOW_MS = 24 * 3600_000, RANGE_BINS = 69;
export const HORIZONS = [1, 4, 24];

const FILE = () => dataPath("scout.json");
function load() { try { return JSON.parse(fs.readFileSync(FILE(), "utf8")); } catch { return { lastScanAt: 0, pools: [] }; } }
function save(d) {
  d.pools = d.pools.slice(-KEEP);
  fs.mkdirSync(dataPath(), { recursive: true });
  fs.writeFileSync(`${FILE()}.tmp`, JSON.stringify(d));
  fs.renameSync(`${FILE()}.tmp`, FILE());
}
const num = (x) => (Number.isFinite(Number(x)) ? Number(x) : null);

/** The stats of a feed entry that the edge report compares. */
export function features(p, now = Date.now()) {
  const t = p.token_x ?? {};
  return {
    ageH: t.created_at ? Math.round((now - t.created_at) / 360_000) / 10 : null,
    mcap: num(t.market_cap), tvl: num(p.tvl), activeTvl: num(p.active_tvl), fee: num(p.fee), feeRate: num(p.fee_active_tvl_ratio),
    volume: num(p.volume), volumeRate: num(p.volume_active_tvl_ratio), swaps: num(p.swap_count), traders: num(p.unique_traders),
    holders: num(p.base_token_holders), holdersChange: num(p.base_token_holders_change_pct), top10: num(t.top_holders_pct), dev: num(t.dev_balance_pct),
    organic: num(t.organic_score), binStep: num(p.dlmm_params?.bin_step), baseFee: num(p.fee_pct), volatility: num(p.volatility),
    priceChange: num(p.pool_price_change_pct), lps: num(p.total_lps), netDeposits: num(p.net_deposits),
  };
}

/** Would a degen still touch this? Only rug checks and a little substance; the edge report tells us the rest. */
export function isPick(p, f) {
  const t = p.token_x ?? {};
  const danger = (t.warnings ?? []).some((w) => ["critical", "danger"].includes(w.severity));
  return !danger && !p.is_blacklisted && t.has_mint_authority === false && t.has_freeze_authority === false
    && (f.top10 ?? 100) <= 60 && (f.mcap ?? 0) >= 50_000 && (f.activeTvl ?? 0) >= 3000 && (f.feeRate ?? 0) >= 0.5
    && (f.binStep ?? 0) >= 50 && (f.binStep ?? 0) <= 400;
}

/** Scans the feeds; adds pools not already being followed. Returns the new pools. */
export async function scan(fetcher = fetchJson, now = Date.now()) {
  const d = load();
  const following = new Map(d.pools.filter((r) => now - r.at < FOLLOW_MS).map((r) => [r.pool, r]));
  const added = [];
  for (const category of CATEGORIES) {
    const url = `${DISCOVERY}?${new URLSearchParams({ page_size: "50", timeframe: "1h", category, filter_by: FLOOR })}`;
    const res = await fetcher(url);
    for (const p of res.data ?? []) {
      if (p.pool_type !== "dlmm" || p.token_y?.address !== SOL) continue;
      const seen = following.get(p.pool_address);
      if (seen) { if (!seen.cats.includes(category)) seen.cats.push(category); continue; }
      const price = num(p.pool_price);
      if (!(price > 0)) continue;
      const f = features(p, now);
      const rec = { pool: p.pool_address, name: p.name, mint: p.token_x?.address, at: now, cats: [category], f, pick: isPick(p, f),
        price, lower: price * (1 + (f.binStep ?? 100) / 10_000) ** -RANGE_BINS, last: price, low: price, feeSum: 0, checkedAt: now, h: {} };
      d.pools.push(rec);
      following.set(rec.pool, rec);
      added.push(rec);
    }
  }
  d.lastScanAt = now;
  save(d);
  return added;
}

/** New picks as entry signals, best fee rate first: the agent opens these without waiting for wallets to agree. */
export function pickSignals(added, now = Date.now(), deadlineSec = 120) {
  return added.filter((r) => r.pick).sort((a, b) => (b.f.feeRate ?? 0) - (a.f.feeRate ?? 0)).map((r) => ({
    source: "scout", mint: r.mint, pool: r.pool, createdAt: now, deadline: now + deadlineSec * 1000, nextCheck: now, events: [], done: false,
  }));
}

/** A single-sided SOL position's result at `price`, as % of the SOL put in, before fees. Spot shape from entry to lower. */
export function positionLossPct(entry, lower, price) {
  if (price >= entry) return 0;
  const p = Math.max(price, lower);
  const converted = (entry - p) / (entry - lower);
  const avgFill = (entry + p) / 2;
  return -converted * (1 - price / avgFill) * 100;
}

const round1 = (x) => Math.round(x * 10) / 10;

/** One follow-up: adds fees earned while in range since the last check, and records any horizon just reached. */
export function applyCheck(r, poolNow, now = Date.now()) {
  const price = num(poolNow.pool_price);
  if (!(price > 0)) return;
  const inRange = price <= r.price && price >= r.lower;
  const hours = (now - r.checkedAt) / 3600_000;
  // the feed gives the fee rate per 30 minutes (timeframe below): scale to the time since the last check
  if (inRange) r.feeSum += (num(poolNow.fee_active_tvl_ratio) ?? 0) * Math.min(hours * 2, 4);
  r.last = price; r.low = Math.min(r.low, price); r.checkedAt = now;
  const ageH = (now - r.at) / 3600_000;
  for (const h of HORIZONS) {
    if (ageH >= h && !r.h[h]) {
      const loss = positionLossPct(r.price, r.lower, price);
      r.h[h] = { fees: round1(r.feeSum), price: round1((price / r.price - 1) * 100), low: round1((r.low / r.price - 1) * 100), est: round1(r.feeSum + loss) };
    }
  }
}

/** Follows every pool younger than a day. */
export async function follow(fetcher = fetchJson, now = Date.now()) {
  const d = load();
  for (const r of d.pools) {
    if (now - r.at > FOLLOW_MS + 3600_000 || r.h[24]) continue;
    try {
      const url = `${DISCOVERY}?${new URLSearchParams({ page_size: "1", timeframe: "30m", filter_by: `pool_address=${r.pool}` })}`;
      const p = (await fetcher(url)).data?.find((x) => x.pool_address === r.pool);
      if (p) applyCheck(r, p, now);
    } catch (e) { log("scout_warn", `${r.pool.slice(0, 8)}: ${e.message}`); }
  }
  save(d);
}

const median = (a) => { const s = [...a].sort((x, y) => x - y); return s.length ? (s.length % 2 ? s[(s.length - 1) / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2) : null; };
const band = (edges, labels) => (x) => { if (x == null) return null; const i = edges.findIndex((e) => x < e); return labels[i < 0 ? labels.length - 1 : i]; };
const TRAITS = {
  Feed: (r) => r.cats,
  "Our pick": (r) => (r.pick ? "Pick" : "Not a pick"),
  "Token age": (r) => band([6, 24, 72, 336], ["Under 6h", "6-24h", "1-3 days", "3-14 days", "Over 14 days"])(r.f.ageH),
  "Market cap": (r) => band([100e3, 500e3, 2e6], ["Under $100K", "$100K-500K", "$500K-2M", "Over $2M"])(r.f.mcap),
  "Fee rate, 1h": (r) => band([0.5, 2, 5], ["Under 0.5%", "0.5-2%", "2-5%", "Over 5%"])(r.f.feeRate),
  Volatility: (r) => band([2, 5, 10], ["Under 2", "2-5", "5-10", "Over 10"])(r.f.volatility),
  "Bin step": (r) => (r.f.binStep == null ? null : String(r.f.binStep)),
  Organic: (r) => band([40, 70], ["Under 40", "40-70", "Over 70"])(r.f.organic),
  "Top 10 holders": (r) => band([20, 40, 60], ["Under 20%", "20-40%", "40-60%", "Over 60%"])(r.f.top10),
};

/** Outcomes by trait at a horizon: pools, median estimate, share above zero, median fees, share that halved. */
export function edge(pools, horizon = 4) {
  const done = pools.filter((r) => r.h?.[horizon]);
  const out = [];
  for (const [trait, of] of Object.entries(TRAITS)) {
    const buckets = new Map();
    for (const r of done) for (const b of [of(r)].flat()) if (b != null) buckets.set(b, [...(buckets.get(b) ?? []), r.h[horizon]]);
    for (const [bucket, rs] of buckets) {
      out.push({ trait, bucket, n: rs.length, est: round1(median(rs.map((x) => x.est))), winPct: Math.round(rs.filter((x) => x.est > 0).length / rs.length * 100),
        fees: round1(median(rs.map((x) => x.fees))), halvedPct: Math.round(rs.filter((x) => x.low <= -50).length / rs.length * 100) });
    }
  }
  return out;
}

/** The scout's summary for the Agent page. */
export function scoutStats(horizon = 4, limit = 12) {
  const d = load();
  const picks = d.pools.filter((r) => r.pick).slice(-limit).reverse();
  return {
    lastScanAt: d.lastScanAt || null, tracked: d.pools.length, picks: d.pools.filter((r) => r.pick).length, withResults: d.pools.filter((r) => r.h?.[horizon]).length, horizon,
    latest: picks.map((r) => ({ at: r.at, pool: r.pool, name: r.name, cats: r.cats, ageH: r.f.ageH, mcap: r.f.mcap, activeTvl: r.f.activeTvl, feeRate: r.f.feeRate, binStep: r.f.binStep, result: r.h?.[horizon] ?? null })),
    edge: edge(d.pools, horizon),
  };
}
