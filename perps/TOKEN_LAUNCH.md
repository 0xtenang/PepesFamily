# MemeLev token launch on Pons — plan

Research date: 2026-10-29. Sources: Hyperliquid and Lighter docs and dashboards, Pons V2 docs and published source, on-chain reads on Robinhood Chain (4663), press coverage. A critic pass checked the key claims. Nothing here is legal or financial advice.

## Decisions (founder, 2026-10-29)

- **Tax: 5%, permanent.** The token launches on Pons V2 with `creatorTaxBps = 500`. Pons fixes it at launch; it can never be raised or lowered.
- **What we receive:** about 5.7% of Pons-pool volume, in native ETH, pulled from Pons's FeeEscrow by `CreatorFeeRouterV2`.
- **Split: 80% LevPool / 10% buyback-and-burn / 10% ops.** That is about 4.56% / 0.57% / 0.57% of Pons volume.
- **No founder money in the pool before launch.** LevPool starts with only the 0.001 ETH seed its constructor requires, minted as house shares to the dead address. The pool fills from tax income alone, so **MemeLev trading opens only after tax income has brought pool cash to a threshold** (see step 9 below).
- **Pons buybacks stay off** (`buybackEnabled = false`). Our own buyback runs through the router instead.
- **Never list our token on MemeLev.**

## What made Hyperliquid and Lighter work

**Hyperliquid**
- **Product and traction first, token second.** About a year of points ran on a live exchange before HYPE (Nov 2024, about 191K users by then).
- **Trading that feels like a CEX.** Gas-free after one signature, using agent wallets that can trade but not withdraw elsewhere. Low fees (0.045% taker). Builder codes paid wallets and bots to bring order flow.
- **A token with no outsiders.** 0% VC. A 31% community airdrop, of which about 270.9M HYPE actually reached about 94K addresses.
- **Value flows automatically from real fees.** About 97–99% of fees go to the Assistance Fund, a keyless address that buys HYPE. A validator vote (85% for) bound the protocol never to touch it. About $1.39B has been spent so far.
- **Caveats.** It tightened after every thin-market squeeze (JELLY, POPCAT, XPL), and most memecoins are now 3–10x. Its vault lost money on thin markets and on a large ETH position. Big auto-deleveraging hit winning traders in Oct 2025.

**Lighter (LIT)**
- **Free retail trading.** Retail pays 0% with a 300 ms delay, while professionals pay for speed.
- **A ZK-proven order book** with an escape hatch to Ethereum.
- **A large, simple airdrop.** Points ran on a live product, then 25% of supply was airdropped automatically on 30 Dec 2025.
- **Distribution through Robinhood Wallet.** That instance reached about 26% of Lighter's volume.
- **Weaknesses.** Insiders hold 50%, and early buyback wording was discretionary, drawing "buybacks or yachts" criticism. After the airdrop, volume fell about 85% and daily active users fell from about 163K to about 12K. LIT fell about 71% in 3 months.

## What transfers to MemeLev

- **Ship the product first.** Run a points season on the live platform, then launch the token.
- **Scoped, gasless one-click trading.** Already built: session keys and the relayer.
- **Low leverage on memecoins and caps tied to liquidity.** Already built. At launch, keep the curator's max leverage at 5x or lower.
- **Write emergency rules down before you need them.** Publish the rug-guard, stale-price, pause and delisting rules before launch.
- **Put the fee flow in code.** Hard-coded splits with hard limits, a timelock, and public addresses and dashboards.
- **Keep the insider share low.** Pons V2 is a fair launch by construction; don't spoil it.
- **Score points on fees paid and LP ETH-days, not volume.** Filter sybils and watch volume/OI.

What does **not** transfer:
- Order-book speed.
- A big airdrop: Pons has no premine, so any rewards must be bought on the market.
- Their near-zero fees: a 5% tax is about 110× Hyperliquid's taker fee.
- Buybacks at their scale: a memecoin buying itself back from its own tax is circular. PONS fell about 71% even after burning about 33% of supply.

