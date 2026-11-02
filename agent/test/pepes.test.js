// PepesAgent layer: per-user context, state isolation, dry-run, the wallet queue and the profit fee.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

process.env.DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "pepes-agent-"));
delete process.env.DRY_RUN;

const { runAs, currentUser, userPath, overlay, isDryRun } = await import("../pepes/context.js");
const { realisedProfit, feeAfterLosses } = await import("../pepes/fee.js");
const { withWalletLock } = await import("../standalone/transactions.js");

const alice = { id: "alice", address: "A1", live: true, settings: { risk: { maxPositions: 1 } } };
const bob = { id: "bob", address: "B1", live: false, settings: {} };

test("each user has their own state files", () => {
  const a = runAs(alice, () => userPath("state.json"));
  const b = runAs(bob, () => userPath("state.json"));
  assert.notEqual(a, b);
  assert.ok(a.includes(path.join("users", "alice")));
  assert.equal(userPath("state.json"), path.join(process.env.DATA_DIR, "state.json"));
});

test("a user's settings override the config only inside runAs", () => {
  const risk = overlay("risk", { maxPositions: 3, maxDeployAmount: 50 });
  assert.equal(risk.maxPositions, 3);
  assert.equal(runAs(alice, () => risk.maxPositions), 1);
  assert.equal(runAs(alice, () => risk.maxDeployAmount), 50);
  assert.equal(runAs(bob, () => risk.maxPositions), 3);
});

test("a user who isn't live never sends, whatever DRY_RUN says", () => {
  assert.equal(isDryRun(), false);
  assert.equal(runAs(alice, isDryRun), false);
  assert.equal(runAs(bob, isDryRun), true);
  process.env.DRY_RUN = "true";
  assert.equal(runAs(alice, isDryRun), true);
  delete process.env.DRY_RUN;
});

test("queued wallet work runs as the user who queued it", async () => {
  const seen = [];
  const slow = runAs(alice, () => withWalletLock(async () => { await new Promise(r => setTimeout(r, 20)); seen.push(currentUser()?.id); }));
  const queued = runAs(bob, () => withWalletLock(async () => seen.push(currentUser()?.id)));
  await Promise.all([slow, queued]);
  assert.deepEqual(seen, ["alice", "bob"]);
});

// Fees round down to the lamport, never up.
const near = (actual, expected) => assert.ok(Math.abs(actual - expected) < 2e-9, `${actual} != ${expected}`);

test("a close's result is the smaller of reported and received, and a gain needs both", () => {
  // 1 SOL in, +20% reported, 1.3 SOL back: received 0.24 > reported 0.2
  near(realisedProfit({ amountSol: 1, pnlPct: 20, solBefore: 5, solAfter: 6.3 }), 0.2);
  // reported +20% but only 1.1 SOL came back (swap failed): received 0.04
  near(realisedProfit({ amountSol: 1, pnlPct: 20, solBefore: 5, solAfter: 6.1 }), 0.04);
  near(realisedProfit({ amountSol: 1, pnlPct: -10, solBefore: 5, solAfter: 5.95 }), -0.11);
  assert.equal(realisedProfit({ amountSol: 1, pnlPct: 20, solBefore: NaN, solAfter: 6.3 }), null); // gain unconfirmed
  near(realisedProfit({ amountSol: 1, pnlPct: -20, solBefore: NaN, solAfter: 6.3 }), -0.2);        // a loss still counts
  assert.equal(realisedProfit({ amountSol: NaN, pnlPct: 20, solBefore: 5, solAfter: 6.3 }), null);
});

test("no fee until losses are earned back, and only on what rises above the best", () => {
  let r = feeAfterLosses({ cum: 0, high: 0 }, -1, 10);       // lose 1 SOL
  assert.equal(r.fee, 0);
  r = feeAfterLosses({ cum: r.cum, high: r.high }, 0.5, 10); // make 0.5: still down
  assert.equal(r.fee, 0);
  r = feeAfterLosses({ cum: r.cum, high: r.high }, 1, 10);   // make 1: 0.5 above the best
  near(r.fee, 0.05);
  r = feeAfterLosses({ cum: r.cum, high: r.cum }, -0.2, 10); // fee paid, then a loss
  assert.equal(r.fee, 0);
  r = feeAfterLosses({ cum: r.cum, high: r.high }, 0.3, 10); // only 0.1 is new profit
  near(r.fee, 0.01);
  assert.equal(feeAfterLosses({ cum: 0, high: 0 }, 0.001, 10).fee, 0); // too small to send: charged with a later one
});

