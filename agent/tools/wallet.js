import {
  Connection,
  PublicKey,
  LAMPORTS_PER_SOL,
  VersionedTransaction,
  Keypair,
  TransactionInstruction,
  TransactionMessage,
  AddressLookupTableAccount,
  ComputeBudgetProgram,
} from "@solana/web3.js";
import { currentUser, isDryRun } from "../pepes/context.js";
import { LocalSigner } from "../pepes/signer.js";
import bs58 from "bs58";
import { rpcBalances, priceBalances } from "../standalone/balances.js";
import { log } from "../logger.js";
import { config } from "../config.js";

let _connection = null;
let _wallet = null;

function getConnection() {
  if (!_connection) _connection = new Connection(process.env.RPC_URL, "confirmed");
  return _connection;
}

/// The current PepesAgent user's signer, else the local WALLET_PRIVATE_KEY (see tools/dlmm.js).
function getWallet() {
  const user = currentUser();
  if (user) return user.signer;
  if (!_wallet) {
    if (!process.env.WALLET_PRIVATE_KEY) throw new Error("WALLET_PRIVATE_KEY not set");
    _wallet = new LocalSigner(Keypair.fromSecretKey(bs58.decode(process.env.WALLET_PRIVATE_KEY)));
  }
  return _wallet;
}

// PepesAgent: a swap transaction from Jupiter's /build response, for wallets that send their own (see sendBuiltSwap).
export function swapTxFromBuild(build, payer, blockhash, unitLimit) {
  const ix = (i) => new TransactionInstruction({
    programId: new PublicKey(i.programId),
    keys: i.accounts.map(a => ({ pubkey: new PublicKey(a.pubkey), isSigner: a.isSigner, isWritable: a.isWritable })),
    data: Buffer.from(i.data, "base64"),
  });
  const isUnitLimit = (i) => i.programId === ComputeBudgetProgram.programId.toString() && Buffer.from(i.data, "base64")[0] === 2;
  const instructions = [
    ComputeBudgetProgram.setComputeUnitLimit({ units: unitLimit }),
    ...(build.computeBudgetInstructions ?? []).filter(i => !isUnitLimit(i)).map(ix),
    ...(build.setupInstructions ?? []).map(ix),
    ix(build.swapInstruction),
    ...(build.cleanupInstruction ? [ix(build.cleanupInstruction)] : []),
    ...(build.otherInstructions ?? []).map(ix),
  ];
  const tables = Object.entries(build.addressesByLookupTableAddress ?? {}).map(([key, addresses]) => new AddressLookupTableAccount({
    key: new PublicKey(key),
    state: { deactivationSlot: 2n ** 64n - 1n, lastExtendedSlot: 0, lastExtendedSlotStartIndex: 0, addresses: addresses.map(a => new PublicKey(a)) },
  }));
  return new VersionedTransaction(new TransactionMessage({ payerKey: payer, recentBlockhash: blockhash, instructions }).compileToV0Message(tables));
}

// /order transactions are made for Jupiter's /execute (some routes need a market maker's signature); a Privy agent
// wallet's policy allows only signAndSendTransaction, so it swaps through /build, which is made to be sent by the wallet.
async function sendBuiltSwap(wallet, connection, { input_mint, output_mint, amountStr, apiKey }) {
  const search = new URLSearchParams({ inputMint: input_mint, outputMint: output_mint, amount: amountStr, taker: wallet.publicKey.toString(), slippageBps: "300" });
  const res = await fetch(`${JUPITER_SWAP_V2_API}/build?${search}`, { headers: apiKey ? { "x-api-key": apiKey } : {} });
  if (!res.ok) throw new Error(`Swap V2 build failed: ${res.status} ${await res.text()}`);
  const build = await res.json();
  if (!build.swapInstruction) throw new Error(`Swap V2 build error: ${build.error || build.errorMessage || "no route"}`);
  const { blockhash } = await connection.getLatestBlockhash("confirmed");
  const sim = await connection.simulateTransaction(swapTxFromBuild(build, wallet.publicKey, blockhash, 1_400_000), { sigVerify: false, replaceRecentBlockhash: true });
  if (sim.value.err) throw new Error(`Swap simulation failed: ${JSON.stringify(sim.value.err)}`);
  const units = Math.min(1_400_000, Math.ceil((sim.value.unitsConsumed || 1_000_000) * 1.2));
  const sig = await wallet.sendVersioned(connection, swapTxFromBuild(build, wallet.publicKey, blockhash, units));
  return { sig, outAmount: build.outAmount ?? null };
}

const JUPITER_PRICE_API = "https://api.jup.ag/price/v3";
const JUPITER_SWAP_V2_API = "https://api.jup.ag/swap/v2";
const DEFAULT_JUPITER_API_KEY = "b15d42e9-e0e4-4f90-a424-ae41ceeaa382";

function getJupiterApiKey() {
  return config.jupiter.apiKey || process.env.JUPITER_API_KEY || DEFAULT_JUPITER_API_KEY;
}

function getJupiterReferralParams() {
  const referralAccount = String(config.jupiter.referralAccount || "").trim();
  const referralFee = Number(config.jupiter.referralFeeBps || 0);
  if (!referralAccount || !Number.isFinite(referralFee) || referralFee <= 0) {
    return null;
  }
  if (referralFee < 50 || referralFee > 255) {
    log("swap_warn", `Ignoring Jupiter referral fee ${referralFee}; Ultra requires 50-255 bps`);
    return null;
  }
  try {
    new PublicKey(referralAccount);
  } catch {
    log("swap_warn", "Ignoring invalid Jupiter referral account");
    return null;
  }
  return { referralAccount, referralFee: Math.round(referralFee) };
}

