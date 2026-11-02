# PepesAgent

An automated Meteora DLMM liquidity agent on Solana for PepesFamily users: connect Phantom on
pepesdotfamily.fun, start the agent, and it opens, manages and closes liquidity positions for you within your
limits. A 10% fee is taken on profit above the user's previous best when a position closes; losses carry forward.

**Based on [Meridian](https://github.com/yunus-0x/meridian) by yunus-0x**, used with the author's permission. Its
standalone bot (wallet-convergence signals, focused screening, deterministic exits) is the core; the original
README follows below.

## What PepesAgent adds (`pepes/`)

- **Many users, one worker.** Signals and screening are shared; each entry, exit and claim runs as one user
  (`pepes/context.js`: `runAs`), with that user's signer, state files (`DATA_DIR/users/<id>/`), caps and
  shadow/live flag. Users are listed in `DATA_DIR/users.json` (`pepes/users.js`). Without `PRIVY_APP_ID` it is
  single-wallet Meridian.
- **Privy agent wallets** (`pepes/signer.js`). Each user's agent wallet is a Privy embedded Solana wallet; the
  worker signs with an authorization key the user approved once, and a Privy policy limits what can be signed
  (Meteora DLMM, Jupiter, system/token programs; SOL only to the fee address, capped).
- **Profit fee** (`pepes/fee.js`): `FEE_PCT` (10) of the user's running result above its previous best, sent to
  `FEE_ADDRESS` on close. A close's result is the smaller of reported and actually-received profit.
- **Track record** (`pepes/signals.js`): every signal, its screening result and price, and what the LPs behind it made.
- **Risk agreement:** users accept it on the Agent page before starting (`terms.json` on the disk).
- **`AGENT_REDUCE_ONLY=true`:** the emergency switch. No new positions; exits, claims and the signal log go on.
- **Fixes to Meridian:** finished signals no longer throw (`finishSignal` without options); queued wallet work runs
  as the user who queued it; the positions cache is per wallet; Jupiter referral is off by default (Meridian sent
  0.5% of each swap to its author's account).

## Environment (worker)

| Variable | Purpose |
|---|---|
| `RPC_URL`, `MONITOR_WS_URL` | Solana RPC with WebSocket (Helius) |
| `PRIVY_APP_ID`, `PRIVY_APP_SECRET` | Privy app (turns on multi-user mode) |
| `PRIVY_AUTHORIZATION_KEY` | the agent's authorization private key (base64 PKCS8), registered in Privy as a key quorum |
| `FEE_ADDRESS`, `FEE_PCT` | where the profit fee goes, and its percent (10) |
| `DATA_DIR` | persistent volume for users and their state |
| `JUPITER_API_KEY` | optional |

Shadow mode stays on (`shadowMode: true`) until the team switches it off; each user also has a `live` flag.

`npm test` runs Meridian's tests and `test/pepes.test.js`.

---

# Meridian

Standalone wallet-triggered Meteora DLMM bot for Solana. It waits for fresh LP entries by tracked wallets, screens the matching token, and manages positions with deterministic rules. No LLM or Meridian server is required.

## Flow

1. Watch tracked LP wallets through Solana WebSocket notifications, with signature backfill for missed events.
2. Count distinct wallets adding meaningful quote-side liquidity to the same **mint address**, across pools, within a rolling window (default: two wallets in 120 seconds).
3. Screen that mint and its eligible token/SOL pools using Meteora and Jupiter data and on-chain token checks.
4. Recheck exposure, price movement, balances, and transaction safety before entry. Failed screening waits within a bounded deadline.
5. Monitor positions independently and execute rule-based closes and fee claims.

Shadow mode is the default and forces `DRY_RUN=true` for all transaction paths. It records proposals without submitting them. Read [user-config.example.json](user-config.example.json) for supported settings. Monitoring and screening implementation details are in [standalone/](standalone/).

## Setup

Use Node.js 18 or newer and a Solana RPC provider supporting WebSocket subscriptions and transaction history.

```sh
npm install
npm run setup
node cli.js wallets add --wallet ADDRESS --name NAME
node cli.js wallets add --wallet OTHER_ADDRESS --name OTHER_NAME
npm start
```

Setup writes `user-config.json` and starts with shadow mode enabled. It preserves existing settings when prompts are left blank. Set credentials in your environment or local `.env`; see [.env.example](.env.example). For read-only operation, `WALLET_ADDRESS` / `walletAddress` can identify the portfolio without a private key. Live signing requires `WALLET_PRIVATE_KEY`.

Supported infrastructure overrides:

| Variable | Purpose |
|---|---|
| `RPC_URL` | Default Solana endpoint and transaction submission |
| `MONITOR_RPC_URL`, `MONITOR_WS_URL` | Wallet monitoring endpoints |
| `BALANCE_RPC_URL` | Standard SOL and token balance reads |
| `FALLBACK_RPC_URL` | Fallback for monitor/balance reads |
| `PNL_SOURCE` | `meteora` (default) or `rpc` |
| `PNL_RPC_URL` | Optional on-chain PnL engine endpoint |
| `JUPITER_API_KEY` | Jupiter price and swap access |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | Optional outbound notifications |

Balances use standard RPC, including SPL Token and Token-2022. PnL defaults to Meteora portfolio and position APIs, with an on-chain fallback. Jupiter supplies prices, token data, and swaps. Telegram is notification-only; the previous agent chat and command menus are archived.

To enable live trading, review your thresholds, wallet list, and shadow results, set `shadowMode` to `false`, remove any `DRY_RUN=true` override, and restart. Configuration edits take effect after restart.

## Commands

```sh
node cli.js help
node cli.js status
node cli.js balance
node cli.js positions
node cli.js screen --mint ADDRESS
node cli.js pool --pool ADDRESS
node cli.js manage --dry-run
node cli.js close --position ADDRESS --dry-run
node cli.js performance
```

`screen --mint` is read-only and never deploys. New entries are available only through wallet convergence. Manual close, claim, and swap operations remain available; run `help` for arguments. The CLI no longer writes skills into your home directory.

For a managed daemon:

```sh
npm run pm2:start
npm run pm2:logs
```

## Local state

Wallets, settings, position state, signal checkpoints, decisions, and logs stay local and are ignored by Git. `performance.js` retains closed-position accounting in the existing `lessons.json` file so historical records remain readable; it does not generate LLM lessons or contact HiveMind. Pool history and cooldowns remain in `pool-memory.json`.

A `submitting` attempt left by a restart needs on-chain reconciliation before that mint can be attempted again. Do not erase recovery state to bypass it.

## Validation

```sh
npm test
```

This checks JavaScript syntax, the standalone signal/rule tests, module imports, CLI behavior, and the Meteora PnL path with mocked data. Tests do not submit transactions.

## Legacy archive

The local **`legacy` branch** preserves the complete pre-cleanup snapshot at **`fd835b7`**, including the earlier LLM runtime in its history. The branch was advanced without rewriting any commits. No archive directory is loaded by the new application.

```sh
git show legacy:agent.js
git show legacy:tools/screening.js
git log legacy
```

The archive includes the old prompts/tool catalog, broad scanning, HiveMind and lesson evolution, LPAgent/Meridian relays, top-LPer studies, chart indicators, GMGN enrichment, Discord listener, Claude agent presets, and old setup/CLI. It has not been pushed automatically.