test("shadow signal log records results and works out price moves", async () => {
  const { recordSignal, signalStats } = await import("../pepes/signals.js");
  const signal = { mint: "MintA", events: [{}, {}] };
  recordSignal(signal, { pass: false, reason: "Insufficient holders" });
  recordSignal({ ...signal, mint: "MintB" }, { pass: true, token: { symbol: "B" }, pool: { pool_address: "PoolB", name: "B-SOL", pool_price: "2", tvl: 5000 } });
  const st = signalStats();
  assert.equal(st.total, 2);
  assert.equal(st.passed, 1);
  assert.equal(st.recent[0].symbol, "B");
  assert.equal(st.recent[0].movePct, 0);
  assert.equal(st.recent[1].reason, "Insufficient holders");
  assert.equal(st.recent[1].movePct, null);
});

test("wallets of one operator count as one vote", async () => {
  const { qualifyingEvents } = await import("../standalone/store.js");
  const now = Date.now();
  const e = (wallet, id) => ({ id, wallet, mint: "M", at: now - 1000, depositSol: 1 });
  const events = [e("A", "1"), e("B", "2"), e("C", "3")];
  const opts = { windowSec: 120, minDepositSol: 0.1, walletGroups: { A: "op", B: "op" } };
  assert.equal(qualifyingEvents(events.slice(0, 2), "M", opts, now).length, 1); // A and B are one operator
  assert.equal(qualifyingEvents(events, "M", opts, now).length, 2);             // C is independent
});

test("the track record follows the real positions of the LPs behind each signal", async () => {
  const { recordSignal, followLps, signalStats } = await import("../pepes/signals.js");
  const ev = (w) => ({ wallet: w, pool: "P", position: "pos-" + w });
  recordSignal({ mint: "MintC", events: [ev("a"), ev("b")] }, { pass: true, token: {}, pool: { pool_address: "P", pool_price: "1" } });
  recordSignal({ mint: "MintD", events: [ev("c")] }, { pass: false, reason: "no" });
  const data = { a: ["10", true], b: ["-4", true], c: ["-20", false] };
  await followLps(async (lp) => ({ positions: [{ positionAddress: "pos-" + lp.wallet, pnlSolPctChange: data[lp.wallet][0], isClosed: data[lp.wallet][1] }] }));
  const st = signalStats();
  assert.equal(st.recent[1].lpPct, 3);                 // average of the two LPs
  assert.equal(st.recent[1].lpClosed, true);
  assert.equal(st.recent[0].lpClosed, false);          // still open: not counted yet
  assert.deepEqual(st.outcomes.passed, { closed: 1, avgPct: 3, winPct: 100 });
  assert.equal(st.outcomes.rejected.closed, 0);
});

test("Stop ends new positions but the agent keeps looking after open ones", async () => {
  const { saveUsers, activeUsers, managedUsers, reduceOnly } = await import("../pepes/users.js");
  const address = "Gy1Ub83ERYtC4y7PNyTKEbuokZUWnt2TQ4DPaX77anQ";
  saveUsers([{ id: "on", address, walletId: "w1", active: true }, { id: "off", address, walletId: "w2", active: false }, { id: "new" }]);
  assert.deepEqual(activeUsers().map(u => u.id), ["on"]);
  assert.deepEqual(managedUsers().map(u => u.id), ["on", "off"]);
  assert.equal(reduceOnly(), false);
  process.env.AGENT_REDUCE_ONLY = "true";
  assert.equal(reduceOnly(), true);
  delete process.env.AGENT_REDUCE_ONLY;
});