## How a 5% tax works on Pons V2

Found on-chain (verify again before launch; these are current settings the Pons owner can change):

| Item | Value |
|---|---|
| Launch factory | `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e` (`maxCreatorTaxBps = 1000`, so 5% is allowed) |
| Swap hook | `0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044` (afterSwap fees; only the factory can create pools with it) |
| Fee escrow | `0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e` |

1. **Fixed forever at launch.** The tax can never be raised *or lowered*.
2. **It's a fee in the curve and hook, not a transfer tax.** The token is a plain ERC-20, so wallet transfers and any other pool are untaxed.
3. **Traders pay about 6% per buy or sell**: Pons's 1% base fee plus the 5% tax. A round trip costs about 12%, plus a snipe tax in the first seconds after launch. On 2026-10-29 it started at 99% and decayed over 3 seconds (`snipeTaxSeconds = 3`; the factory caps it at 60).
4. **We receive about 5.7% of all trading volume on the Pons pool.** Pons keeps 0.3%; we get the other 0.7% of the base fee plus the whole 5% tax. Paid in native ETH. The fork test measured 5.6999% on the curve and on the V4 pool (the gap is rounding).
5. **The snipe tax is booked as base fee, so we get 70% of it.** On the fork, a 0.1 ETH buy in the launch second paid 94% into the base-fee bucket and 5% as our tax. We claimed 0.0708 ETH of it and Pons kept 0.0282 ETH. The published curve source has no snipe tax at all, so the deployed bytecode is not the published source.
6. **Fees are pull-based.** Fees are swept into FeeEscrow, then the recipient must call `claim()` itself. `CreatorFeeRouterV2` does both in `harvest()`. Fork-tested:
   - The FeeEscrow pays `claim()` with a call that forwards all gas, so any contract can claim. A zero-balance `claim()` reverts.
   - The curve lets the creator fee recipient sweep, not the account that launched. With the router as the recipient, only the router and the Pons operator can sweep.
   - After graduation the hook takes its fee from the swap's unspecified side. Sells and exact-output buys pay it in ETH, which the router sweeps itself. Exact-input buys (most router and aggregator buys) pay it in our token. Converting that is an internal swap, so only the Pons operator can sweep while any is pending. After graduation we mostly depend on the operator's sweeps.
7. **The fee recipient can be moved.** We can move it at any time; the router does it only through its own 7-day timelock, and collects what it is owed first (fork-tested). The Pons owner can also redirect it after a 3-day timelock, and we have no on-chain veto. The keeper alerts on that proposal.
8. **Launch gate.** `canLaunch(address)` must be true for our launcher. On 2026-10-29 the public gate was open (`launchEnabled = true`). The fork test closes it and whitelists the launcher through the owner's `setWhitelistedLauncher`, which works.
9. **Graduation.** The curve graduates to a locked Uniswap V4 pool after it sells out (4.2 ETH of real reserve, about 5.7 ETH of trading volume in the fork test). The buy that sells it out triggers the sweep into the factory. `createGraduatedPool` then seeds the V4 pool (ETH, token, fee 0, tick spacing 200, `PonsV2MemeHook`). If it never sells out, there is no V4 pool.

## Split of what we receive (decided)

| Bucket | Share of claimed ETH | ≈ share of Pons volume | Code limit | Use |
|---|---|---|---|---|
| LevPool donation | **80%** | 4.56% | at least 40% | Donated at once. Pool cash sets max-win tiers, coverage room and caps. Before any LP joins it becomes house shares held by the dead address, which nobody can withdraw. |
| Buyback and burn | **10%** | 0.57% | at most 40% | Small, rules-based buys spread over 24 h. Bought tokens go to the burn address (`0x…dEaD`). Never a price floor. |
| Ops | **10%** | 0.57% | at most 30% | Relayer and keeper gas first (`topUpGas`), then the treasury (`claimOps`). Spending is disclosed. |

Changing the split takes the router's 7-day timelock. ETH that arrived before a change is split the old way.

