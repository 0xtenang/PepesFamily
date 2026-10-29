# MemeLev

Leveraged longs and shorts on curated Robinhood Chain memecoins, against one shared ETH pool funded by our platform token's creator fees and open to LPs. Working name. Rules and reasoning are in [DESIGN.md](DESIGN.md). The platform token's launch and fee path are in [TOKEN_LAUNCH.md](TOKEN_LAUNCH.md).

## Platform token (founder's decisions)

- Launches on Pons V2 with a permanent 5% creator tax. We receive about 5.7% of Pons-pool volume in native ETH, which `CreatorFeeRouterV2` claims from Pons's FeeEscrow.
- What we receive is split 80% to LevPool (donated), 10% to buyback-and-burn and 10% to ops.
- No founder money goes into the pool before launch: LevPool holds only its 0.001 ETH constructor seed. MemeLev trading opens only after tax income has brought pool cash to a threshold.
- Pons buybacks stay off. The token is never listed on MemeLev.

## Layout

| Folder | What |
|---|---|
| `contracts/` | Solidity (Foundry): `LevExchange` (with `LevExchangeAdmin`), `LevPool`, `LevRouter`, `LevLens`, Uniswap V3 and V4 price feeds, the platform token's fee path (`src/fees/CreatorFeeRouterV2`, `PonsV4BuybackExecutor`), tests, deploy scripts |
| `keeper/` | TypeScript bot: rug guard, liquidations, max-win closes, rugged-short settlement, V4 price samples, and with `FEE_ROUTER` set the fee jobs (harvest, gas top-ups, buyback slices, alerts) |
| `relayer/` | One-click relayer: checks each signed order, submits it and pays the gas |
| `web/` | Trading app (Vite + React + viem) |
| `abi/` | Contract ABIs shared by the keeper and app (`scripts/export-abis.sh`) |
| `memecoin-pool-simulator.html`, `engine.js` | The pool simulator from earlier |

## Run it locally

Needs Foundry (`~/.foundry/bin`) and Node 22.18 or newer.

```bash
(cd keeper && npm install) && (cd relayer && npm install) && (cd web && npm install)
```

```bash
scripts/dev-local.sh
```

That starts a local chain on port 8547, deploys everything with five test coins, funds the pool (3 ETH of creator fees plus a 15 ETH LP), and runs the keeper, moving demo prices, the one-click relayer (port 8790) and the app at http://localhost:5180. In the app, pick "Local test wallet" to trade with a funded test account.

Force events from another terminal:

```bash
cd keeper && node src/demo-prices.ts pump PLONK 40
```

```bash
cd keeper && node src/demo-prices.ts rug GRMB
```

## Tests

```bash
cd contracts && forge test
```

```bash
cd keeper && node src/e2e.ts
```

```bash
cd relayer && RELAYER_URL= node src/e2e.ts
```

```bash
cd web && npm run check:chain && npm run check:session && npm run check:relay
```

177 contract tests pass offline, including fuzz and invariant tests that the books always balance, and one regression test per fixed review finding. 15 more are fork tests, which skip without `FORK_URL`. The keeper end-to-end run has one keeper pass liquidate, close at max win, fire the rug guard and settle a rugged short. The relayer run (34 checks) trades, closes, withdraws and logs out through a relayer it starts itself, then replays the review's abuse cases. The web checks need the local stack running (`check:relay` needs the relayer).

Fork tests against Robinhood Chain mainnet skip unless `FORK_URL` is set:

```bash
cd contracts && FORK_URL=https://robinhood.drpc.org forge test --match-path 'test/fork/*' -vv
```

They launch a real Pons V2 token with our router as the recipient (impersonating the Pons owner to whitelist the launcher). Then they trade the curve, sweep and harvest into LevPool, graduate to the V4 pool, sweep the hook, and buy back through `PonsV4BuybackExecutor`. Measured: 5.6999% of volume reached the router, and 80% of it reached LevPool as house shares. [TOKEN_LAUNCH.md](TOKEN_LAUNCH.md#fork-tests) has the numbers and what is still unverified. The public drpc endpoint only keeps about 100 s of state, so leave `FORK_BLOCK` unset there or set it a few blocks behind the head. Some of its nodes sometimes answer `Unknown state` for every account; rerun when that happens.

## PepesFamily Long/Short (2026-10-29)

This folder is MemeLev, brought into the PepesFamily repo. The site's Long/Short page (`#/perps` in `web/index.html`) trades on it: no token of our own is involved, the pool is funded by deposits (and `pool.donate()`, e.g. from PepesFamily's protocol fees), and coins are listed one by one.

