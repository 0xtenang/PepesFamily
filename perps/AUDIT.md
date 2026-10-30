# Audit brief: PepesFamily Long/Short (MemeLev contracts)

What the long/short contracts do, what they must guarantee, the admin powers, and the limits we already know about. Rules and reasoning in more detail: [DESIGN.md](DESIGN.md). Earlier internal reviews and their fixes: [SECURITY_REVIEW.md](SECURITY_REVIEW.md).

**Audited:** IMD Swarm, 2026-10-30, commit 19ac59a ([report](https://explorer.imd.fun/jobs/1425b92e-2a79-4c8e-9ba8-fa2163df4825)): 1 high, 2 medium, 1 low, all fixed with tests (SECURITY_REVIEW.md).

## 1. What the system is

Leveraged longs and shorts on a curated list of memecoins on **Robinhood Chain** (chain ID 4663, an Arbitrum Orbit L2). The first coin is UBIK (`0x812486EAea648819853F8E372dc9f1516C7868Bd`).

- **One ETH pool is the counterparty to every position.** There is no order book: every position fills at once against `LevPool`. LPs deposit ETH and hold transferable shares. The pool also takes donations (`donate`), which raise the share price.
- **Traders** hold an ETH balance inside `LevExchange`, open a long or short on a listed coin with a stake and a leverage (1–10x, shorts at most 5x), and close it later. P&L = stake × leverage × the price move, capped by a per-position **max win** fixed at open. A trader can never lose more than the stake plus any margin they added.
- **Prices** come from the coin's own Uniswap pools, as ticks (price = 1.0001^tick) of the coin's price in ETH: a live price, a fast average (~1–2 minutes) and a slow average (30 minutes).
  - `UniV3Oracle`: a coin/WETH Uniswap V3 pool's own TWAP.
  - `UniV4SampledOracle`: a coin/ETH Uniswap V4 pool sampled by approved keepers at least 30 s apart. The fast price is the median of the last 3 samples.
  - `UniV4BridgedOracle`: for UBIK, whose liquidity is in UBIK/USDG (Uniswap V4). It prices UBIK in USDG from that pool, and USDG in ETH from the WETH/USDG Uniswap V3 pool (`0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca`, ~$13M). Keepers sample it like a V4 feed.
- **Fair prices.**
  - Fills take whichever of the live and fast price is worse for the trader, plus a size-based spread.
  - Liquidations, max-win closes and take-profit/stop-loss triggers use the fast price.
  - Pool value (NAV) marks open positions at the live, fast and slow prices and takes the worst one for whichever side of the deal.
- **Keepers** (ours or anyone's) liquidate, close positions at max win, settle shorts after a rug, fire take-profits and stop-losses, fill orders, and sample V4 feeds. Every keeper action is permissionless except V4 feed sampling.
- **One-click trading** (`LevRouter`): a browser session key (P-256, WebCrypto) signs EIP-712 intents within limits the owner's wallet approved once. A relayer submits them and pays the gas.
- **Code layout.** `LevExchange` holds the money paths. Everything else (listing, config, the rug guard, triggers, orders, margin, reads) is `LevExchangeAdmin` code, run on `LevExchange`'s storage through its `fallback` (`delegatecall`). Both inherit one storage layout from `LevExchangeBase`.
- Nothing is upgradeable.

## 2. Scope

**In scope.** All under `perps/contracts/`:

- `src/LevExchange.sol`, `src/LevExchangeAdmin.sol`, `src/LevExchangeBase.sol`, `src/LevTypes.sol`
- `src/LevPool.sol`, `src/LevLens.sol`, `src/LevRouter.sol`
- `src/libraries/LevLogic.sol`, `src/libraries/ConfigCheck.sol`, `src/libraries/TickRatio.sol`
- `src/oracles/UniV3Oracle.sol`, `src/oracles/UniV4SampledOracle.sol`, `src/oracles/UniV4BridgedOracle.sol`
- `src/interfaces/*`
- `script/Deploy.s.sol`, `script/DeployBridgedOracle.s.sol`

**Out of scope:**
- `src/fees/*` (`CreatorFeeRouterV2`, `PonsV4BuybackExecutor`): written for a separate platform token that PepesFamily doesn't use.
- `src/mocks/*`.
- Off-chain code: `keeper/`, `relayer/`, `web/`, and the PepesFamily site.

**Build and test:**

```bash
git submodule update --init --recursive
cd perps/contracts
forge test
```

That runs 219 tests offline. The fork tests skip unless `FORK_URL` is set:

```bash
FORK_URL=https://robinhood.drpc.org forge test --match-path 'test/fork/*'
```

The public endpoint keeps only ~100 s of state; rerun on "Unknown state". Solidity 0.8.26, via-IR, cancun, OpenZeppelin 5.1.0.

## 3. What must hold

1. **Books.**
   - `address(LevExchange).balance == Σ balanceOf + Σ open stakes + Σ margin + treasuryBalance + orderEscrow`.
   - `address(LevPool).balance == LevPool.cash`.
   - Every settlement moves exactly the difference between the trader's payout, the keeper reward and the treasury fee, and what the position held.
2. **No trader extracts more than the rules allow.**
   - A position never pays out more than its stake + margin + max win, less fees.
   - Pushing the coin's pool price, alone or combined with any keeper action, should not profit a trader at the pool's expense beyond what holding the coin itself would.
   - Rules to check: the worse-of-live-and-fast fill, the spread, the open bands (no opens while live/fast differ by more than 5% or fast/slow by more than 20%), and the pump band (a long's exit is priced at most +50% over the slow price).
3. **The pool can always pay every open max win.**
   - Open max wins are at most `coverageBps` (50%) of pool cash.
   - LP withdrawals only come from cash not reserved for max wins.
   - Open size across coins is at most 3× pool cash.
4. **LP share pricing can't be gamed.**
   - Deposits buy in at the highest plausible pool value, and withdrawals pay the lowest.
   - Withdrawals wait a 24 h cooldown, then pay the lower of the value at request and at withdrawal, less a stress fee while traders are winning. The fee stays in the pool.
   - Deposits and withdraw requests pull in pending donations first.
   - Valuation pauses while a feed is down or a rug is unsettled.
5. **Exits are never frozen for long.**
   - An owner can always close their position: at the live price; at the last good fast price once its feed has been down 10 minutes (`staleSeconds`); or, for a short caught by the rug guard, at the rug price capped at +20%.
   - No admin action blocks closes or withdrawals of trader balances.
6. **Price feeds.**
   - A single manipulated block or sample can't move the fast price (median of 3 samples, or a V3 TWAP).
   - The V3 feed refuses to report until the pool keeps enough observations for the slow window.
   - Depth readings can't be inflated for a moment to unlock leverage (smallest sampled depth over the slow window).
   - The bridged feed only reads the pools given at construction. Its pool id is computed from the PoolKey, so the currencies are the pool's own.
7. **Session keys** (`LevRouter`) can only:
   - open and close within the limits the owner signed (leverage, slippage from the fast price, stake per trade, open stake, a daily budget that refills over 24 h);
   - withdraw to the owner's own address.

   Revocation (`revoke`, `revokeAll`, `revokeBySig`, `cancelNonce`, the guardian's `revokeEverySession`) works even while signed trading is paused.
8. **Orders and triggers.**
   - An order's escrow is exactly its stake plus the open fee at placement, and returns to the owner on cancel or expiry.
   - A fill passes every check a normal open does and lands at most `slipTicks` past the trigger.
   - A take-profit or stop-loss can't be set at a level already reached, so it can't be used as a close at the lagging fast price.
   - The owner gets no keeper share for closing their own position.

## 4. Admin powers

The owner is meant to be a multisig with a timelock. Ownership is two-step everywhere.

- **`LevExchange` owner:**
  - `listMarket` (an oracle, max leverage, net cap).
  - `setMarket` (pause a coin's new opens, change its caps; closes are never blocked).
  - `setConfig` and `setRiskConfig`, within the hard limits in `ConfigCheck.isValid` / `isValidRisk`.
  - `setOpensPaused`; `setRouter` (once); `setGuardian`; `setTreasury`.
  - `claimTreasury` is callable by anyone and pays only `treasury`.
  - The owner has no function that moves trader balances, stakes, margin, escrow or pool cash.
- **Guardian:**
  - can pause new opens (exchange) and pause signed trading (router);
  - can void every session (`revokeEverySession`);
  - can't unpause.
- **`LevPool` owner:**
  - `setExchange`, `setNavSource`, `setFeeSource`, each settable once;
  - the withdrawal cooldown (1 h–7 days), withdrawal window and minimum deposit, all within bounds.
- **Oracle owner:** `setKeeper` (who may sample a V4 feed).
- **Config changes apply at once**, including to open positions and to intents already signed, within the hard limits. This is why the owner should sit behind a timelock.

## 5. Known limits (please confirm, not re-report)

- **Open-position cap.** The pool values every open position, so at most 600 are open at once (`MAX_OPEN_POSITIONS`). Someone can fill the slots to block new opens, at the cost of the stakes, fees and hold fees.
- **Owner keeper share.** The owner gets no keeper share for clearing their own position, but this is an address check: calling from a second address collects it.
- **F19 (mitigated).** A stolen session key can pre-sign intents that become usable shortly before their deadline. Any revocation kills them.
- **Slippage bound and spread.** The session slippage bound is checked before the spread (at most 3% by default, and it goes to the pool).
- **Stress-fee tier.** A large deposit just before a withdrawal can lower the stress-fee tier. The deposit is locked for the 24 h cooldown.
- **Curator and keeper trust.**
  - Listing a coin trusts its price feed.
  - On V4 feeds, approved keepers choose when to sample, within a spacing of 30–60 s. The median of 3 limits what one sample can do.
- **Stale settlement.** It uses the last good fast price. Thin coins with long feed outages can settle off-market.
- **Robinhood Chain specifics to confirm:** block-time ordering by the sequencer, and the RIP-7212 P-256 precompile (without it, one-click trades cost ~950k gas).

## 6. Where to look hardest

- **Interaction of exit paths with the pump band, spread and bands:**
  - `close`, `closeFor`, `closeByTrigger`, `closeAtMaxWin`, `liquidate`, `settleRugged`, and the stale path;
  - whether any of them, or any ordering of them with keeper actions, beats the intended price.
- **Margin (`addMargin`)** in liquidation, settlement and NAV (`Side.margin`; it counts in the deposit-side valuation only).
- **The hourly growth limit:** `Market.growthStart` / `growthSize`, and the size a closing position gives back.
- **`UniV4BridgedOracle`:**
  - tick composition: −(V4 tick) − (V3 tick);
  - depth conversion through `TickRatio`;
  - a manipulated bridge or coin pool at sample time.
- **The delegatecall split.** Storage layout agreement between `LevExchange` and `LevExchangeAdmin`, reentrancy through payable admin functions (`addMargin`, `placeOrder`), and `nonReentrant` across the split.
- **`LevRouter`'s EIP-712 hashing, nonces, generations and budget refill.**
