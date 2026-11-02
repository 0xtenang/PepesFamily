// PepesAgent layer: per-user context, state isolation, dry-run, the wallet queue and the profit fee.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

process.env.DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "pepes-agent-"));
delete process.env.DRY_RUN;

const { runAs, currentUser, userPath, overlay, isDryRun } = await import("../pepes/context.js");
const { feeFor } = await import("../pepes/fee.js");
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

test("profit fee: 10% of the smaller of reported and received profit", () => {
  // 1 SOL in, +20% reported, 1.3 SOL back (incl. ~0.057 rent): received profit 0.24 > reported 0.2 -> 0.02 fee
  near(feeFor({ amountSol: 1, pnlPct: 20, solBefore: 5, solAfter: 6.3, pct: 10 }), 0.02);
  // reported +20% but only 1.1 SOL came back (swap failed): received 0.04 -> 0.004
  near(feeFor({ amountSol: 1, pnlPct: 20, solBefore: 5, solAfter: 6.1, pct: 10 }), 0.004);
  // a loss, a flat close, or missing data: nothing
  assert.equal(feeFor({ amountSol: 1, pnlPct: -10, solBefore: 5, solAfter: 5.95, pct: 10 }), 0);
  assert.equal(feeFor({ amountSol: 1, pnlPct: 0.1, solBefore: 5, solAfter: 6.06, pct: 10 }), 0);
  assert.equal(feeFor({ amountSol: 1, pnlPct: 20, solBefore: NaN, solAfter: 6.3, pct: 10 }), 0);
  assert.equal(feeFor({ amountSol: NaN, pnlPct: 20, solBefore: 5, solAfter: 6.3, pct: 10 }), 0);
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
