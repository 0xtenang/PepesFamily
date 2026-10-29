# Keeper

Runs every few seconds and does the jobs anyone may do on MemeLev, most urgent first:

1. records prices for Uniswap V4 coins (`V4_ORACLES`; the keeper must be approved on each oracle), and waits for them, so the refreshes below see the revived feed
2. fires the rug guard when a coin's fast price is 80% under its slow price
3. refreshes each coin's last good price: every 15 s on coins with open positions, every 120 s on the rest. It also refreshes at once when a feed starts failing, which starts the stale clock, and as soon as it reads again, which clears the clock. While a feed stays down with positions open, it refreshes every 15 s to record that the failure continues.
4. liquidates, then closes positions at max win, then settles shorts after a rug. A short at max win on a coin whose spot (or fast) price has fallen to the rug guard's level (20% of the slow price by default) is not closed: it waits for the rug guard and is settled at the rug cap.
5. withdraws its liquidation rewards (25% of a liquidated position's leftover equity, credited to its exchange balance) to its wallet, and logs an `ALERT` when that wallet runs low on gas money

Each step's transactions are simulated together, then sent back to back from a local nonce counter with a gas margin, and confirmed together. A pass sends at most `MAX_ACTIONS` position transactions; if more are waiting, the next pass starts at once, so rug guards and refreshes are never more than one batch away. Markets and open positions are each read at one block. Every coin, oracle and step is isolated: one bad read or a bad `V4_ORACLES` entry skips only itself.

```bash
npm install
node src/keeper.ts            # local anvil stack
node src/keeper.ts --once     # one pass, then exit
node src/e2e.ts               # local end-to-end check
```

Robinhood Chain:

```bash
DEPLOYMENT=../contracts/deployments/robinhood.json KEEPER_PRIVATE_KEY=0x… node src/keeper.ts
```

| Env | Default | What |
|---|---|---|
| `INTERVAL_MS` | 4000 | time between passes |
| `REFRESH_OPEN_SECONDS` | 15 | refresh cadence on coins with open positions, and while a feed stays down |
| `REFRESH_SECONDS` | 120 | refresh cadence on coins without open positions |
| `MAX_ACTIONS` | 50 | liquidations, max-win closes and rug settlements sent per pass |
| `V4_ORACLES` | none | comma-separated UniV4SampledOracle addresses to poke. A malformed entry stops the keeper at startup; an address with no contract or no V4 oracle is logged as an `ALERT` and ignored |
| `GAS_MARGIN_PCT`, `GAS_MARGIN_MIN` | 130, 25000 | gas limit = estimate × 1.3, and at least estimate + 25k. A transaction that still runs out of gas is sent once more with twice the gas |
| `GAS_ALERT_WEI` | 0.01 ETH | `ALERT` when the keeper's wallet holds less |
| `GAS_EXIT_WEI` | 0 (off) | exit with code 2 below this, for a supervisor that pages someone |
| `REWARD_WITHDRAW_MIN_WEI` | 0.001 ETH | withdraw exchange rewards once they reach this, or whenever the wallet is under `GAS_ALERT_WEI` |
| `POLLING_MS` | 500 | receipt polling interval |
| `ALERT_REPEAT_S` | 3600 | repeat an `ALERT` at most this often |

## Fee jobs (`src/fees.ts`)

With `FEE_ROUTER=<CreatorFeeRouterV2>` set, the keeper also runs the platform token's fee jobs on their own timer (`FEE_TICK_MS`, default 15 s). Both loops send from the keeper's account through one sender that numbers their transactions, so they run side by side and the fee jobs never hold up the rug guard.

| Job | When | Env (default) |
|---|---|---|
| `harvest()` | every 10 min, if the escrow, the router or the fees the router can sweep itself hold more than the threshold | `HARVEST_EVERY_S` (600), `HARVEST_MIN_WEI` (0.0005 ETH) |
| `topUpGas()` | every 10 min, if a registered gas wallet is under half its target and the ops bucket and daily cap allow | `GAS_CHECK_S` (600), `GAS_LOW_BPS` (5000) |
| `buyback(ethIn, minOut)` | each 10-min slot. `ethIn` = buyback bucket ÷ slots left in the 24 h period, at most the router's cap. Quoted with `eth_call`, `minOut` = quote × 0.995. Skipped when paused, too soon, or when the price guards would refuse it | `BUYBACK_SLOT_S` (600), `BUYBACK_SPREAD_S` (86400), `BUYBACK_SLIP_BPS` (50), `BUYBACK_MIN_WEI` (0.00001 ETH) |
| `poke()` on the token pool's `UniV4SampledOracle` | when a sample is due (the keeper must be approved with `setKeeper`) | `FEE_ORACLE` (default: the router's oracle) |
| `ALERT` log lines | Pons proposes or makes a move of our fee recipient; no sweep has paid us for 24 h while fees are pending; a gas wallet needs a top-up but the ops bucket is empty or the daily cap is used | `SWEEP_ALERT_S` (86400), `ALERT_REPEAT_S` (3600), `LOG_RANGE` (199 blocks per `eth_getLogs`), `FEE_LOG_FROM_BLOCK` |

```bash
FEE_ROUTER=0x… DEPLOYMENT=../contracts/deployments/robinhood.json KEEPER_PRIVATE_KEY=0x… node src/keeper.ts
```

`demo-prices.ts` moves the mock pools on the local chain only (`pump PLONK 40`, `rug WOB`, `--rugs`). Its random walk sends from anvil account 8 (no other script uses it) and one step at a time, so the one-off commands (deployer key) and `e2e.ts` never race it for nonces, and it reads ticks from the pending block, so it doesn't undo their moves.