**How much volume opens trading.** At 4.56% of volume to the pool, each 1 ETH of pool cash needs about 22 ETH of Pons volume. The curve alone (about 5.7 ETH of volume) brings about 0.26 ETH. 5 ETH of pool cash takes about 110 ETH of volume, and 10 ETH about 220 ETH.

## Launch sequence

**Before launch**
1. ~~Decide the tax rate.~~ Decided: 5%, permanent (the median Pons swap pays 1%, and FLOKI cut its tax from 3% to 0.3% for adoption, so expect it to cost some volume).
2. Verify Pons directly. The fork tests settled:
   - launching through the whitelist (`setWhitelistedLauncher`, `canLaunch`)
   - the live fee parameters
   - `claim()` for a contract recipient
   - where snipe-tax proceeds go

   Still open:
   - the Pons operator's sweep cadence after graduation
   - written terms on the recipient redirect
   - the deployed bytecode, which already differs from the published source (snipe tax). Re-run the fork tests just before launch.
3. ~~Build `CreatorFeeRouterV2`, a `BuybackExecutor` and keeper fee jobs, and fork-test the whole path.~~ Done (see below). Audit them with the rest of the contracts.
4. Get legal advice covering the leverage product, the relayer (including sanctions screening), the token, buybacks and points. Decide which countries to geo-block.
5. Ship MemeLev to testnet, then mainnet, at 5x max leverage with small caps and the published emergency rules. **No founder money goes into the pool:** LevPool holds only its 0.001 ETH constructor seed (house shares) until tax income arrives. Keep new positions closed (`setOpensPaused(true)`, or list no markets) until the threshold in step 9.
6. Run Points Season 0 for 4–8 weeks on the live product.
7. At least 7 days ahead, publish the token spec:
   - the tax, and that it is permanent
   - the split and its limits
   - all addresses
   - no team allocation and zero sniper exemptions
   - Pons buyback toggle off
   - never listed on MemeLev
   - no price promises

**Launch**
8. Deploy `CreatorFeeRouterV2` first (`script/DeployPonsFeeRouter.s.sol:DeployPonsFeeRouter`), then launch from a fresh launcher that `canLaunch` and never buys:
   - `creatorTaxBps = 500`
   - `creatorFeeRecipient` = the router, from creation
   - `pairToken = address(0)` (native ETH)
   - an empty exemption list
   - `buybackEnabled = false`
   - `expectedEconomics` = `previewLaunchEconomics(launchConfigId, address(0))`, read just before

   Then the multisig calls `router.setToken(token)`. Run `CheckPonsLaunch` and publish what it prints.
9. Donations to the pool start with the first harvest. **MemeLev trading opens only when LevPool cash reaches the threshold** the founder sets (to be decided; the volumes above show what each level takes). Until then keep opens paused. Any team buys happen only after 1 h, from disclosed wallets, into a public lock.
10. On graduation, publish the canonical V4 pool. Deploy its `UniV4SampledOracle` (the fork test uses fast 90 s, slow 1800 s, a sample every 30 s, max age 60 s; the constructor needs fast ≥ 3 samples and max age ≤ 2 intervals), approve the keeper on it, and deploy `PonsV4BuybackExecutor` with the router as its only caller. Then `proposeBuybackRoute(executor, oracle)`. Buybacks can't start until that 7-day timelock ends, so the earliest is 7 days after graduation (and never earlier than 24 h after `setToken`). Have a no-graduation branch ready: revenue stays on the curve and there are no buybacks.

**After launch**
11. The keeper (run with `FEE_ROUTER` set) harvests about every 10 minutes and spreads buybacks over 24 h. Publish a weekly on-chain report from the router's `totals()`.
12. Alert on:
    - a Pons recipient-redirect proposal (keeper: built)
    - no fee sweeps for 24 h (keeper: built)
    - factory parameter changes (not built)
    - new untaxed pools for our token (not built)
