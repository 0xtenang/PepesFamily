// Standalone orchestrator: monitor → convergence signal → focused screening →
// revalidated deploy → deterministic exits. No Meridian server, no LLM authority.
//
// Entry and exit paths are independent: exits keep running while a signal is
// being screened, and wallet mutations are serialized by the wallet lock
// (close_position > other writes > deploy_position) in standalone/transactions.js.

import fs from "node:fs";
import { config, computeDeployAmount } from "../config.js";
import { log } from "../logger.js";
import { repoPath } from "../repo-root.js";
import { sendMessage as tgSend, isEnabled as tgEnabled } from "../telegram.js";
import { MonitorStore, finishSignal } from "./store.js";
import { WalletMonitor } from "./monitor.js";
import { screenMint, poolDetail } from "./screening.js";
import { exposureStillPresent } from "./events.js";
import { getMyPositions } from "../tools/dlmm.js";
import { executeTool } from "../tools/executor.js";
import { getWalletBalances } from "../tools/wallet.js";
import { getTrackedPositions, confirmPeak, updatePnlAndCheckExits, registerExitSignal, syncOpenPositions } from "../state.js";
import { recordPositionSnapshot } from "../pool-memory.js";
import { getDeterministicCloseRule, computeBinsBelow } from "../exit-rules.js";
import { runAs } from "../pepes/context.js";
import { activeUsers, managedUsers, multiUser, reduceOnly } from "../pepes/users.js";
import { recordSignal, followSignals, followLps } from "../pepes/signals.js";
import { scan as scoutScan, follow as scoutFollow, takePendingPicks, bestPoolSignal, markPassed, markAttempted, freshScreening } from "../pepes/scout.js";

/** Picks from the scout have no wallets behind them. */
const hasNoWallets = (signal) => signal.source === "scout" || signal.source === "best";

/** How a signal is screened: its own pool if it names one, with the fresh lane's checks if it's a fresh pick. */
const screenFor = (signal) => screenMint(signal.mint, {
  ...(signal.pool ? { poolAddress: signal.pool } : {}),
  ...(signal.fresh ? { screening: freshScreening(config.screening) } : {}),
});
import { startAdmin } from "./telegram-admin.js";

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

let store = null;
let monitor = null;
let lockPath = null;
let stopAdmin = null;
let shuttingDown = false;
let manageBusy = false;
let pollBusy = false;
let pursuing = false;
const timers = {};
const signalQueue = [];

async function notify(text) {
  try { if (tgEnabled()) await tgSend(text); } catch { /* notifications are best-effort */ }
}

// ─── Signal pursuit ──────────────────────────────────────────────────────────

function onSignal(signal) {
  signalQueue.push(signal);
  void drainSignals();
}

async function drainSignals() {
  if (pursuing) return;
  pursuing = true;
  try {
    while (signalQueue.length && !shuttingDown) {
      const signal = signalQueue.shift();
      try {
        await pursueSignal(signal);
      } catch (e) {
        finishSignal(store, signal, `error: ${e.message}`, config.standalone);
        log("signal_error", `Signal ${signal.mint.slice(0, 8)} aborted: ${e.message}`);
      }
    }
  } finally {
    pursuing = false;
  }
}

// Screen and enter within the signal deadline. Terminal outcomes finish the
// signal; temporary failures retry every retrySec until the deadline expires.
// PepesAgent: a signal is screened and entered for every active user, each with its own attempt store, caps,
// balance and signer (pepes/context.js). Without users (a local wallet) it runs once, as Meridian does.
async function pursueSignal(signal) {
  if (!multiUser()) return pursueOne(signal, store);
  // The shared record comes first: shadow mode shows it even when nobody has started the agent or deposited.
  const screened = await screenFor(signal).catch(e => ({ pass: false, reason: `screening error: ${e.message}` }));
  try { recordSignal(signal, screened); if (signal.pool) markAttempted(signal.pool); } catch (e) { log("signal_error", `Signal log: ${e.message}`); }
  log("signal", `${signal.mint.slice(0, 8)}: ${screened.pass ? "passed screening" : `rejected (${screened.reason})`}`);
  if (reduceOnly()) { finishSignal(store, signal, "exits only", config.standalone); return; }
  if (screened.pass) { try { markPassed(); } catch (e) { log("signal_error", `Signal log: ${e.message}`); } }
  if (hasNoWallets(signal)) {
    // A rejected pick doesn't wait in the queue retrying: another scan comes in 5 minutes. A kept one gets its full
    // time to enter from now, however long it queued.
    if (!screened.pass) { signal.done = true; return; }
    signal.deadline = Date.now() + config.standalone.screeningDeadlineSec * 1000;
  }
  const users = activeUsers();
  await Promise.all(users.map(u => runAs(u, () => pursueOne({ ...signal, done: false }, u.store)
    .catch(e => log("signal_error", `Signal ${signal.mint.slice(0, 8)} for ${u.address.slice(0, 6)}: ${e.message}`)))));
  finishSignal(store, signal, `pursued for ${users.length} user(s)`, config.standalone);
}

