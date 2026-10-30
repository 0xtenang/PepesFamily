# IMD Swarm audit request: Long/Short

Paste the request text at [explorer.imd.fun/launch](https://explorer.imd.fun/launch) (choose **Audit**), or send the API body below.

- **Repository:** https://github.com/0xtenang/PepesFamily
- **Commit:** `72b40ae4b730938846619eaa3f7042169cdc4477`

## Request text

```text
Project: PepesFamily Long/Short (MemeLev contracts), pre-launch audit.

Repo: github.com/0xtenang/PepesFamily (commit 72b40ae). Read perps/AUDIT.md first: it states the system, the scope, what must hold, the admin powers and the known, accepted limits. Rules in detail: perps/DESIGN.md; earlier internal reviews and fixes: perps/SECURITY_REVIEW.md.

Scope (all under perps/contracts/): src/LevExchange.sol, src/LevExchangeAdmin.sol, src/LevExchangeBase.sol, src/LevTypes.sol, src/LevPool.sol, src/LevLens.sol, src/LevRouter.sol, src/libraries/LevLogic.sol, src/libraries/ConfigCheck.sol, src/libraries/TickRatio.sol, src/oracles/UniV3Oracle.sol, src/oracles/UniV4SampledOracle.sol, src/oracles/UniV4BridgedOracle.sol, src/interfaces/*, script/Deploy.s.sol, script/DeployBridgedOracle.s.sol. Out of scope: src/fees/*, src/mocks/*, keeper/, relayer/, web/.

Tests: git submodule update --init --recursive; cd perps/contracts; forge test (211 tests). Fork tests against live Robinhood Chain (UBIK market, Uniswap V4 + V3 pools): FORK_URL=https://robinhood.drpc.org forge test --match-path 'test/fork/*'.

What it is: leveraged longs and shorts (1-10x, shorts at most 5x) on curated memecoins on Robinhood Chain (4663), first UBIK. One ETH pool (LevPool, LP shares) is the counterparty to every position; no order book. Prices are ticks of the coin's ETH price from its own Uniswap pools (live, fast and slow averages): V3 TWAP, keeper-sampled V4 (median of 3), or bridged through a stablecoin (UBIK/USDG V4 x WETH/USDG V3). Fills take the worse of live and fast plus a size-based spread; liquidations, max-win closes and take-profit/stop-loss use the fast price; NAV marks positions at the worst of live/fast/slow. Risk rules: open bands (live/fast 5%, fast/slow 20%), a pump band (a long's exit at most +50% over the slow price), leverage tiers by coin liquidity and by position size, per-coin net and gross caps, an hourly new-size limit, a platform cap (open size <= 3x pool cash), coverage (open max wins <= 50% of pool cash), a rug guard (shorts capped at +20%, coin locked 1 h), a loss breaker, stale settlement after 10 minutes of feed failure, and an LP withdrawal stress fee. Trader tools: on-chain take-profit/stop-loss fired by anyone, escrowed orders that open at a trigger price, add-margin, and one-click trading through session keys (LevRouter, P-256 EIP-712 intents, relayer pays gas). LevExchange delegatecalls LevExchangeAdmin through its fallback (shared storage in LevExchangeBase). Nothing upgradeable; owner meant to be a multisig with a timelock.

Please verify above all: the exchange's ETH always equals trader balances + open stakes + margin + treasury + order escrow, and pool ETH equals pool cash; no trader, alone or with keeper actions and pool price manipulation, can extract more from the pool than the rules allow (check every exit path: close, closeFor, closeByTrigger, closeAtMaxWin, liquidate, settleRugged, the stale path, and order fills); the pool can always pay every open max win and LP withdrawals only come from unreserved cash; LP deposits and withdrawals can't be priced unfairly (NAV range, margin counted only on the deposit side, cooldown, stress fee, valuation pause); exits can't be frozen; the three price feeds resist single-block or single-sample manipulation and depth inflation; session keys can't exceed their signed limits or withdraw anywhere but the owner; order escrow and refunds are exact; the delegatecall split shares one storage layout and reentrancy guard; and no admin power reaches trader balances, stakes, margin, escrow or pool cash beyond the documented, bounded config changes.
```

## Same request as an API body (`job.open`)

```json
{
  "objective": "<the request text above>",
  "template": "audit",
  "repoUrl": "https://github.com/0xtenang/PepesFamily.git",
  "baseCommit": "72b40ae4b730938846619eaa3f7042169cdc4477"
}
```