13. Later, with counsel's agreement, platform trading fees can also fund buybacks (the Hyperliquid model) through a second splitter set as `LevExchange.treasury`.
14. Plan for volume to fall 90% or more from launch week. Never market an APR. Never list the token on MemeLev.

## Fee contracts (built)

The old `CreatorFeeRouter` can't claim from Pons's FeeEscrow. **Do not set it as the Pons recipient.** The recipient is `CreatorFeeRouterV2`.

- **`CreatorFeeRouterV2`** (`contracts/src/fees/`):
  - `harvest()`: anyone can call it. It sweeps the curve or the graduated pool, claims from the FeeEscrow, and splits 80/10/10.
  - Split limits in code. The split, treasury, buyback route, gas wallets, the Pons recipient and stray-token sweeps all go through a 7-day timelock.
  - `topUpGas()` for the relayer and keeper wallets (at most 1 ETH a day). `claimOps` sends the rest of ops to the treasury.
  - `buyback(ethIn, minOut)` with on-chain guards:
    - at most 0.1 ETH per call, and at most 1% of the pool's ETH depth
    - at least 10 minutes apart
    - live price within 200 ticks of the fast average, and the fast average at most 1000 ticks above the slow one
    - at least 93% of the oracle's fair amount out
  - Bought tokens go to a distributor until a fixed date, and to `0x…dEaD` forever after. Deployed with no distributor, they are burned from the start.
  - A guardian can pause allocation and buybacks. Pausing never moves funds.
  - Events and views for a public dashboard.
- **`PonsV4BuybackExecutor`**: buys on the graduated V4 pool for the router only. `buy` is exact input; `buyExactOut` is exact output (the hook then charges its 6% in ETH).
- **Keeper fee jobs** (`keeper/src/fees.ts`, on when `FEE_ROUTER` is set):
  - `harvest` every 10 minutes when the escrow, the router or the sweepable curve/hook fees hold more than `HARVEST_MIN_WEI`
  - `topUpGas` when a registered wallet is under half its target
  - buyback slices: the bucket spread over the rest of each 24 h period in 10-minute slots, quoted with `eth_call`, `minOut` = quote × 0.995, skipped when a router guard would refuse
  - samples for the token's own `UniV4SampledOracle`
  - alerts on a Pons recipient-change proposal or move, and on no fee sweep for 24 h while fees are pending
- **Deploy and check scripts:** `DeployPonsFeeRouter`, `CheckPonsLaunch` (`contracts/script/DeployPonsFeeRouter.s.sol`).

## Fork tests

```bash
cd contracts
FORK_URL=https://robinhood.drpc.org forge test --match-path 'test/fork/*' -vv
```

Without `FORK_URL` they skip, so plain `forge test` stays offline. `FORK_BLOCK` pins a block, but the public drpc endpoint only keeps about the last 900 blocks (~100 s) of state, so leave it unset there.

`test/fork/PonsLaunchFlow.fork.t.sol` runs the whole path against the live Pons V2 contracts with impersonated Pons roles. Numbers from the run on 2026-10-29 (L2 block 100923897; all 15 fork tests passed):