**First market: UBIK** (`0x8124…68Bd`, ~$6M market cap). Its liquidity is in UBIK/USDG on Uniswap V4 (pool `0x4aaa…d2a7`: dynamic fee, tick spacing 200, hook `0x08E5…A080`); its WETH pool is too thin to price from. `UniV4BridgedOracle` therefore prices UBIK in USDG from that pool and USDG in ETH from the WETH/USDG Uniswap V3 pool (`0x52e6…71Ca`, ~$13M). Keepers sample it like any V4 feed (`V4_ORACLES`). Fast window 120 s (three 30 s samples plus 30 s of slack for the keeper), slow window 30 min.

Tests: `test/BridgedOracle.t.sol` (offline) and `test/fork/UbikMarket.fork.t.sol` (live pools: the price, and a long and a short opened and closed on a fresh stack; run with `FORK_URL=https://robinhood.drpc.org`). `script/DeployLocalUbik.s.sol` sets up a local chain with stand-in pools at UBIK's live values, for testing the page (it reads a localhost-only `pf-perps-dev` override; see the comment at `perpCfg` in `web/index.html`).

Going live (the owner's wallet signs every step; keys never go in this repo):

1. Deploy the stack (`script/Deploy.s.sol`, see below).
2. `KEEPER=<keeper wallet> OWNER=<owner> forge script script/DeployBridgedOracle.s.sol --rpc-url robinhood --broadcast --account <keystore>`; the owner accepts the oracle's ownership.
3. Run the keeper with `V4_ORACLES=<oracle>` for at least 30 minutes, until `oracle.read()` answers.
4. From the owner: `listMarket(oracle, 5, <netCapEth>)` (5x max; the cap per side is the curator's choice, e.g. 0.5 ETH to start). Fund the pool (`pool.deposit()` or `pool.donate()`).
5. Put the exchange, lens and pool addresses in `CONFIG.perps` in `web/index.html` (the market's `id` is what `listMarket` returned).

`contracts/lib` (OpenZeppelin 5.1.0, forge-std 1.17.0) isn't pushed: `forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 foundry-rs/forge-std@v1.17.0 --no-git` restores it.

## Going to Robinhood Chain

1. Confirm WETH and Uniswap addresses for chain 4663 (testnet 46630) at docs.robinhood.com.
2. Deploy to testnet first: `OWNER=<multisig> GUARDIAN=<pause key> TREASURY=<addr> forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast --account <keystore>`. `OWNER` must already be a contract on that chain (set `OWNER_IS_CONTRACT=false` only for a test). The owner then calls `acceptOwnership()` on the pool, the exchange and the trade router. The guardian can pause trading and one-click, but only the owner can unpause.
3. Deploy `CreatorFeeRouterV2` (`POOL=<LevPool> TREASURY=<addr> OWNER=<multisig> forge script script/DeployPonsFeeRouter.s.sol:DeployPonsFeeRouter --rpc-url robinhood --broadcast --account <keystore>`). Launch the platform token on Pons V2 with that router as `creatorFeeRecipient`, following [TOKEN_LAUNCH.md](TOKEN_LAUNCH.md#launch-sequence). Before the launch, the owner calls `pool.setFeeSource(router)` (once), so deposits and withdraw requests pull in waiting creator fees first. Then call `router.setToken(token)` and check the launch with `CheckPonsLaunch`.
4. For each curated coin, deploy its price feed (`DeployV3Oracle`). It grows the pool's observation history in steps; run it again with `ORACLE=<addr>` until it logs `ready`. Then list the coin from the multisig: `listMarket(oracle, maxLeverage, netCapEth)`.
5. Run the keeper with its own key and some ETH for gas, and `FEE_ROUTER=<router>` for the fee jobs. Approve it on the token pool's `UniV4SampledOracle` after graduation. It withdraws its rewards and logs an ALERT when its gas runs low.
6. Run the relayer with its own funded key behind your proxy (see [relayer/README.md](relayer/README.md) for `TRUST_PROXY` and the gas ceiling).

Before real money: an external audit, a testnet period, and legal advice. Leveraged trading for the public is regulated in most countries.

## Trust

- The owner can list coins, pause them, and change fees only within limits written into the contract. It can never withdraw the pool or trader balances.
- Listing a coin means trusting its price feed. A bad feed could pay fake wins, up to the per-coin caps. Put the owner behind a multisig with a timelock.
- Closing is never blocked: paused coins still close, and a dead price feed settles at the last good price after 10 minutes of failed reads (the keeper records them). The owner can't stretch that wait past an hour or the post-rug lock past a day.
