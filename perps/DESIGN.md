# MemeLev — design

Working name. Leveraged long/short bets on a curated list of Robinhood Chain memecoins, settled against one shared ETH pool. The pool is seeded and topped up by the creator fees of our own platform token, and anyone can join it as an LP.

## How it works

1. **LPs** deposit ETH into `LevPool` and get LP shares. Creator fees from our platform token arrive through `CreatorFeeRouterV2` and are added to the pool without minting shares, so they raise the LP share price.
2. **Traders** deposit ETH into `LevExchange`, then open a long or short on a listed coin with a stake and leverage. The pool is the other side of every bet. There is no order book: every order fills at once against the pool.
3. **One-click trading.** After one wallet approval, trades are signed by a session key in the browser and submitted by our relayer, which pays the gas. No wallet pop-up per trade. Trading straight from the wallet still works.
4. **Prices** come from the coin's own Uniswap pool on Robinhood Chain: a fast and a slow time-weighted average plus the live price.
5. **Keepers** (our bot, or anyone) liquidate losing positions, close positions that hit their max win, settle shorts after a rug, and record prices for Uniswap V4 coins.

Everything is on-chain: positions, P&L, fees and the pool's books. The relayer only submits what the trader's key signed; it can't change a trade.

## Rules and defaults

All numbers are owner-settable within hard limits written into the contract.