| Step | Result |
|---|---|
| Launch | The gate was closed and our launcher whitelisted through the factory owner, then the launch went through. A non-whitelisted launch reverted `NotWhitelisted`. The record shows tax 500, the router as recipient, Pons buyback off, ETH pair, fee 0, tick spacing 200 and a 4.2 ETH threshold. The fee policy snapshot shows a 30% Pons share and a 100 bps base fee. |
| Curve trading | Buys and sells from four wallets, 2.25 ETH of volume. The router claimed 0.1283 ETH, 5.6999% of volume. |
| Sweeps | The Pons operator's sweep credited the router in the escrow, and `harvest` claimed it. In the next round `harvest` swept the curve itself. The launcher's own sweep reverted `NotFeeSweepOperator`. |
| Split | Every harvest: 80% donated to LevPool, raising its cash, with the same number of house shares minted to `0x…dEaD` (no LP yet). 10% each stayed in the buyback and ops buckets. |
| Graduation | A buy cleared the last 353M sellable tokens. The curve swept 4.2 ETH and 285.7M tokens into the V4 pool, and the graduation sweep paid us 0.1971 ETH. Whole curve: 5.71 ETH of volume, 0.3254 ETH claimed (5.6999%). |
| V4 pool | The router's pool id matched the hook registry, and the hook pays the router. Sells and exact-output buys: 0.956 ETH of volume, router sweep plus claim 0.0545 ETH (5.6999%). A 0.05 ETH exact-input buy left fees in our token. The router's harvest then claimed 0. After the impersonated operator converted them, harvest claimed 0.00289 ETH. |
| Buyback | A `UniV4SampledOracle` on the new pool (62 samples over 31 min) and the executor went in through the 7-day timelock. The keeper-style buyback spent 0.0340 ETH (the 1%-of-depth cap) and sent 2.34M tokens to `0x…dEaD`: 93.07% of the oracle's fair value, against a 93.00% floor. A second buy right away was refused. |
| Totals | 0.3828 ETH claimed: 0.3062 ETH donated (80%), 0.0383 ETH buyback, 0.0383 ETH ops. LevPool cash 0.3072 ETH = house shares (share price still 1:1). |
| Escrow | `claim()` pays a contract with a call forwarding all gas, so a receiver that writes storage works. Crediting is permissionless. A zero-balance `claim()` reverts. |
| Recipient move | After the 7-day timelock the router swept and claimed 0.0388 ETH, then moved the stream. The factory record and the curve show the new recipient, the router claims nothing more, and the new recipient can sweep. |
| Gas | `harvest` 186k–317k, `buyback` 551k. |

`test/fork/PonsV4BuybackExecutor.fork.t.sol` checks the executor on three live graduated pools (exact input and output, fee currency, `minOut`).

## Still unverified or open

- **Deployed Pons bytecode ≠ published source.** The deployed curve has snipe-tax code that the published curve lacks. The tests only prove the behaviour they exercise. Re-run the fork tests right before launch.
- **Pons can change terms before our launch.** The test asserts today's base fee (100 bps), Pons share (30%) and launch fee (0.0005 ETH). Our launch snapshots whatever is live then.
- **After graduation we wait on the Pons operator**, because exact-input buys leave token fees that only the operator can convert. The keeper alerts after 24 h without a sweep.
- **Buybacks use exact input.** The hook keeps 6% of each buyback in our token and the operator later sells it back into our pool. Exact output (`buyExactOut`) would pay that 6% in ETH and saved 36 bps on the fork, but the router only calls `buy`.
- **The buyback floor is tight at the cap.** A cap-sized buy got 93.07% of fair value against a 93.00% floor. If the live price sits above the fast average, a cap-sized buy will be refused. The keeper's slices (bucket ÷ slots left) are far below the cap. Consider `feeAndSlipBps` 750–800 or a smaller `maxDepthBps`.
- **The no-sweep alert is untested live** (it needs 24 h), and keeper state lives in memory.
- **RPC limits.** The public drpc endpoint keeps ~100 s of state and refuses log ranges of 200 blocks or more. The fallback RPC's TLS certificate had expired.
- **Not audited.** `Deploy.s.sol` and DESIGN.md still mention the v1 router.

## Main risks

- **The 5% tax deters volume, and it's permanent.** Volume will leak to untaxed pools, and aggregators can misprice the hidden fee.
- **Revenue decays.** Pons fees are down about 96% from their peak week.
- **Legal.** Revenue-funded buybacks, issuer self-trades, points-for-token rewards, leveraged trading and the relayer can each draw regulators.
- **Pons is a trusted counterparty.** It's unaudited and pseudonymous, its owner can redirect our recipient and rescue pool fees, and it can change parameters before our launch.
- **Conflicts of interest.** The team controls listings, caps, the keeper, the relayer and the buyback schedule. That needs a team trading policy and disclosure of ops spending.
- **Wrong-way risk.** Pool growth depends on our own token's volume, which falls exactly when memecoin markets turn and manipulation losses are most likely.
