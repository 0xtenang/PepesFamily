// Email / Google / Apple sign-in with a PepesFamily wallet (a Privy embedded wallet), for a site that isn't React.
// Mounts Privy in a hidden root and exposes window.PFPrivy, whose wallet is a standard EIP-1193 provider: the site
// uses it exactly like MetaMask, without confirmation windows (embeddedWallets.showWalletUIs: false).
//   PFPrivy.init({ appId, chains, defaultChainId })  -> starts Privy (once)
//   PFPrivy.restore()  -> { provider, address } of a signed-in visitor, or null
//   PFPrivy.connect()  -> signs in (Privy's sign-in window) and resolves with { provider, address }
//   PFPrivy.exportWallet(), PFPrivy.logout()
// PFPrivy.agent (PepesAgent, Solana): sign in with Phantom, a Solana agent wallet, the agent's signer, deposits and
// withdrawals. See the agent methods at the end.
import React, { useEffect } from "react";
import { createRoot } from "react-dom/client";
import { PrivyProvider, usePrivy, useWallets, useLogin, useSigners } from "@privy-io/react-auth";
import { toSolanaWalletConnectors, useWallets as useSolanaWallets, useSignAndSendTransaction, useCreateWallet as useCreateSolanaWallet } from "@privy-io/react-auth/solana";
import {
  address, appendTransactionMessageInstruction, compileTransaction, createNoopSigner, createSolanaRpc, createSolanaRpcSubscriptions,
  createTransactionMessage, getBase58Decoder, getTransactionEncoder, pipe, setTransactionMessageFeePayer, setTransactionMessageLifetimeUsingBlockhash,
} from "@solana/kit";
import { getTransferSolInstruction } from "@solana-program/system";
import { defineChain } from "viem";

let api = null; // the hooks' latest values, set by <Bridge>
const waiters = new Set();
const changed = () => { for (const w of [...waiters]) w(); };
const until = (test) => new Promise((ok) => {
  const check = () => { const v = api && test(api); if (v) { waiters.delete(check); ok(v); } };
  waiters.add(check); check();
});
// Privy not answering (outage, wrong App ID): fail after 20 s instead of waiting forever
const ready = () => Promise.race([until((a) => a.ready),
  new Promise((_, fail) => setTimeout(() => fail(new Error("Sign-in isn't available right now. Try again in a minute.")), 20000))]);
let loginDone = null; // { ok, fail } of the sign-in in progress

const embedded = (a) => a.wallets.find((w) => w.walletClientType === "privy");

function Bridge() {
  const p = usePrivy();
  const { wallets, ready: walletsReady } = useWallets();
  const { login } = useLogin({
    onComplete: () => { loginDone?.ok(); loginDone = null; },
    onError: (e) => { loginDone?.fail(Object.assign(new Error(e === "exited_auth_flow" ? "Sign-in closed" : "Sign-in failed: " + e), { code: 4001 })); loginDone = null; },
  });
  const sol = useSolanaWallets();
  const { signAndSendTransaction } = useSignAndSendTransaction();
  const { addSigners, removeSigners } = useSigners();
  const { createWallet: createSolanaWallet } = useCreateSolanaWallet();
  api = { ...p, login, wallets, walletsReady, solWallets: sol.wallets, solReady: sol.ready, signAndSendTransaction, addSigners, removeSigners, createSolanaWallet };
  useEffect(changed);
  return null;
}

async function asWallet(w) {
  return { provider: await w.getEthereumProvider(), address: w.address };
}

