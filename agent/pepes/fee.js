// PepesAgent's fee: a share (FEE_PCT, 10%) of the realised profit of each closed position, sent in SOL to
// FEE_ADDRESS. Nothing on deposits, withdrawals, losses or open positions.
//
// The profit is the smaller of two measures, so a user is never charged more than they made:
//   reported  Meteora's PnL % for the position x the SOL deployed
//   received  the SOL the close (and its swap back to SOL) actually brought in, minus the SOL deployed and an
//             allowance for the position account's rent, which is refunded on close but isn't profit
// Missing or non-positive either way: no fee.

import { PublicKey, SystemProgram, Transaction, Connection, LAMPORTS_PER_SOL } from "@solana/web3.js";
import fs from "node:fs";
import { currentUser, isDryRun, userPath } from "./context.js";
import { log } from "../logger.js";

export const FEE_PCT = Number(process.env.FEE_PCT ?? 10);
/** The PepesFamily team's Solana fee wallet (public); FEE_ADDRESS overrides it. */
export const FEE_ADDRESS = process.env.FEE_ADDRESS || "Gy1Ub83ERYtC4y7PNyTKEbuokZUWnt2TQ4DPaX77anQ";
const RENT_ALLOWANCE_SOL = 0.06; // a DLMM position account's rent is about 0.057 SOL
const MIN_FEE_SOL = 0.0005;      // smaller fees cost more in network fees than they bring

/** The fee for one close, in SOL (0 when there is nothing to charge). Pure, for tests. */
export function feeFor({ amountSol, pnlPct, solBefore, solAfter, pct = FEE_PCT }) {
  if (![amountSol, pnlPct, solBefore, solAfter].every(Number.isFinite) || !(amountSol > 0)) return 0;
  const reported = amountSol * pnlPct / 100;
  const received = solAfter - solBefore - amountSol - RENT_ALLOWANCE_SOL;
  const profit = Math.min(reported, received);
  if (!(profit > 0)) return 0;
  const fee = profit * pct / 100;
  return fee >= MIN_FEE_SOL ? Math.floor(fee * 1e9) / 1e9 : 0;
}

/** Takes the fee for a close the current user just made. Never throws: a failed fee is logged, not retried. */
export async function takeProfitFee({ position, amountSol, pnlPct, solBefore, solAfter }) {
  const user = currentUser();
  const to = FEE_ADDRESS;
  if (!user || !to || isDryRun()) return null;
  const sol = feeFor({ amountSol, pnlPct, solBefore, solAfter });
  if (!sol) return null;
  try {
    const conn = new Connection(process.env.RPC_URL, "confirmed");
    const tx = new Transaction().add(SystemProgram.transfer({
      fromPubkey: user.signer.publicKey,
      toPubkey: new PublicKey(to),
      lamports: Math.round(sol * LAMPORTS_PER_SOL),
    }));
    const sig = await user.signer.send(conn, tx);
    record({ at: new Date().toISOString(), position, sol, pnlPct, amountSol, tx: sig });
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
