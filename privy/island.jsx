// Email / Google / Apple sign-in with a PepesFamily wallet (a Privy embedded wallet), for a site that isn't React.
// Mounts Privy in a hidden root and exposes window.PFPrivy, whose wallet is a standard EIP-1193 provider: the site
// uses it exactly like MetaMask, without confirmation windows (embeddedWallets.showWalletUIs: false).
//   PFPrivy.init({ appId, chains, defaultChainId })  -> starts Privy (once)
//   PFPrivy.restore()  -> { provider, address } of a signed-in visitor, or null
//   PFPrivy.connect()  -> signs in (Privy's sign-in window) and resolves with { provider, address }
//   PFPrivy.exportWallet(), PFPrivy.logout()
import React, { useEffect } from "react";
import { createRoot } from "react-dom/client";
import { PrivyProvider, usePrivy, useWallets, useLogin } from "@privy-io/react-auth";
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
  api = { ...p, login, wallets, walletsReady };
  useEffect(changed);
  return null;
}

async function asWallet(w) {
  return { provider: await w.getEthereumProvider(), address: w.address };
}

window.PFPrivy = {
  init({ appId, chains, defaultChainId }) {
    if (this.started) return;
    this.started = true;
    const list = chains.map((c) => defineChain({
      id: c.id, name: c.name, nativeCurrency: { decimals: 18, name: c.native.name, symbol: c.native.symbol },
      rpcUrls: { default: { http: [c.rpc] } }, blockExplorers: { default: { name: "Explorer", url: c.explorer } },
    }));
    const el = document.createElement("div");
    el.id = "privy-root";
    document.body.appendChild(el);
    createRoot(el).render(
      <PrivyProvider appId={appId} config={{
        appearance: { theme: "dark", accentColor: "#8fd66a", logo: location.origin + "/icon-192.png", landingHeader: "Sign in to PepesFamily", showWalletLoginFirst: false },
        embeddedWallets: { ethereum: { createOnLogin: "users-without-wallets" }, showWalletUIs: false },
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
      await new Promise((ok, fail) => { loginDone = { ok, fail }; api.login(); });
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
};