window.PFPrivy = {
  init({ appId, chains, defaultChainId, solanaRpc = "https://api.mainnet-beta.solana.com" }) {
    if (this.started) return;
    this.started = true;
    const list = chains.map((c) => defineChain({
      id: c.id, name: c.name, nativeCurrency: { decimals: 18, name: c.native.name, symbol: c.native.symbol },
      rpcUrls: { default: { http: [c.rpc] } }, blockExplorers: { default: { name: "Explorer", url: c.explorer } },
    }));
    this.solanaRpc = solanaRpc;
    const el = document.createElement("div");
    el.id = "privy-root";
    document.body.appendChild(el);
    createRoot(el).render(
      <PrivyProvider appId={appId} config={{
        appearance: { theme: "dark", accentColor: "#8fd66a", logo: location.origin + "/icon-192.png", landingHeader: "Sign in to PepesFamily", showWalletLoginFirst: false, walletChainType: "ethereum-and-solana" },
        // Solana wallets are made only for PepesAgent users (agent.connect), never on sign-in
        embeddedWallets: { ethereum: { createOnLogin: "users-without-wallets" }, solana: { createOnLogin: "off" }, showWalletUIs: false },
        externalWallets: { solana: { connectors: toSolanaWalletConnectors({ shouldAutoConnect: true }) } },
        solana: { rpcs: { "solana:mainnet": { rpc: createSolanaRpc(solanaRpc), rpcSubscriptions: createSolanaRpcSubscriptions(solanaRpc.replace(/^http/, "ws")) } } },
        supportedChains: list,
        defaultChain: list.find((c) => c.id === defaultChainId) || list[0],
      }}>
        <Bridge />
      </PrivyProvider>,
    );
  },
  async restore() {
    await ready();
    if (!api.authenticated) return null;
    const w = await Promise.race([until((a) => a.walletsReady && embedded(a)), new Promise((ok) => setTimeout(() => ok(null), 8000))]);
    return w ? asWallet(w) : null;
  },
  async connect() {
    await ready();
    if (!api.authenticated) {
      await new Promise((ok, fail) => { loginDone = { ok, fail }; api.login({ walletChainType: "ethereum-only" }); });
    }
    // the wallet is created right after the first sign-in
    const w = await Promise.race([
      until((a) => a.walletsReady && embedded(a)),
      new Promise((_, fail) => setTimeout(() => fail(new Error("Your PepesFamily wallet didn't load. Reload the page and sign in again.")), 30000)),
    ]);
    return asWallet(w);
  },
  async exportWallet() {
    await ready();
    const w = embedded(api);
    return api.exportWallet(w ? { address: w.address } : undefined);
  },
  async logout() {
    await ready();
    await api.logout();
  },
  agent: {
    /** The signed-in visitor's PepesAgent wallets: { phantom, agent: { address, delegated } } (null if signed out). */
    async state() {
      await ready();
      if (!api.authenticated) return null;
      return agentState();
    },
    /** Signs in with Phantom (if needed) and makes the Solana agent wallet (once). */
    async connect() {
      await ready();
      if (!api.authenticated) {
        await new Promise((ok, fail) => { loginDone = { ok, fail }; api.login({ loginMethods: ["wallet"], walletChainType: "solana-only" }); });
      }
      if (!agentState().agent) await api.createSolanaWallet();
      await until((a) => agentState(a).agent);
      return agentState();
    },
    /** Privy access token, for the agent's server to know who is asking. */
    async token() { await ready(); return api.authenticated ? api.getAccessToken() : null; },
    /** Lets the agent's server key (`signerId`, a Privy key quorum) sign for the agent wallet within `policyIds`. */
    async approve(signerId, policyIds) {
      const a = agentState().agent;
      await api.addSigners({ address: a.address, signers: [{ signerId, policyIds }] });
      return agentState();
    },
    /** Removes every signer from the agent wallet: the agent can no longer trade it. */
    async revoke() {
      await api.removeSigners({ address: agentState().agent.address });
      return agentState();
    },
    /** Moves `lamports` SOL from Phantom to the agent wallet (Phantom asks to confirm). Resolves with the signature. */
    deposit: (lamports) => { const s = agentState(); return sendSol(s.phantom, s.agent.address, lamports); },
    /** Moves `lamports` SOL from the agent wallet back to Phantom. */
    withdraw: (lamports) => { const s = agentState(); return sendSol(s.agent.address, s.phantom, lamports); },
  },
};

function agentState(a = api) {
  const sol = (a.user?.linkedAccounts || []).filter((w) => w.type === "wallet" && w.chainType === "solana");
  const agent = sol.find((w) => w.walletClientType === "privy" || w.walletClientType === "privy-v2");
  const phantom = sol.find((w) => w !== agent);
  return { phantom: phantom?.address || null, agent: agent ? { address: agent.address, delegated: !!agent.delegated } : null };
}

async function sendSol(from, to, lamports) {
  const wallet = await Promise.race([until((a) => a.solWallets.find((w) => w.address === from)),
    new Promise((_, fail) => setTimeout(() => fail(new Error("Phantom isn't connected: open Phantom, unlock it and try again.")), 15000))]);
  const rpc = createSolanaRpc(window.PFPrivy.solanaRpc);
  const { value: blockhash } = await rpc.getLatestBlockhash().send();
  const message = pipe(
    createTransactionMessage({ version: 0 }),
    (m) => setTransactionMessageFeePayer(address(from), m),
    (m) => setTransactionMessageLifetimeUsingBlockhash(blockhash, m),
    (m) => appendTransactionMessageInstruction(getTransferSolInstruction({ source: createNoopSigner(address(from)), destination: address(to), amount: BigInt(lamports) }), m),
  );
  const transaction = new Uint8Array(getTransactionEncoder().encode(compileTransaction(message)));
  const { signature } = await api.signAndSendTransaction({ transaction, wallet, chain: "solana:mainnet" });
  return getBase58Decoder().decode(signature);
}