async function pursueOne(signal, st) {
  const wallets = signal.events.map(e => `${e.wallet.slice(0, 6)}(◎${e.depositSol.toFixed(1)})`).join(", ");
  log("signal", hasNoWallets(signal) ? `Scout pick ${signal.mint.slice(0, 8)}: pool ${signal.pool.slice(0, 8)}` : `Convergence on ${signal.mint.slice(0, 8)}: ${signal.events.length} wallets [${wallets}] — screening with ${config.standalone.screeningDeadlineSec}s deadline`);
  let lastReason = "no attempt";
  while (!shuttingDown && !signal.done && Date.now() < signal.deadline) {
    const reason = await attemptEntry(signal, st);
    if (reason == null) return;
    lastReason = reason;
    const wait = Math.min(config.standalone.retrySec * 1000, signal.deadline - Date.now());
    if (wait > 0) await sleep(wait);
  }
  if (!signal.done) {
    finishSignal(st, signal, lastReason, config.standalone);
    log("signal", `Signal ${signal.mint.slice(0, 8)} expired: ${lastReason}`);
  }
}

// One entry attempt. Returns null when the signal is finished (entered,
// terminal rejection, or fatal condition), or a reason string to retry.
async function attemptEntry(signal, st) {
  const mint = signal.mint;
  const attempt = st.data.attempts[mint];
  // One attempt chain per mint; bounded retries only for temporary failures.
  if (attempt && ["entered", "proposed", "submitting"].includes(attempt.status)) {
    finishSignal(st, signal, `mint already attempted (${attempt.status})`, config.standalone);
    return null;
  }
  if (attempt?.status === "failed" && (attempt.failures ?? 0) >= 2) {
    finishSignal(st, signal, "deploy failed repeatedly", config.standalone);
    return null;
  }

  // A failed position read is unavailable data, never "no positions".
  const positions = await getMyPositions({ force: true }).catch(() => null);
  if (!positions || positions.error || !Array.isArray(positions.positions)) return "position read unavailable";
  if (positions.positions.length >= config.risk.maxPositions) {
    finishSignal(st, signal, "portfolio full", config.standalone);
    return null;
  }

  // Focused screening: this mint and its eligible pools only.
  let screened;
  try {
    screened = await screenFor(signal);
  } catch (e) {
    return `screening error: ${e.message}`;
  }
  if (!screened.pass) {
    if (screened.terminal) {
      finishSignal(st, signal, `blocked: ${screened.reason}`, config.standalone);
      return null;
    }
    return screened.reason;
  }

  const gate = await finalRecheck(signal, screened);
  if (gate) return gate;

  const balances = await getWalletBalances({ force: true, nativeOnly: true });
  if (balances.error || !Number.isFinite(balances.sol)) return "balance read unavailable";
  const amountY = computeDeployAmount(balances.sol);
  if (balances.sol < config.management.minSolToOpen + config.management.gasReserve) {
    finishSignal(st, signal, "insufficient spendable SOL", config.standalone);
    return null;
  }

  const pool = screened.pool;
  const binsBelow = computeBinsBelow(pool.volatility);
  // Checkpoint before building anything: a crash mid-sequence leaves a
  // recovery pointer instead of a silent duplicate-entry risk.
  st.data.attempts[mint] = {
    at: Date.now(), mint, pool: pool.pool_address, wallets: signal.events.map(e => e.wallet),
    status: "submitting", failures: attempt?.failures ?? 0, position: null, txs: [],
  };
  st.save();

  let submitted = 0;
  const result = await executeTool("deploy_position", {
    pool_address: pool.pool_address,
    amount_y: amountY,
    bins_below: binsBelow,
    before_submit: async () => {
      // Gate only the first transaction of the sequence. Once creation has
      // been sent, completing the sequence is safer than abandoning a
      // half-built position.
      if (submitted++ > 0) return;
      const fresh = await finalRecheck(signal, screened);
      if (fresh) throw new Error(`Pre-submit recheck failed: ${fresh}`);
    },
    on_prepared: position => {
      st.data.attempts[mint].position = position;
      st.save();
    },
  }).catch(e => ({ error: e.message }));

  const record = st.data.attempts[mint];
  const ok = result && result.success !== false && !result.error && !result.blocked;
  if (ok) {
    record.status = result.dry_run ? "proposed" : "entered";
    record.position = result.position ?? record.position;
    record.txs = result.txs ?? [];
    record.amountSol = amountY;
    st.save();
    finishSignal(st, signal, record.status === "proposed" ? "shadow proposal recorded" : "entered", config.standalone);
    const label = result.dry_run ? "[SHADOW] Would deploy" : "Deployed";
    log("entry", `${label} ${amountY} SOL → pool ${pool.pool_address.slice(0, 8)} mint ${mint.slice(0, 8)} (${binsBelow} bins below, ${signal.events.length}-wallet convergence)`);
    void notify(`${result.dry_run ? "🕯️ Shadow proposal" : "✅ Entry"}: ${amountY} SOL → ${pool.pool_address.slice(0, 8)} (mint ${mint.slice(0, 8)}, ${signal.events.length} wallets)`);
    return null;
  }

  record.status = "failed";
  record.failures = (record.failures ?? 0) + 1;
  record.error = result?.error || result?.reason || "unknown";
  if (Array.isArray(record.txs) && record.txs.length > 0) record.note = "transaction submitted before failure — outcome uncertain";
  st.save();
  return `deploy failed (${record.error})`;
}

