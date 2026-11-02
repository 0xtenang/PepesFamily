// PepesAgent's fee: a share (FEE_PCT, 10%) of a user's realised profit above their previous best, sent in SOL to
// FEE_ADDRESS when a position closes. Losses carry forward: nothing is charged until they're earned back. Nothing on
// deposits, withdrawals or open positions.
//
// A close's result is the smaller of two measures, so a user is never charged more than they made:
//   reported  Meteora's PnL % for the position x the SOL deployed
//   received  the SOL the close (and its swap back to SOL) actually brought in, minus the SOL deployed and an
//             allowance for the position account's rent, which is refunded on close but isn't profit

import { PublicKey, SystemProgram, Transaction, Connection, LAMPORTS_PER_SOL } from "@solana/web3.js";
import fs from "node:fs";
import { currentUser, isDryRun, userPath } from "./context.js";
import { log } from "../logger.js";

export const FEE_PCT = Number(process.env.FEE_PCT ?? 10);
/** The PepesFamily team's Solana fee wallet (public); FEE_ADDRESS overrides it. */
export const FEE_ADDRESS = process.env.FEE_ADDRESS || "Gy1Ub83ERYtC4y7PNyTKEbuokZUWnt2TQ4DPaX77anQ";
const RENT_ALLOWANCE_SOL = 0.06; // a DLMM position account's rent is about 0.057 SOL
const MIN_FEE_SOL = 0.0005;      // smaller fees cost more in network fees than they bring

/** One close's realised result in SOL: the smaller of both measures, or the one known loss; null if unknown. Pure. */
export function realisedProfit({ amountSol, pnlPct, solBefore, solAfter }) {
  if (!Number.isFinite(amountSol) || !(amountSol > 0)) return null;
  const reported = Number.isFinite(pnlPct) ? amountSol * pnlPct / 100 : null;
  const received = Number.isFinite(solBefore) && Number.isFinite(solAfter) ? solAfter - solBefore - amountSol - RENT_ALLOWANCE_SOL : null;
  if (reported != null && received != null) return Math.min(reported, received);
  const known = reported ?? received;
  return known != null && known < 0 ? known : null; // a gain needs both measures to agree; a loss counts on either
}

/**
 * The fee once `profit` is added to a user's running result. `high` is the running result at the last fee: only what
 * rises above it is charged, so losses have to be earned back before any fee. Rounds down to the lamport. Pure.
 */
export function feeAfterLosses({ cum = 0, high = 0 }, profit, pct = FEE_PCT) {
  const next = cum + profit;
  const fee = Math.max(0, next - high) * pct / 100;
  return { cum: next, high, fee: fee >= MIN_FEE_SOL ? Math.floor(fee * 1e9) / 1e9 : 0 };
}

function loadResult() {
  try { return JSON.parse(fs.readFileSync(userPath("result.json"), "utf8")); } catch { return { cum: 0, high: 0 }; }
}
const saveResult = (r) => fs.writeFileSync(userPath("result.json"), JSON.stringify(r));

/** Adds a close the current user just made to their result and takes any fee due. Never throws. A fee that fails or is
 *  too small leaves `high` where it was, so that profit is charged with the next one. */
export async function takeProfitFee({ position, amountSol, pnlPct, solBefore, solAfter }) {
  const user = currentUser();
  if (!user || isDryRun()) return null;
  const profit = realisedProfit({ amountSol, pnlPct, solBefore, solAfter });
  if (profit == null) { log("fee_warn", `${user.address.slice(0, 6)}: result of ${position.slice(0, 8)} unknown, no fee`); return null; }
  const { cum, high, fee: sol } = feeAfterLosses(loadResult(), profit);
  saveResult({ cum, high });
  if (!sol) return null;
  try {
    const conn = new Connection(process.env.RPC_URL, "confirmed");
    const tx = new Transaction().add(SystemProgram.transfer({
      fromPubkey: user.signer.publicKey,
      toPubkey: new PublicKey(FEE_ADDRESS),
      lamports: Math.round(sol * LAMPORTS_PER_SOL),
    }));
    const sig = await user.signer.send(conn, tx);
    saveResult({ cum, high: cum });
    record({ at: new Date().toISOString(), position, sol, profit, cum, tx: sig });
    log("fee", `${user.address.slice(0, 6)}: ${FEE_PCT}% profit fee ${sol} SOL on ${position.slice(0, 8)} (${sig})`);
    return { sol, tx: sig };
  } catch (e) {
    log("fee_warn", `${user.address.slice(0, 6)}: profit fee on ${position.slice(0, 8)} not taken: ${e.message}`);
    return null;
  }
}

function record(entry) {
  const file = userPath("fees.json");
  let list = [];
  try { list = JSON.parse(fs.readFileSync(file, "utf8")); } catch { /* first fee */ }
  list.push(entry);
  fs.writeFileSync(file, JSON.stringify(list, null, 2));
}
