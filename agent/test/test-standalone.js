/**
 * Unit tests for the standalone wallet-trigger pipeline (no network, no wallet).
 * Run: node test/test-standalone.js
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import bs58 from "bs58";
import { config } from "../config.js";
import { MonitorStore, qualifyingEvents, acceptEvents, finishSignal } from "../standalone/store.js";
import { decodeEvents, transactionEntries } from "../standalone/events.js";
import { aggregateTokenAccounts } from "../standalone/balances.js";
import { rejectToken, rejectPool } from "../standalone/screening.js";
import { withWalletLock } from "../standalone/transactions.js";
import { getDeterministicCloseRule, computeBinsBelow } from "../exit-rules.js";

const options = {
  walletThreshold: 2,
  windowSec: 120,
  screeningDeadlineSec: 120,
  minDepositSol: 0.1,
  cooldownSec: 300,
  walletGroups: {},
};

let failed = 0;
function check(name, cond, detail = "") {
  const ok = !!cond;
  if (!ok) failed++;
  console.log(`${ok ? "  ✓" : "  ✗"} ${name}${!ok && detail ? ` — ${detail}` : ""}`);
}

const MINT = "Mint111111111111111111111111111111111111111";
const POOL_A = "Po01AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const POOL_B = "Po02BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
const W1 = "Wa11eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const W2 = "Wa22eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const W3 = "Wa33eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const pk = s => ({ toString: () => s });

function entry(overrides = {}) {
  return {
    id: `sig:${overrides.wallet ?? W1}:${overrides.position ?? "pos1"}`,
    signature: "sig",
    wallet: W1, position: "pos1", pool: POOL_A, mint: MINT,
    at: Date.now(), slot: 100, depositSol: 1, shares: "1000",
    ...overrides,
  };
}

// ─── Token-level trigger ─────────────────────────────────────────────────────
console.log("\n[1] qualifyingEvents — aggregation, dedup, grouping, dust, expiry");

{
  const now = Date.now();
  const evts = [
    entry({ wallet: W1, pool: POOL_A, position: "p1", at: now - 90_000 }),
    entry({ wallet: W1, pool: POOL_B, position: "p2", at: now - 30_000 }), // same wallet, later counts
    entry({ wallet: W2, pool: POOL_A, position: "p3", at: now - 10_000 }),
  ];
  const q = qualifyingEvents(evts, MINT, options, now);
  check("cross-pool entries by the same wallet count once", q.length === 2 && q.find(e => e.wallet === W1).position === "p2", JSON.stringify(q.map(e => e.position)));

  const grouped = qualifyingEvents([
    entry({ wallet: W1, at: now - 10_000 }),
    entry({ wallet: W2, at: now - 20_000 }),
    entry({ wallet: W3, at: now - 5_000 }),
  ], MINT, { ...options, walletGroups: { [W1]: "op1", [W2]: "op1" } }, now);
  check("wallets sharing an operator group count once", grouped.length === 2 && grouped.every(e => e.wallet !== W2), JSON.stringify(grouped.map(e => e.wallet)));

  check("dust deposits excluded", qualifyingEvents([entry({ wallet: W1, depositSol: 0.01 })], MINT, options, now).length === 0);
  check("events past the window excluded", qualifyingEvents([entry({ wallet: W1, at: now - 121_000 })], MINT, options, now).length === 0);
  check("other mints ignored", qualifyingEvents([entry({ wallet: W1, mint: "Other111111111111111111111111111111111111111" })], MINT, options, now).length === 0);
}

console.log("\n[2] acceptEvents / finishSignal — thresholds, cooldowns, dedup");
{
  const file = path.join(os.tmpdir(), `wm-test-${Date.now()}.json`);
  const store = new MonitorStore(file);
  const now = Date.now();

  const first = acceptEvents(store, [entry({ wallet: W1 })], options, now);
  check("one wallet does not trigger", first.length === 0);

  const second = acceptEvents(store, [entry({ wallet: W2, position: "p3" })], options, now + 1000);
  check("second distinct wallet triggers a signal", second.length === 1 && second[0].mint === MINT);
  check("signal deadline set from screening window", Math.abs(second[0].deadline - (now + 1000 + options.screeningDeadlineSec * 1000)) < 5);

  const third = acceptEvents(store, [entry({ wallet: W3, position: "p4" })], options, now + 2000);
  check("no duplicate signal while one is active", third.length === 0);

  // Duplicate event ids must not inflate anything.
  const dup = acceptEvents(store, [entry({ wallet: W2, position: "p3" })], options, now + 3000);
  check("duplicate event ids ignored", dup.length === 0 && store.data.events.filter(e => e.id === `sig:${W2}:p3`).length === 1);

  finishSignal(store, second[0], "test done", options, now + 4000);
  const stale = acceptEvents(store, [], options, now + 5000);
  check("completed signal not reused within cooldown", stale.length === 0 && second[0].done && second[0].cooldownUntil === now + 4000 + options.cooldownSec * 1000);

  // After the cooldown, only events newer than the close can form a new signal.
  const afterCooldown = now + 4000 + options.cooldownSec * 1000 + 1000;
  const retriggerOld = acceptEvents(store, [entry({ wallet: W3, position: "p5", at: now })], options, afterCooldown);
  check("old events cannot re-trigger after cooldown", retriggerOld.length === 0);
  const retriggerFresh = acceptEvents(store, [
    entry({ wallet: W3, position: "p6", at: afterCooldown - 1000 }),
    entry({ wallet: W1, position: "p7", at: afterCooldown - 500, pool: POOL_B }),
  ], options, afterCooldown);
  check("fresh events re-trigger after cooldown", retriggerFresh.length === 1);

  // Restart recovery: a new store instance must load the same history.
  const reopened = new MonitorStore(file);
  check("state persists across restart", reopened.data.events.length === store.data.events.length && reopened.data.signals[MINT] != null);

  // Attempt records expire after a day (unless mid-submit).
  reopened.data.attempts[MINT] = { at: Date.now() - 25 * 3600_000, status: "failed", failures: 1 };
  reopened.data.attempts["Mint999999999999999999999999999999999999999"] = { at: Date.now() - 25 * 3600_000, status: "submitting" };
  reopened.prune();
  check("attempt records pruned after 24h except mid-submit", reopened.data.attempts[MINT] === undefined && Object.keys(reopened.data.attempts).length === 1);

  fs.rmSync(file, { force: true });
  const bad = path.join(os.tmpdir(), `wm-bad-${Date.now()}.json`);
  fs.writeFileSync(bad, JSON.stringify({ version: 99 }));
  let refused = false;
  try { new MonitorStore(bad); } catch { refused = true; }
  check("invalid monitor state refused, not discarded", refused);
  fs.rmSync(bad, { force: true });
}

// ─── Event decoding ──────────────────────────────────────────────────────────
console.log("\n[3] decodeEvents — only verified DLMM program, only CPI events");
{
  const coder = { decode: payload => {
    const buf = Buffer.from(payload, "base64");
    const kind = buf.subarray(0, 4).toString("utf8");
    if (kind === "ADD1") return { name: "addLiquidity", data: { from: pk(W1), position: pk("pos1"), lbPair: pk(POOL_A), amounts: [{ toString: () => "100000000" }, { toString: () => "500000000" }] } };
    if (kind === "ADD2") return { name: "addLiquidity", data: { from: pk(W2), position: pk("pos2"), lbPair: pk(POOL_A), amounts: [{ toString: () => "100000000" }, { toString: () => "500000000" }] } };
    if (kind === "REMV") return { name: "removeLiquidity", data: {} };
    return null;
  } };
  const cpi = kind => Buffer.concat([Buffer.from([228, 69, 165, 46, 81, 203, 154, 29]), Buffer.from(kind), Buffer.alloc(8)]);
  const PROGRAM = "LBUZKhRxPF3XUpBCjp4YzTKgLccjZhTSDM9YuVaPwxo";
  const OTHER = "Vote111111111111111111111111111111111111111";
  const tx = (instructions, { err = null } = {}) => ({
    blockTime: Math.floor(Date.now() / 1000),
    meta: { err, innerInstructions: [{ index: 0, instructions }] },
    transaction: { message: { staticAccountKeys: [pk(PROGRAM), pk(OTHER)] } },
  });
  const ix = (programIdx, data) => ({ programIdIndex: programIdx, data: bs58.encode(data) });

  const decoded = decodeEvents(tx([ix(0, cpi("ADD1")), ix(1, cpi("ADD2")), ix(0, cpi("REMV"))]), coder);
  check("decodes DLMM CPI events only", decoded.length === 2 && decoded.filter(e => e.name === "addLiquidity").length === 1);
  check("failed transaction yields nothing", decodeEvents(tx([ix(0, cpi("ADD1"))], { err: "x" }), coder).length === 0);
  check("missing blockTime yields nothing", decodeEvents({ ...tx([ix(0, cpi("ADD1"))]), blockTime: null }, coder).length === 0);
  const junk = decodeEvents(tx([{ programIdIndex: 0, data: bs58.encode(Buffer.alloc(32)) }]), coder);
  check("non-CPI instruction data ignored", junk.length === 0);
}

console.log("\n[4] transactionEntries — rebalances, ownership, quote side, dust");
{
  const now = Date.now();
  const coder = { decode: payload => {
    const kind = Buffer.from(payload, "base64").subarray(0, 4).toString("utf8");
    if (kind === "ADD1") return { name: "addLiquidity", data: { from: pk(W1), position: pk("pos1"), lbPair: pk(POOL_A), amounts: [{ toString: () => "100000000" }, { toString: () => "500000000" }] } };
    if (kind === "DUST") return { name: "addLiquidity", data: { from: pk(W1), position: pk("pos1"), lbPair: pk(POOL_A), amounts: [{ toString: () => "1000000" }, { toString: () => "10000000" }] } };
    if (kind === "REMV") return { name: "removeLiquidity", data: {} };
    return null;
  } };
  const cpi = kind => Buffer.concat([Buffer.from([228, 69, 165, 46, 81, 203, 154, 29]), Buffer.from(kind), Buffer.alloc(8)]);
  const inner = kind => [{ index: 0, instructions: [{ programIdIndex: 0, data: bs58.encode(cpi(kind)) }] }];
  const snapshot = async (position, wallet, pool) => wallet === W1 && pool === POOL_A ? {
    shares: "1000", xMint: MINT, yMint: config.tokens.SOL, lower: 50, upper: 90, active: 60, inRange: true,
  } : null;
  const DLMM = "LBUZKhRxPF3XUpBCjp4YzTKgLccjZhTSDM9YuVaPwxo";
  const tx = (kind = "ADD1", extra = {}) => ({
    meta: { err: null, innerInstructions: inner(kind) },
    transaction: { message: { staticAccountKeys: [pk(DLMM)] } },
    blockTime: Math.floor(now / 1000) - 3, slot: 500, ...extra,
  });

  const entries = await transactionEntries(tx(), "sig", W1, options, snapshot, coder, now);
  check("valid SOL-side deposit extracted", entries.length === 1 && entries[0].mint === MINT && Math.abs(entries[0].depositSol - 0.5) < 1e-9);

  check("stale transaction ignored", (await transactionEntries(tx("ADD1", { blockTime: Math.floor(now / 1000) - 500 }), "sig", W1, options, snapshot, coder, now)).length === 0);
  check("other wallet's deposit ignored", (await transactionEntries(tx(), "sig", W2, options, snapshot, coder, now)).length === 0);
  check("position snapshot mismatch ignored", (await transactionEntries(tx(), "sig", W1, options, async () => null, coder, now)).length === 0);

  const removeThenAdd = [{ index: 0, instructions: [
    { programIdIndex: 0, data: bs58.encode(cpi("REMV")) },
    { programIdIndex: 0, data: bs58.encode(cpi("ADD1")) },
  ] }];
  check("withdraw-and-redeposit is not an entry", (await transactionEntries({ ...tx(), meta: { err: null, innerInstructions: removeThenAdd } }, "sig", W1, options, snapshot, coder, now)).length === 0);

  check("dust deposit filtered", (await transactionEntries(tx("DUST"), "sig", W1, options, snapshot, coder, now)).length === 0);

  const tokenOnly = async () => ({ shares: "1000", xMint: MINT, yMint: "Othr111111111111111111111111111111111111111", lower: 50, upper: 90, active: 60, inRange: true });
  check("token-only (inventory) pair filtered", (await transactionEntries(tx(), "sig", W1, options, tokenOnly, coder, now)).length === 0);
}

// ─── Balances ────────────────────────────────────────────────────────────────
console.log("\n[5] aggregateTokenAccounts — SPL + Token-2022, no phantom zeros");
{
  const acct = (mint, amount, decimals) => ({ account: { data: { parsed: { info: { mint, tokenAmount: { amount: String(amount), decimals } } } } } });
  const tokens = aggregateTokenAccounts([
    { value: [acct(MINT, 1000, 6), acct(config.tokens.USDC, 0, 6)] },
    { value: [acct(MINT, 2500, 6)] },
  ]);
  check("same mint aggregated across programs", tokens.length === 1 && tokens[0].balance === 0.0035 && tokens[0].mint === MINT);
  check("zero-balance accounts dropped", !tokens.some(t => t.mint === config.tokens.USDC));
  let conflicted = false;
  try { aggregateTokenAccounts([{ value: [acct(MINT, 1, 6)] }, { value: [acct(MINT, 1, 9)] }]); } catch { conflicted = true; }
  check("conflicting decimals rejected", conflicted);
}

// ─── Screening gates ─────────────────────────────────────────────────────────
console.log("\n[6] rejectToken / rejectPool — missing data never passes");
{
  const now = Date.now();
  const base = {
    id: MINT, updatedAt: new Date(now - 10_000).toISOString(),
    audit: { mintAuthorityDisabled: true, freezeAuthorityDisabled: true, topHoldersPercentage: 30, botHoldersPercentage: 10 },
    fees: 50, launchpad: null, holderCount: 800, mcap: 400_000, organicScore: 75,
    createdAt: new Date(now - 3 * 3600_000).toISOString(),
  };
  check("healthy token passes", rejectToken(base, MINT, config.screening, now) === null);
  check("mint mismatch rejected", rejectToken(base, POOL_A, config.screening, now) !== null);
  check("stale token data rejected", rejectToken({ ...base, updatedAt: new Date(now - 300_000).toISOString() }, MINT, config.screening, now) !== null);
  check("missing audit rejected", rejectToken({ ...base, audit: undefined }, MINT, config.screening, now) !== null);
  check("mint authority still enabled rejected", rejectToken({ ...base, audit: { ...base.audit, mintAuthorityDisabled: false } }, MINT, config.screening, now) !== null);
  check("unknown holder concentration rejected", rejectToken({ ...base, audit: { ...base.audit, topHoldersPercentage: null } }, MINT, config.screening, now) !== null);

  const pool = {
    pool_type: "dlmm", is_blacklisted: false,
    token_x: { address: MINT, warnings: [] },
    token_y: { address: config.tokens.SOL, warnings: [], organic_score: 75 },
    tvl: 50_000, active_tvl: 40_000, volume: 5_000, fee_active_tvl_ratio: 0.1,
    dlmm_params: { bin_step: 100 }, volatility: 3.2, pool_price: 1.5,
  };
  check("healthy pool passes", rejectPool(pool, MINT, config.screening) === null);
  check("wrong pool type rejected", rejectPool({ ...pool, pool_type: "clmm" }, MINT, config.screening) !== null);
  check("wrong quote side rejected", rejectPool({ ...pool, token_y: { ...pool.token_y, address: "USDTMint11111111111111111111111111111111111" } }, MINT, config.screening) !== null);
  check("pool token warning rejected", rejectPool({ ...pool, token_x: { ...pool.token_x, warnings: [{ severity: "danger" }] } }, MINT, config.screening) !== null);
  check("unknown TVL rejected", rejectPool({ ...pool, tvl: null }, MINT, config.screening) !== null);
  check("TVL above cap rejected", rejectPool({ ...pool, tvl: 10_000_000 }, MINT, config.screening) !== null);
}

// ─── Coordination + rules ────────────────────────────────────────────────────
console.log("\n[7] withWalletLock — exits jump the queue, never concurrent");
{
  const order = [];
  const job = (label, ms) => async () => { order.push(`start:${label}`); await new Promise(r => setTimeout(r, ms)); order.push(`end:${label}`); };
  const first = withWalletLock(job("deploy", 40), 0);
  const second = withWalletLock(job("close", 1), 10);
  const third = withWalletLock(job("claim", 1), 5);
  await Promise.all([first, second, third]);
  check("serialized execution", order[0] === "start:deploy" && order[1] === "end:deploy");
  check("exit priority runs before other writes", order[2] === "start:close" && order[4] === "start:claim");
}

console.log("\n[8] deterministic rules");
{
  const pos = base => ({ position: "Pos111111111111111111111111111111111111111", pair: "T/SOL", pnl_pct: 0, active_bin: 100, upper_bin: 100, minutes_out_of_range: 0, age_minutes: 90, fee_per_tvl_24h: 10, ...base });
  const mgmt = { ...config.management };
  check("stop loss closes", getDeterministicCloseRule(pos({ pnl_pct: -60 }), mgmt)?.rule === 1);
  check("take profit closes", getDeterministicCloseRule(pos({ pnl_pct: 10 }), mgmt)?.rule === 2);
  check("pumped far above range closes", getDeterministicCloseRule(pos({ active_bin: 130 }), mgmt)?.rule === 3);
  check("suspect PnL never closes on PnL rules", getDeterministicCloseRule(pos({ pnl_pct: -95, pnl_pct_suspicious: true }), mgmt) === null);

  const lo = config.strategy.minBinsBelow, hi = config.strategy.maxBinsBelow;
  const tiny = computeBinsBelow(0.01), mid = computeBinsBelow(2.5), huge = computeBinsBelow(50);
  check("bins scale with volatility and clamp", tiny === lo && mid > lo && mid < hi && huge === hi);
  let threw = false;
  try { computeBinsBelow(null); } catch { threw = true; }
  check("unknown volatility refuses to deploy", threw);
}

console.log(failed === 0 ? "\nALL TESTS PASSED" : `\n${failed} TEST(S) FAILED`);
process.exit(failed === 0 ? 0 : 1);