// Immediate pre-entry conditions: the triggering wallets still hold their
// exposure, the market has not run away since screening, and spendable funds
// cover the entry. Returns null when everything holds, else the reason.
async function finalRecheck(signal, screened) {
  // A scout pick has no wallets behind it to recheck; the price and funds checks below still apply.
  if (!hasNoWallets(signal)) {
    let present = 0;
    for (const e of signal.events) {
      try { if (await exposureStillPresent(e)) present++; } catch { /* unreadable position = not confirmed */ }
    }
    if (present < config.standalone.walletThreshold) {
      return `wallet exposure gone (${present}/${signal.events.length} remain)`;
    }
  }
  try {
    const fresh = await poolDetail(screened.pool.pool_address);
    const base = Number(screened.pool.pool_price);
    const now = Number(fresh.pool_price);
    if (!(base > 0) || !(now > 0)) return "price unavailable for move check";
    const movePct = Math.abs(now - base) / base * 100;
    if (movePct > config.standalone.maxPriceMovePct) return `price moved ${movePct.toFixed(1)}% since screening`;
  } catch (e) {
    return `fresh pool read failed (${e.message})`;
  }
  const balances = await getWalletBalances({ force: true, nativeOnly: true });
  if (balances.error || !Number.isFinite(balances.sol)) return "balance read unavailable";
  if (balances.sol < config.management.minSolToOpen + config.management.gasReserve) return "insufficient spendable SOL";
  return null;
}

// ─── Exits (deterministic, no LLM) ──────────────────────────────────────────

// One management pass: trailing/rule exits and fee claims. Never triggers
// screening — an empty portfolio just waits for the next convergence signal.
export async function manageOnce() {
  if (manageBusy || shuttingDown) return null;
  manageBusy = true;
  try {
    if (!multiUser()) return await manageFor();
    for (const u of managedUsers()) await runAs(u, () => manageFor().catch(e => log("manage_warn", `${u.address.slice(0, 6)}: ${e.message}`)));
    return null;
  } finally {
    manageBusy = false;
  }
}

