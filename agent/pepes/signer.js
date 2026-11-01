// PepesAgent signers: the one thing Meridian's transaction code needs from a wallet.
//
//   signer.publicKey                         the wallet
//   await signer.send(connection, tx, extra) a legacy Transaction (Meteora SDK), co-signed by `extra` keypairs
//                                            (a new position's key), sent and confirmed; returns the signature
//   await signer.signVersioned(vtx)          a VersionedTransaction (Jupiter), signed, not sent (local keys)
//   await signer.sendVersioned(conn, vtx)    the same, signed and sent here (Privy: the policy allows only
//                                            signAndSendTransaction, so Privy users' swaps skip Jupiter's /execute)
//
// LocalSigner holds a key (WALLET_PRIVATE_KEY: the team's own testing). PrivySigner is a user's Privy agent
// wallet: the worker signs with the authorization key the user approved, and Privy's policy decides what may be
// signed (programs, SOL destinations, amounts), so this process can't exceed it.

import { PublicKey, sendAndConfirmTransaction, VersionedTransaction } from "@solana/web3.js";

const SOLANA_MAINNET = "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp";

export class LocalSigner {
  constructor(keypair) {
    this.keypair = keypair;
    this.publicKey = keypair.publicKey;
  }

  send(connection, tx, extra = []) {
    return sendAndConfirmTransaction(connection, tx, [this.keypair, ...extra]);
  }

  async signVersioned(vtx) {
    vtx.sign([this.keypair]);
    return vtx;
  }
}

let _privy = null;
async function privy() {
  if (!_privy) {
    const { PrivyClient } = await import("@privy-io/node");
    if (!process.env.PRIVY_APP_ID || !process.env.PRIVY_APP_SECRET) throw new Error("PRIVY_APP_ID / PRIVY_APP_SECRET not set");
    _privy = new PrivyClient({ appId: process.env.PRIVY_APP_ID, appSecret: process.env.PRIVY_APP_SECRET });
  }
  return _privy;
}

function authorization() {
  const key = process.env.PRIVY_AUTHORIZATION_KEY; // base64 PKCS8, no PEM headers (Privy's format)
  if (!key) throw new Error("PRIVY_AUTHORIZATION_KEY not set");
  return { authorization_private_keys: [key] };
}

export class PrivySigner {
  /** `walletId`: the Privy wallet id of the user's agent wallet; `address`: its Solana address. */
  constructor({ walletId, address }) {
    this.walletId = walletId;
    this.publicKey = new PublicKey(address);
  }

  async send(connection, tx, extra = []) {
    const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash("confirmed");
    tx.feePayer = this.publicKey;
    tx.recentBlockhash = blockhash;
    if (extra.length) tx.partialSign(...extra);
    const transaction = tx.serialize({ requireAllSignatures: false, verifySignatures: false }).toString("base64");
    const res = await (await privy()).wallets().solana().signAndSendTransaction(this.walletId, {
      caip2: SOLANA_MAINNET,
      transaction,
      authorization_context: authorization(),
    });
    const conf = await connection.confirmTransaction({ signature: res.hash, blockhash, lastValidBlockHeight }, "confirmed");
    if (conf.value.err) throw new Error(`Transaction ${res.hash} failed: ${JSON.stringify(conf.value.err)}`);
    return res.hash;
  }

  /** Signs and sends a VersionedTransaction (a Jupiter swap): the policy allows only signAndSendTransaction. */
  async sendVersioned(connection, vtx) {
    const res = await (await privy()).wallets().solana().signAndSendTransaction(this.walletId, {
      caip2: SOLANA_MAINNET,
      transaction: Buffer.from(vtx.serialize()).toString("base64"),
      authorization_context: authorization(),
    });
    const conf = await connection.confirmTransaction(res.hash, "confirmed");
    if (conf.value.err) throw new Error(`Swap ${res.hash} failed: ${JSON.stringify(conf.value.err)}`);
    return res.hash;
  }

  async signVersioned(vtx) {
    const res = await (await privy()).wallets().solana().signTransaction(this.walletId, {
      transaction: Buffer.from(vtx.serialize()).toString("base64"),
      authorization_context: authorization(),
    });
    return VersionedTransaction.deserialize(Buffer.from(res.signed_transaction, "base64"));
  }
}