/** Standard RPC balances; native SOL and wrapped SOL remain separate. */
export async function getWalletBalances(options = {}) {
  try {
    const walletAddress = currentUser()?.address || config.standalone.walletAddress || getWallet().publicKey.toString();
    const raw = await rpcBalances(walletAddress, options);
    return options.nativeOnly ? raw : await priceBalances(raw);
  } catch (error) {
    return { wallet: null, sol: null, sol_price: null, sol_usd: null, usdc: null, tokens: [], total_usd: null, error: error.message };
  }
}

/**
 * Swap tokens via Jupiter Swap API V2 (order → sign → execute).
 */
const SOL_MINT = "So11111111111111111111111111111111111111112";

// Normalize any SOL-like address to the correct wrapped SOL mint
export function normalizeMint(mint) {
  if (!mint) return mint;
  const SOL_MINT = "So11111111111111111111111111111111111111112";
  if (
    mint === "SOL" || 
    mint === "native" || 
    /^So1+$/.test(mint) || 
    (mint.length >= 32 && mint.length <= 44 && mint.startsWith("So1") && mint !== SOL_MINT)
  ) {
    return SOL_MINT;
  }
  return mint;
}

export async function swapToken({
  input_mint,
  output_mint,
  amount,
}) {
  input_mint  = normalizeMint(input_mint);
  output_mint = normalizeMint(output_mint);

  if (isDryRun()) {
    return {
      dry_run: true,
      would_swap: { input_mint, output_mint, amount },
      message: "DRY RUN — no transaction sent",
    };
  }

  try {
    log("swap", `${amount} of ${input_mint} → ${output_mint}`);
    const wallet = getWallet();
    const connection = getConnection();

    // ─── Convert to smallest unit ──────────────────────────────
    let decimals = 9; // SOL default
    if (input_mint !== config.tokens.SOL) {
      const mintInfo = await connection.getParsedAccountInfo(new PublicKey(input_mint));
      decimals = mintInfo.value?.data?.parsed?.info?.decimals ?? 9;
    }
    const amountStr = Math.floor(amount * Math.pow(10, decimals)).toString();

    if (wallet.sendVersioned) {
      const { sig, outAmount } = await sendBuiltSwap(wallet, connection, { input_mint, output_mint, amountStr, apiKey: getJupiterApiKey() });
      log("swap", `SUCCESS tx: ${sig}`);
      return { success: true, tx: sig, input_mint, output_mint, amount_in: amountStr, amount_out: outAmount };
    }

    // ─── Get Swap V2 order (unsigned tx + requestId) ───────────
    const search = new URLSearchParams({
      inputMint: input_mint,
      outputMint: output_mint,
      amount: amountStr,
      taker: wallet.publicKey.toString(),
    });
    const referralParams = getJupiterReferralParams();
    if (referralParams) {
      search.set("referralAccount", referralParams.referralAccount);
      search.set("referralFee", String(referralParams.referralFee));
    }
    const orderUrl = `${JUPITER_SWAP_V2_API}/order?${search.toString()}`;
    const jupiterApiKey = getJupiterApiKey();

    const orderRes = await fetch(orderUrl, {
      headers: jupiterApiKey ? { "x-api-key": jupiterApiKey } : {},
    });
    if (!orderRes.ok) {
      const body = await orderRes.text();
      throw new Error(`Swap V2 order failed: ${orderRes.status} ${body}`);
    }

    const order = await orderRes.json();
    if (order.errorCode || order.errorMessage) {
      throw new Error(`Swap V2 order error: ${order.errorMessage || order.errorCode}`);
    }

    const { transaction: unsignedTx, requestId } = order;

    // ─── Deserialize and sign ─────────────────────────────────
    const tx = await wallet.signVersioned(VersionedTransaction.deserialize(Buffer.from(unsignedTx, "base64")));
    const signedTx = Buffer.from(tx.serialize()).toString("base64");

    // ─── Execute ───────────────────────────────────────────────
    const execRes = await fetch(`${JUPITER_SWAP_V2_API}/execute`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(jupiterApiKey ? { "x-api-key": jupiterApiKey } : {}),
      },
      body: JSON.stringify({ signedTransaction: signedTx, requestId }),
    });
    if (!execRes.ok) {
      throw new Error(`Swap V2 execute failed: ${execRes.status} ${await execRes.text()}`);
    }

    const result = await execRes.json();
    if (result.status === "Failed") {
      throw new Error(`Swap failed on-chain: code=${result.code}`);
    }

    log("swap", `SUCCESS tx: ${result.signature}`);
    if (referralParams && order.feeBps !== referralParams.referralFee) {
      log(
        "swap_warn",
        `Jupiter referral fee requested ${referralParams.referralFee} bps but order applied ${order.feeBps ?? "unknown"} bps`,
      );
    }

    return {
      success: true,
      tx: result.signature,
      input_mint,
      output_mint,
      amount_in: result.inputAmountResult,
      amount_out: result.outputAmountResult,
      referral_account: referralParams?.referralAccount || null,
      referral_fee_bps_requested: referralParams?.referralFee || 0,
      fee_bps_applied: order.feeBps ?? null,
      fee_mint: order.feeMint ?? null,
    };
  } catch (error) {
    log("swap_error", error.message);
    return { success: false, error: error.message };
  }
}