// One management pass for the current wallet (the local one, or the user runAs set).
async function manageFor() {
  {
    const live = await getMyPositions({ force: true }).catch(() => null);
    if (!live || live.error || !Array.isArray(live.positions)) {
      log("manage_warn", "Position read unavailable — holding this cycle");
      return null;
    }
    syncOpenPositions(live.positions.map(p => p.position));
    if (live.positions.length === 0) return "No open positions";
    for (const p of live.positions) {
      recordPositionSnapshot(p.pool, p);
      // Slow backstop: raise peaks immediately and act on detected exits.
      // Real-time confirmation lives in the fast poller below.
      confirmPeak(p.position, p.pnl_pct, 1);
      const exit = updatePnlAndCheckExits(p.position, p, config.management);
      const closeRule = exit
        ? { action: "CLOSE", rule: "exit", reason: exit.reason }
        : getDeterministicCloseRule(p, config.management);
      let action = null;
      if (closeRule?.action === "CLOSE") {
        action = { tool: "close_position", args: { position_address: p.position, reason: closeRule.reason }, label: `close (${closeRule.reason})` };
      } else if ((p.unclaimed_fees_usd ?? 0) >= config.management.minClaimAmount) {
        action = { tool: "claim_fees", args: { position_address: p.position }, label: "claim fees" };
      }
      // LLM-set free-text instructions have no execution path in standalone — hold.
      if (!action) continue;
      const res = await executeTool(action.tool, action.args).catch(e => ({ error: e.message }));
      const ok = res?.success !== false && !res?.error && !res?.blocked;
      log("manage", `${p.pair ?? p.position.slice(0, 8)}: ${action.label} ${ok ? "done" : `FAILED — ${res?.error || res?.reason || "unknown"}`}`);
    }
    return null;
  }
}

// Fast exit poller (RPC + Meteora deposits, no LLM). An exit fires only after
// `confirmTicks` consecutive confirming polls; confirmed exits close directly.
function startPnlPoller() {
  const pollMs = Math.max(1, Number(config.pnl.pollIntervalSec ?? 3)) * 1000;
  const confirmTicks = Math.max(1, Number(config.pnl.confirmTicks ?? 2));
  timers.pnl = setInterval(async () => {
    if (manageBusy || pollBusy || shuttingDown) return;
    pollBusy = true;
    try {
      if (!multiUser()) await pollFor(confirmTicks);
      else for (const u of managedUsers()) await runAs(u, () => pollFor(confirmTicks).catch(e => log("poll_warn", `${u.address.slice(0, 6)}: ${e.message}`)));
    } finally {
      pollBusy = false;
    }
  }, pollMs);
}

// One fast exit check for the current wallet.
async function pollFor(confirmTicks) {
  if (getTrackedPositions(true).length === 0) return;
  {
    {
      const live = await getMyPositions({ force: true, silent: true }).catch(() => null);
      if (!live?.positions?.length) return;
      for (const p of live.positions) {
        confirmPeak(p.position, p.pnl_pct, confirmTicks);
        const exit = updatePnlAndCheckExits(p.position, p, config.management);
        const closeRule = exit ? null : getDeterministicCloseRule(p, config.management);
        let signal = null, reason = null;
        if (exit) { signal = exit.action ?? "EXIT"; reason = exit.reason; }
        else if (closeRule) { signal = `RULE_${closeRule.rule}`; reason = closeRule.reason; }
        const { fire } = registerExitSignal(p.position, signal, confirmTicks);
        if (!signal || !fire) continue;
        log("poll", `Exit confirmed (${confirmTicks} ticks): ${p.pair ?? p.position.slice(0, 8)} — ${reason} — closing`);
        manageBusy = true; // hold the slow cycle off this position
        try {
          const res = await executeTool("close_position", { position_address: p.position, reason }).catch(e => ({ error: e.message }));
          const ok = res?.success !== false && !res?.error && !res?.blocked;
          log("poll", `${p.pair ?? p.position.slice(0, 8)}: ${ok ? "closed" : `close FAILED — ${res?.error || res?.reason || "unknown"}`}`);
        } finally {
          manageBusy = false;
        }
        break; // one action per tick
      }
    }
  }
}

// ─── Lifecycle ───────────────────────────────────────────────────────────────

function startHeartbeat() {
  timers.heartbeat = setInterval(() => {
    const stats = monitor?.stats ?? {};
    const active = Object.values(store.data.signals).filter(s => !s.done).length;
    const pending = Object.keys(store.data.pending).length;
    const lag = stats.lastLagMs != null ? `${(stats.lastLagMs / 1000).toFixed(1)}s` : "n/a";
    log("heartbeat", `mode=${config.standalone.shadow ? "shadow" : "live"} | monitor tx=${stats.transactions ?? 0} entries=${stats.entries ?? 0} lag=${lag} pending=${pending} errors=${stats.errors ?? 0} | signals active=${active} queued=${signalQueue.length}`);
    store.prune();
    store.save();
  }, 60_000);
}