test("scout: scans feeds, follows pools, and reports outcomes by trait", async () => {
  const { scan, applyCheck, positionLossPct, edge, isPick, features } = await import("../pepes/scout.js");
  const t0 = 1_800_000_000_000;
  const pool = (over = {}) => ({ pool_address: "PA", name: "A-SOL", pool_type: "dlmm", pool_price: 1, is_blacklisted: false, active_tvl: 5000, fee_active_tvl_ratio: 1, fee_pct: 1, volatility: 3,
    dlmm_params: { bin_step: 100 }, token_y: { address: "So11111111111111111111111111111111111111112" },
    token_x: { address: "MA", market_cap: 200000, top_holders_pct: 30, organic_score: 50, created_at: t0 - 3600_000, has_mint_authority: false, has_freeze_authority: false, warnings: [] }, ...over });
  assert.equal(isPick(pool(), features(pool(), t0)), true);
  const rug = pool({ token_x: { ...pool().token_x, has_mint_authority: true } });
  assert.equal(isPick(rug, features(rug, t0)), false);
  const notSol = pool({ pool_address: "PB", token_y: { address: "USDC" } });
  assert.equal((await scan(async (url) => ({ data: url.includes("category=top") ? [pool(), notSol] : url.includes("category=new") ? [pool()] : [] }), t0)).length, 1); // once, SOL only

  // losses: none above entry; half the drop at the bottom of a wide range is about right for spot
  assert.equal(positionLossPct(1, 0.5, 1.2), 0);
  assert.ok(Math.abs(positionLossPct(1, 0.5, 0.5) - -33.33) < 0.1);
  assert.ok(positionLossPct(1, 0.5, 0.25) < positionLossPct(1, 0.5, 0.5)); // below the range it keeps falling

  const r = { price: 1, lower: 0.5, last: 1, low: 1, feeSum: 0, at: t0, checkedAt: t0, h: {}, cats: ["top"], f: { ageH: 1, feeRate: 1 }, pick: true };
  applyCheck(r, { pool_price: 0.9, fee_active_tvl_ratio: 2 }, t0 + 3600_000);  // in range: 1h at 2% per 30m = 4%
  assert.equal(r.feeSum, 4);
  assert.equal(r.h[1].price, -10);
  assert.ok(r.h[1].est > 0 && r.h[1].est < 4);
  applyCheck(r, { pool_price: 1.5, fee_active_tvl_ratio: 9 }, t0 + 2 * 3600_000); // above the range: no fees
  assert.equal(r.feeSum, 4);
  applyCheck(r, { pool_price: 1.5, fee_active_tvl_ratio: 9 }, t0 + 4 * 3600_000);
  assert.equal(r.h[4].est, 4);
  const rows = edge([r], 4);
  assert.deepEqual(rows.find((x) => x.trait === "Feed"), { trait: "Feed", bucket: "top", n: 1, est: 4, winPct: 100, fees: 4, halvedPct: 0 });
  assert.equal(rows.find((x) => x.trait === "Token age").bucket, "Under 6h");
});

test("scout picks become entry signals, best fee rate first, with no wallets behind them", async () => {
  const { pickSignals } = await import("../pepes/scout.js");
  const signals = pickSignals([
    { pick: false, mint: "M0", pool: "P0", f: { feeRate: 99 } },
    { pick: true, mint: "M1", pool: "P1", f: { feeRate: 1 } },
    { pick: true, mint: "M2", pool: "P2", f: { feeRate: 5 } },
  ], 1000);
  assert.deepEqual(signals.map((x) => x.pool), ["P2", "P1"]);
  assert.equal(signals[0].source, "scout");
  assert.deepEqual(signals[0].events, []);
  assert.equal(signals[0].deadline, 121_000);
});

test("fresh lane: a token at most 2 hours old with at least $10K TVL, rug checks still on", async () => {
  const { isFresh, isPick, pickSignals, freshScreening, features } = await import("../pepes/scout.js");
  const now = 1_800_000_000_000;
  const pool = (hours, tvl, over = {}) => ({ tvl, active_tvl: tvl, fee_active_tvl_ratio: 0, dlmm_params: { bin_step: 100 }, is_blacklisted: false,
    token_x: { created_at: now - hours * 3600_000, top_holders_pct: 30, has_mint_authority: false, has_freeze_authority: false, warnings: [], market_cap: 1000, ...over } });
  const fresh = (p) => isFresh(p, features(p, now));
  assert.equal(fresh(pool(1.5, 10_000)), true);
  assert.equal(fresh(pool(1.5, 9_999)), false);
  assert.equal(fresh(pool(2.5, 50_000)), false);
  assert.equal(fresh(pool(1, 50_000, { has_mint_authority: true })), false);
  assert.equal(fresh(pool(1, 50_000, { top_holders_pct: 80 })), false);
  assert.equal(fresh(pool(1, 50_000, { warnings: [{ severity: "critical" }] })), false);
  assert.equal(isPick(pool(1, 50_000), features(pool(1, 50_000), now)), false); // no fee history: only the fresh lane takes it
  const s = pickSignals([{ pick: true, mint: "A", pool: "PA", f: { feeRate: 9 } }, { pick: true, fresh: true, mint: "B", pool: "PB", f: { feeRate: 0 } }], now);
  assert.deepEqual(s.map((x) => [x.pool, x.fresh]), [["PB", true], ["PA", false]]);
  const screening = freshScreening({ maxTop10Pct: 60, maxBotHoldersPct: 30, minHolders: 100, minOrganic: 30, minBinStep: 50 });
  assert.equal(screening.maxTop10Pct, 60);       // rug limits untouched
  assert.equal(screening.maxBotHoldersPct, 30);
  assert.equal(screening.minBinStep, 50);
  assert.equal(screening.minOrganic, 0);         // history limits off
  assert.equal(screening.minTvl, 10_000);
});

