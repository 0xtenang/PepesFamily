# MemeLev web app

Trading app for MemeLev: markets, the trade ticket, your positions and trading balance, the LP pool, and the live rules. Vite + React + viem, no wallet library.

## Run it

```bash
npm install
```

```bash
npm run dev
```

The app opens on http://localhost:5180. It reads the contract ABIs from `../abi/` and the deployment from `../contracts/deployments/local.json`, so deploy the local stack first (see the contracts README / `DeployLocal.s.sol`, anvil on port 8547).

On the local chain you can trade with **Use local test wallet** (anvil's public test account #1). That button only appears on chain 31337. A browser wallet works too; the app asks it to switch to or add the chain.

For one-click trading, start the relayer too (`cd ../relayer && node src/server.ts`, port 8790).

## One-click trading

On the Positions tab, **Turn on one-click trading** makes a P-256 key in this browser (WebCrypto, non-extractable, kept in IndexedDB) and approves it with one wallet transaction, `LevRouter.authorize`, together with the deposit. Defaults: 24 h, open + close what it opened + withdraw, up to 10x, 2% open and 5% close slippage, 25% of the balance per trade, the whole balance open at once and per day.

After that, opens, closes and withdrawals are signed by that key and sent to the relayer, with no wallet pop-up. The app checks the session's limits first and says when a trade has to use the wallet instead: the relayer is down, the session ended, a limit would be passed, or the position was not opened by this browser's key. Log out deletes the key here and revokes it through the relayer; Revoke and Revoke all are wallet transactions. When the key can't revoke itself (the relayer is down, or one-click is paused), log out still deletes it but says it stays approved on-chain, and the panel offers Revoke it / Revoke all from the wallet until that is done. Tabs of the app share one key per account: turning one-click on or off in one tab updates the others, and a second tab can't approve a second key while one is live. If a closing price moves further from the 1-minute average than the close slippage allows, the position offers Close with wallet.

The local test wallet can approve a session, so the whole flow works without a browser extension.

## Networks

Pick the deployment with `VITE_NETWORK`:

| Value | Deployment file | Chain |
|---|---|---|
| `local` (default) | `../contracts/deployments/local.json` | anvil, 31337 |
| `robinhood` | `src/config/robinhood.example.json` | Robinhood Chain, 4663 |

```bash
VITE_NETWORK=robinhood npm run build
```

Fill in the real addresses and markets in `src/config/robinhood.example.json` after deploying (`lens` is LevLens, `tradeRouter` is LevRouter, `router` is CreatorFeeRouter). `VITE_RPC_URL` overrides the RPC in either file. `VITE_RELAYER_URL` sets the relayer (default `http://127.0.0.1:8790`, or the file's `relayerUrl`; empty turns one-click off).

## Checks

```bash
npm run build
```

```bash
npm run check:chain
```

```bash
npm run check:session
```

```bash
npm run check:relay       # needs the relayer: cd ../relayer && node src/server.ts
```

`check:chain` runs the app's own read code in Node against the configured chain and prints the markets, pool and config. `check:session` (local chain only) approves a fresh session key from anvil account #4, signs intents with the app's own `src/lib/session.ts` under Node's WebCrypto, checks every digest against the router's `hashOpen`/`hashClose`/`hashWithdraw`/`hashRevoke`, simulates `router.open`, `withdraw` and `revokeBySig` with the signatures, checks tampered and high-s signatures are refused, then revokes the key. `check:relay` (local chain only) runs the browser path against the real relayer: the app's own `session.ts` signs and `relayer.ts` posts and polls, with the `Origin: http://localhost:5180` header and the same CORS checks a browser makes. Anvil #4 approves a key (its only transaction), opens a 2x long, closes it (the relayer retries `TooSoon` until the 10 s hold has passed) and logs out with a signed revoke. `npx tsx scripts/check-errors.ts` simulates a few failing calls (nothing is sent) to confirm contract errors come back as plain words.

## Layout

- `src/lib/reads.ts` — every chain read, polled every 3 s as one snapshot (market, quote and position views come from LevLens)
- `src/lib/wallet.ts` — browser wallet and local test wallet; every write is simulated first, then sent and confirmed
- `src/lib/session.ts` — session keys, EIP-712 signing (low-s), IndexedDB storage, client-side limit checks
- `src/lib/relayer.ts` — the relayer's HTTP API (`/health`, `POST /intents`, `GET /intents/:owner/:nonce`)
- `src/lib/oneclick.ts` — one-click state: the stored key, the session on-chain, relayer health, the order in flight
- `src/lib/errors.ts` — contract and relayer errors in plain words
- `src/components/` — Markets, TradePanel, Positions (plus trading balance), OneClick, Pool, Rules