function acquireLock() {
  lockPath = repoPath("standalone.lock");
  if (fs.existsSync(lockPath)) {
    const pid = Number(fs.readFileSync(lockPath, "utf8").trim());
    let alive = false;
    try { process.kill(pid, 0); alive = true; } catch { /* not running or invalid pid */ }
    if (alive && pid !== process.pid) throw new Error(`Another standalone instance is running (pid ${pid}) — refusing to start`);
    log("runtime", `Removing stale standalone lock (pid ${pid || "unknown"} is not running)`);
    fs.rmSync(lockPath);
  }
  fs.writeFileSync(lockPath, String(process.pid));
}

async function shutdown(signalName) {
  if (shuttingDown) return;
  shuttingDown = true;
  log("runtime", `${signalName} received — shutting down`);
  for (const timer of Object.values(timers)) clearInterval(timer);
  try { stopAdmin?.(); } catch { /* best-effort */ }
  try { await monitor?.stop(); } catch { /* best-effort */ }
  // Best-effort stop notice; never let a slow Telegram call hold shutdown.
  await Promise.race([notify(`🛑 Meridian stopped (${signalName})`), sleep(3000)]).catch(() => {});
  try { if (lockPath) fs.rmSync(lockPath, { force: true }); } catch { /* best-effort */ }
  process.exit(0);
}

export async function startStandalone() {
  if (!config.standalone.monitorRpcUrl) throw new Error("Standalone requires RPC_URL or MONITOR_RPC_URL");
  acquireLock();

  store = new MonitorStore();
  for (const [mint, attempt] of Object.entries(store.data.attempts)) {
    if (attempt.status === "submitting") {
      log("runtime_warn", `Mint ${mint.slice(0, 8)} was mid-submit at shutdown (position ${attempt.position ?? "unknown"}, txs ${attempt.txs?.length ?? 0}) — reconcile on-chain before re-enabling entries`);
    }
  }

  monitor = new WalletMonitor(store, config.standalone, { onSignal });
  log("runtime", `Standalone starting — ${config.standalone.shadow ? "SHADOW MODE (proposals recorded, nothing submitted)" : "LIVE MODE"} | threshold=${config.standalone.walletThreshold} wallets / ${config.standalone.windowSec}s window | screening deadline=${config.standalone.screeningDeadlineSec}s`);

  await monitor.start();
  if (!monitor.healthy()) {
    log("runtime_warn", "Monitor baseline incomplete — wallets without a portfolio baseline produce no signals until reconciliation succeeds");
  }

  // Entries come only from signals; exits run on their own cadences.
  timers.manage = setInterval(() => { void manageOnce(); }, Math.max(1, config.schedule.managementIntervalMin) * 60_000);
  startPnlPoller();
  startHeartbeat();
  if (multiUser()) {
    const scout = () => void scoutScan().then(added => {
      if (added.length) log("scout", `${added.length} new pool(s), ${added.filter(r => r.pick).length} pick(s)`);
      const picks = takePendingPicks();
      for (const signal of picks) onSignal(signal);
      // Nothing to work with for a while: take the most rewarding pool that qualifies right now.
      if (!picks.length && !signalQueue.length && !pursuing) {
        const best = bestPoolSignal();
        if (best) { log("scout", `No signal for 30 min: trying the best pool ${best.pool.slice(0, 8)}`); onSignal(best); }
      }
    }).catch(e => log("scout_warn", e.message));
    timers.scout = setInterval(scout, 5 * 60_000);
    timers.scoutFollow = setInterval(() => { void scoutFollow().catch(e => log("scout_warn", e.message)); }, 30 * 60_000);
    scout();
  }
  if (multiUser()) timers.signals = setInterval(() => {
    void followSignals().catch(e => log("signals_warn", e.message));
    void followLps().catch(e => log("signals_warn", e.message));
  }, 15 * 60_000);
  void manageOnce();
  stopAdmin = startAdmin({
    monitor,
    activeSignals: () => Object.values(store.data.signals).filter(s => !s.done).length,
  });

  const trackedWallets = Object.keys(store.data.wallets).length;
  void notify(`🤖 Meridian started — ${config.standalone.shadow ? "SHADOW (nothing submitted)" : "LIVE"}\n${trackedWallets} wallet(s) monitored | trigger: ${config.standalone.walletThreshold} within ${config.standalone.windowSec}s | exits: ${config.pnl.pollIntervalSec}s poller`);

  process.on("SIGINT", () => void shutdown("SIGINT"));
  process.on("SIGTERM", () => void shutdown("SIGTERM"));
  log("runtime", `Running — exits every ${config.schedule.managementIntervalMin}m + ${config.pnl.pollIntervalSec}s poller; waiting for wallet convergence`);
}