test("a pool that turns hot becomes a pick, and every pick is tried once, even after a restart", async () => {
  const { scan, takePendingPicks, markAttempted, forgetQueued } = await import("../pepes/scout.js");
  const fs = await import("node:fs");
  fs.rmSync(process.env.DATA_DIR + "/scout.json", { force: true });
  const t0 = 1_900_000_000_000;
  const feed = (feeRate) => ({ pool_address: "PH", name: "H-SOL", pool_type: "dlmm", pool_price: 1, is_blacklisted: false, active_tvl: 5000, fee_active_tvl_ratio: feeRate,
    dlmm_params: { bin_step: 100 }, token_y: { address: "So11111111111111111111111111111111111111112" },
    token_x: { address: "MH", market_cap: 200000, top_holders_pct: 30, created_at: t0 - 86400_000, has_mint_authority: false, has_freeze_authority: false, warnings: [] } });
  const onlyTop = (p) => async (url) => ({ data: url.includes("category=top") ? [p] : [] });
  await scan(onlyTop(feed(0.1)), t0);                 // quiet: tracked, not a pick
  assert.equal(takePendingPicks(t0).length, 0);
  assert.equal((await scan(onlyTop(feed(0.1)), t0 + 300_000)).length, 0); // still quiet: nothing new
  assert.equal((await scan(onlyTop(feed(2)), t0 + 600_000)).length, 1);   // turned hot: a new pick from here
  const first = takePendingPicks(t0 + 600_000);
  assert.deepEqual(first.map((x) => x.pool), ["PH"]);
  assert.equal(takePendingPicks(t0 + 600_000).length, 0);                 // already queued
  forgetQueued();                                                         // a restart empties the queue...
  assert.deepEqual(takePendingPicks(t0 + 600_000).map((x) => x.pool), ["PH"]); // ...and the pick isn't lost
  markAttempted("PH", t0 + 600_000);
  forgetQueued();
  assert.equal(takePendingPicks(t0 + 600_000).length, 0);                 // screened: tried once
  assert.equal((await scan(onlyTop(feed(3)), t0 + 900_000)).length, 0);   // already a pick
});

test("activity score rewards a busy pool and stays within 0-100", async () => {
  const { activityScore } = await import("../pepes/scout.js");
  assert.equal(activityScore({}), 0);
  assert.equal(activityScore({ feeRate: 5, swapsPerMin: 10, positionsCreated: 5, netDeposits: 1 }), 100);
  assert.equal(activityScore({ feeRate: 50, swapsPerMin: 500, positionsCreated: 99, netDeposits: 9 }), 100);
  assert.equal(activityScore({ feeRate: 2.5, netDeposits: -5 }), 20);
});

test("no signal for 30 minutes: the best qualifying pool is tried, once, and it waits after a pass", async () => {
  const { scan, bestPoolSignal, markPassed } = await import("../pepes/scout.js");
  const fs = await import("node:fs");
  fs.rmSync(process.env.DATA_DIR + "/scout.json", { force: true });
  const t0 = 1_950_000_000_000, MIN = 60_000;
  const feed = (pool, feeRate, over = {}) => ({ pool_address: pool, name: pool, pool_type: "dlmm", pool_price: 1, is_blacklisted: false, active_tvl: 5000, fee_active_tvl_ratio: feeRate,
    dlmm_params: { bin_step: 100 }, token_y: { address: "So11111111111111111111111111111111111111112" },
    token_x: { address: "M" + pool, market_cap: 200000, top_holders_pct: 30, created_at: t0 - 86400_000, has_mint_authority: false, has_freeze_authority: false, warnings: [], ...over } });
  await scan(async (url) => ({ data: url.includes("category=top") ? [feed("LOW", 1), feed("HIGH", 4), feed("BEST", 90, { has_mint_authority: true }), feed("QUIET", 0.1)] : [] }), t0);
  assert.equal(bestPoolSignal(t0).pool, "HIGH");          // highest fee rate that qualifies; the mintable one doesn't
  assert.equal(bestPoolSignal(t0).pool, "LOW");           // HIGH was tried: the next best
  assert.equal(bestPoolSignal(t0), null);                 // nothing else qualifies (QUIET doesn't)
  assert.equal(bestPoolSignal(t0 + 6 * 60 * MIN).pool, "HIGH"); // tryable again after 6 hours
  markPassed(t0 + 6 * 60 * MIN);
  assert.equal(bestPoolSignal(t0 + 6 * 60 * MIN + 29 * MIN), null);  // something passed recently: wait
  assert.equal(bestPoolSignal(t0 + 6 * 60 * MIN + 31 * MIN).source, "best");
});