| Rule | Default | Inverse | Note |
|---|---|---|---|
| Open fee | max(1% of stake, 0.25% of size) | same | |
| Close fee | max(1% of what comes back, 0.25% of size) | same | |
| Profit fee | 10% of profit | same | |
| **Pool's share of trading fees** | **50%** | 20% | Improvement 4. Contract floor: 20% |
| Holding fee | 0.05% of size per hour, first hour free, 100% to pool | same | |
| **Crowded side pays** | **3× holding fee** | 1× | Improvement 1. Per coin, the side with more open size |
| **Max win on shorts** | **+100%** | same as longs | Improvement 2 |
| **Max short leverage** | **5x** | 10x | Improvement 2 |
| Max win on longs | +400%, +600% from 10 ETH of pool cash, +1000% from 20 ETH, and never more than 200% × leverage | +400/600/1000% (SOL tiers) | A 1x long wins at most +200%, so a hedged 1x pair can't fill the pool's coverage cheaply |
| Leverage by coin liquidity | 10x from 25 ETH, 5x from 7.5 ETH, else 2x | 10x/5x/2x (SOL tiers) | Liquidity is averaged over 30 minutes; also capped per coin by the curator |
| Net size per coin | min(curator cap, 0.5% of coin's ETH liquidity) | 2 SOL / 0.5% | Each side is also capped at twice that, so offsetting longs and shorts can't stack past it |
| Room for open max wins | 50% of pool cash | same | Pool can always pay every winner |
| Liquidation | equity at or below 15% of stake | same | 25% of what is left goes to the liquidator. A trader closing their own position always gets what is left |
| Rug guard | fast price 80% under slow price: shorts settle at most +20%, new bets locked 1 hour | same | Anyone can trigger it when the condition holds. While the live price shows a rug the averages haven't caught yet, shorts can't close or take a max win |
| Loss breaker | new bets pause for a full hour after the pool loses 10% in trading within an hour | "protection engine" | LP deposits and withdrawals don't count |
| Stale price | price feed failing for 10 minutes without a break: positions close at the last good fast price | same idea | Nothing gets stuck. The failures must be recorded at least every 2 minutes, so a feed that recovered quietly can't be settled at an old price |
| LP withdrawal | 24-hour cooldown (never under 1 hour), then a 2-day window; pays the lower of the value at request and at withdrawal; only from cash not reserved for max wins | n/a | Deposits and withdraw requests wait while a rug is being settled |
| **On-chain book** | **all positions and P&L on-chain, no co-signer** | off-chain engine | Improvement 5 |
| One-click trading | session key with expiry, limits and a daily budget; relayer pays gas | one-click trading for 24 h | See below |

Hedging (improvement 3) is left out on purpose.

## One-click trading

Learned from Veranta (formerly Avantis), adapted for an on-chain book with ETH balances.

1. **Approve once.** "Enable one-click trading" creates a P-256 key in the browser with WebCrypto, marked non-extractable, so code can't copy it out of the browser. One wallet transaction calls `LevRouter.authorize`, usually with the deposit attached. It sets:
   - expiry: at most 7 days, default 24 h
   - allowed actions: open, close positions this key opened, close any position, withdraw to the owner
   - max leverage
   - slippage bounds for opens and closes
   - max stake per trade, max open stake, and a daily budget that counts the open fee too and refills gradually over 24 h
2. **Each trade.** The app builds an EIP-712 message (Open, Close or Withdraw), and the session key signs it with no pop-up. Opens and closes carry a price limit. Each message carries:
   - a random one-time nonce
   - a deadline of 30 s (the router rejects anything more than 120 s ahead)
   - the session's generation, so revoking a key and approving it again can't bring its old messages back
3. **Submission.** The relayer simulates the call, sends it and pays the gas. There is no relay fee. Anyone may submit a signed message, so a backup relayer or the trader can submit it if ours is down.
4. **What a stolen session key can do.** Only what the limits allow:
   - open and close within them, at fills no worse than the slippage bound from the fast price, so it can't force a fill at a pushed price
   - lose at most the daily budget
   - withdraw only to the owner's own wallet

   It can never move funds anywhere else.
5. **Turning it off:**
   - `revoke(key)`
   - `revokeAll()` kills every key and every message not yet run
   - `revokeBySig`, where the key logs itself out with no gas; it works even while signed trading is paused
   - `cancelNonce`
   - the guardian's `setPaused` stops every signed path at once (for example if the web app is compromised), while wallet trading keeps working. The guardian can pause but only the owner can unpause
   - the guardian's `revokeEverySession` voids every session of every trader at once

## Fair prices

- **Fills** use whichever is worse for the trader: the live price or the fast average (default 60 s). Pushing the live price around only hurts the person doing it.
- **Liquidations and max-win closes** use the fast average, so a one-block spike can't trigger them. An open that the fast average would liquidate at once is refused.
- **Pool value (NAV)** marks open positions at the live price and at both averages (fast, and slow at default 30 min). Withdrawals use whichever value is lowest for the pool, and deposits use whichever is highest, so an LP can't act on a move the averages haven't caught up with.

Price oracles, one per listed coin:
- `UniV3Oracle` reads Uniswap V3's built-in TWAP (`observe`), and the harmonic mean of in-range liquidity over the slow window, never more than the WETH the pool really holds. It refuses to report until the pool keeps more observations than the slow window has seconds, so nobody can run the history short to force the stale fallback. Fully trustless.
- `UniV4SampledOracle` is for Uniswap V4 coins, which have no built-in TWAP. Keepers record the live price and depth at least 30 s apart. The fast price is the median of the last 3 samples, so one pushed sample can't move it; the slow average is built from the samples in its window, and the reported depth is the smallest one there.

## Pool value

`NAV = pool cash − what open positions are worth to traders right now`, clamped per side between "all stakes lost" and "all max wins paid", and taken at whichever of the live, fast and slow prices is worse for the side of the deal. Nobody can buy in cheap while traders are losing, or exit early while they are winning. `LevLens` computes it and `LevPool` reads it.

Two more things keep the price fair between LPs:
- Holding fees the pool is already owed count toward the value a depositor pays (a lower bound of them), so a new LP can't take a share of fees earned before they joined.
- Each deposit and withdraw request first pulls in creator fees waiting in the fee router, so nobody can deposit just before a large batch lands.

Creator fees that arrive before any LP joins become house shares, held by a dead address at the current price. They stay in the pool for good and earn their share like any LP.

## Contracts

| Contract | Job |
|---|---|
| `LevExchange` | Trader balances, positions, fees, caps, liquidations, rug guard, breaker. Owner, keeper and view calls it doesn't have itself go through its fallback to `LevExchangeAdmin`, which runs them on the exchange's own storage (`delegatecall`) |
| `LevExchangeAdmin` | Code only: listing, config, pauses, guardian, price refresh, rug-guard trigger, views. Holds no state of its own |
| `LevRouter` | One-click trading: session keys, signed Open/Close/Withdraw messages, limits, revocation |
| `LevLens` | Read-only previews: quotes, position status, markets, keeper to-do list, and the pool's value range |
| `LevPool` | LP shares, NAV, deposits, cooldown withdrawals, creator-fee donations |
| `CreatorFeeRouterV2` | Claims the platform token's Pons creator fees and splits them 80% pool, 10% operations, 10% buyback and burn (see TOKEN_LAUNCH.md) |
| `PonsV4BuybackExecutor` | Buys the platform token on its Pons Uniswap V4 pool for the buyback share and sends it to the burn address |
| `UniV3Oracle` / `UniV4SampledOracle` | Price feeds per coin |
| `LevLogic`, `ConfigCheck`, `TickRatio` | Shared math, config limits, tick math |

## Not done yet

- **Audit.** These contracts hold user funds. They need an external audit and a testnet run before mainnet.
- **Chain details.** Confirm against docs.robinhood.com before deploying:
  - WETH, Uniswap V3 and V4 PoolManager addresses on Robinhood Chain (chain ID 4663)
  - whether the chain has the RIP-7212 P-256 verifier (one-click trades cost about 950k gas without it)
  - the 24 KB contract size limit
  - how the sequencer orders transactions
- **Legal.** Leveraged trading for the public is regulated in most countries, and so may be running a relayer that submits trades. Get advice before launch.
- **Wallet-age rule** from Inverse can't be checked on-chain and is not included.
- **Take-profit and stop-loss orders** are not built yet. Stops belong on-chain and should fire on the fast average, as liquidations do.

## Known limits

- **Price history on fast blocks.** Robinhood Chain makes blocks quickly, and a Uniswap V3 pool stores one observation per block with a swap. A busy coin can need more than 1,000 observations to cover a 30-minute slow average. If history runs short, the feed reverts: new positions stop, and closes fall back to the last good fast price. Size the observation count per coin, or shorten its slow window.
- **Relayer timing.** The relayer chooses when to submit within the 30 s deadline, and the fill is bounded by the session's slippage limit. Its logs record when each intent was received and when it was included, so delays can be audited.
- **Config changes apply at once**, within the contract's hard limits, including to messages already signed. Put the owner behind a multisig with a timelock.
- **Curator trust.** Listing a coin means trusting its price feed.
- **Capped winners in pool value (open).** Pool value caps each side's winnings as a whole, not per position. A winner past its own max win therefore counts above its cap until someone calls `closeAtMaxWin`. A depositor can buy in at that low value and close the winner in the same transaction. Paying the closer makes keepers clear such positions within a pass, but doesn't stop the same-transaction version. See the critic's medium finding in SECURITY_REVIEW.md.
- **Exchange size.** The exchange is split in two to stay under the 24,576-byte limit: `LevExchange` is 15,609 bytes and `LevExchangeAdmin` 9,814. Trade paths belong in `LevExchange`; owner, keeper and view calls in `LevExchangeAdmin`, with any new state added to `LevExchangeBase` so the two layouts stay the same.
