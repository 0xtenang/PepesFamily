# PepesFamily

A Pons-style fixed-supply token launchpad on Robinhood Chain (chain ID 4663), built on **Uniswap v4**. Every launch is paired with either **ETH** or **IMD** (`0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`), and every trade pays a 4% fee that goes partly to holders.

## Live on Robinhood Chain (4663)

| Contract | Address |
| --- | --- |
| PepesFamily (launchpad + v4 hook) | [`0x2d7689E48Fd71D9A0f225C673D7b8F8A693368CC`](https://robinhoodchain.blockscout.com/address/0x2d7689E48Fd71D9A0f225C673D7b8F8A693368CC) |
| PepesFamilyRouter | [`0xA73604EA3C393B47573986ff9Ce5A9EAb61883dC`](https://robinhoodchain.blockscout.com/address/0xA73604EA3C393B47573986ff9Ce5A9EAb61883dC) |
| PepesFamilyEthRouter (trade IMD pairs with ETH) | [`0x79eeE0C12C1284bc046e4494Eea6180695F5028A`](https://robinhoodchain.blockscout.com/address/0x79eeE0C12C1284bc046e4494Eea6180695F5028A) |

Deployed at block 76719371. Source verified on [Sourcify](https://repo.sourcify.dev/4663/0x2d7689E48Fd71D9A0f225C673D7b8F8A693368CC). Owner and fee recipient: `0x3c8A4d94B3219F6633F2cC94094f4765b30c691C`.

## How it works

- **Launch:** each launch deploys a `PadToken` with a fixed 1,000,000,000 supply. All of it goes into a new Uniswap v4 pool as single-sided liquidity, running from the launch price to the end of the price curve. The pool is paired with ETH or IMD, the creator's choice. It behaves like `x*y=k` with virtual quote liquidity, so the starting market cap is about 1.5 ETH or about 635 IMD (both roughly $4k on 2026-09-30).
- **Locked liquidity:** the liquidity position belongs to `PepesFamily`, which has no function to remove it, so it is locked forever. `PepesFamily` is also the pools' v4 hook, and the hook blocks anyone else from creating pools or adding liquidity with it.
- **Fees: 4% of the quote side of every swap.** The hook charges it no matter which router sends the swap: our `PepesFamilyRouter`, the Uniswap app, Universal Router, or an aggregator.
  - 1% goes to the protocol. Anyone can call `collectProtocolFees(quote)` to send it to `0x3c8A4d94B3219F6633F2cC94094f4765b30c691C`.
  - 3% goes to the token's holders pro rata, paid in ETH or IMD. The accrual is O(1) and automatic, and holders withdraw with `claim()` on the token.
  - The hook holds fees as PoolManager ERC-6909 claims until they are flushed. `PepesFamilyRouter` flushes on every trade. Credit goes to holders before a buyer receives tokens and after a seller's tokens leave, so a trader doesn't earn from their own trade.
  - For swaps through other routers, fees are flushed at the next PepesFamilyRouter trade or `claim()`. The holders at that moment receive them, which can include that trader.
- **Approvals:** sells need no approval. IMD buys need an IMD approval for `PepesFamilyRouter`.
- **Paying with ETH on IMD pairs:** the website routes buys and sells through `PepesFamilyEthRouter`. Selling to ETH needs a one-time token approval for that router.
- **USD prices:** the website shows market caps and prices in USD, read from on-chain Uniswap v4 pools (ETH/USDG and IMD/ETH). No off-chain price API is involved.

Pushing rewards into every holder's wallet on every trade isn't possible on-chain, because gas would grow with the number of holders. So rewards accrue automatically and each holder claims them, the same way reflection/dividend tokens work.

## Contracts

| Contract | Role |
| --- | --- |
| `src/PepesFamily.sol` | Launcher, v4 hook (fees), and owner of the locked liquidity. Its address must carry hook flags `0x28CC` (mined CREATE2 salt). |
| `src/PepesFamilyRouter.sol` | Buy, sell, and launch-with-initial-buy for the website. Deployed by PepesFamily. |
| `src/PepesFamilyEthRouter.sol` | Buy or sell IMD-paired tokens with ETH in one transaction (ETH ⇄ IMD ⇄ token through the Uniswap v4 IMD/ETH pool). No owner, holds no funds. |
| `src/PadToken.sol` | The launched ERC20, with pro-rata holder rewards. |

Uniswap v4 on Robinhood Chain: PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, V4Quoter `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94`.

## Setup

Needs [Foundry](https://book.getfoundry.sh/getting-started/installation). Dependencies (forge-std, Uniswap v4-core) are git submodules:

```bash
git clone --recursive https://github.com/0xtenang/PepesFamily.git
cd PepesFamily/contracts
forge build
```

## Test

```bash
cd contracts
forge test                                           # 25 unit + attack tests against a real v4 PoolManager
FORK_RPC=https://robinhood.drpc.org forge test       # + 5 fork tests against live mainnet (incl. the deployed contracts)
```

The tests cover:
- the 4% fee and the 1%/3% split for every swap kind (exact-in/out, buy/sell) through a third-party router
- both currency orderings for IMD pairs
- pro-rata payouts and transfers
- exits, and the hook blocking outside pools and liquidity
- slippage and admin controls
- a fuzzed solvency check
- mainnet fork runs with the real PoolManager, real IMD, and Uniswap's deployed Quoter

## Deploy (mainnet)

The owner defaults to `0x3c8A…691C`, and any wallet can pay for the deployment (about 0.0003 ETH). The script mines the hook salt, deploys through the standard CREATE2 factory, and writes `deployments/robinhood.json`.

```bash
cd contracts
forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --interactive
```

Optional environment variables:
- `ETH_START_MCAP` (wei, default `1.5e18`)
- `IMD_START_MCAP` (wei, default `635e18`)
- `OWNER`

Verify on Blockscout:

```bash
forge verify-contract <PAD> src/PepesFamily.sol:PepesFamily --chain-id 4663 --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api --guess-constructor-args
```

## Website

Copy `pad`, `router` and `block` from `contracts/deployments/robinhood.json` into `CONFIG` at the top of `web/index.html`, then host the file on any static host. For production, point `CONFIG.rpc` at a paid RPC; the public endpoint is rate-limited.

## Owner powers

- `setFeeRecipient`: changes where the 1% protocol fee goes.
- `setStartTick`: sets the starting market cap for future launches.
- `transferOwnership` + `acceptOwnership`: a two-step handover, so a typo can't lose the admin role.

The owner **can't** change the fee percentages, touch pool liquidity or holder rewards, pause trading, upgrade the contracts, or add quote assets other than ETH and IMD. No contract is upgradeable.

## Security

**What the contracts guarantee (each one covered by tests):**
- **Liquidity is locked.** The position belongs to `PepesFamily`, which has no remove function. The hook reverts on any outside pool creation or liquidity add.
- **Hook entry points only accept the PoolManager**, and `launchFor` only accepts the router. The unlock callbacks can only be reached through the contracts' own `unlock` calls.
- **The router only moves `msg.sender`'s funds.** The allowance-free token pull is limited to that one router and to the caller's own tokens.
- **Fees can't be redirected.** Anyone can trigger `collectProtocolFees`/`flush`, but the funds only go to `feeRecipient` or the token's holders. The fee claims (ERC-6909) can only be spent by `PepesFamily`.
- **Casts are checked.** Fee math uses checked casts (`SafeCast`), so extreme swap sizes revert instead of truncating.
- **Payouts can't get stuck.** `distribute()` never reverts, so an unusual quote balance can't block trades or claims. `claim()` is reentrancy-guarded and updates state before paying.
- **The website is hardened:**
  - all token names and metadata are HTML-escaped
  - only `https://`/`ipfs://` images and links are shown
  - ethers.js is pinned with Subresource Integrity (SRI)
  - a Content-Security-Policy restricts where code can load from
  - IMD approvals are for the exact amount, never unlimited

**Known risks, by design:**
- **Dividend sniping.** Someone can buy just before a big trade to catch part of its 3% holder fee, then sell. They pay 4% on each side, so it only pays off against trades much larger than their own position. Every reflection-style token has this trade-off.
- **Late flushes for other routers.** Fees from swaps through other routers (the Uniswap app, aggregators) reach holders at the next flush, so that trader can share in their own fee.
- **Launch sniping.** Bots can buy in the launch block. Creators can buy first, atomically, with `PepesFamilyRouter.launch(..., initialBuy, ...)`.
- **IMD risk.** IMD is a LayerZero OFT whose owner controls its bridge configuration. That is an IMD-level risk, outside these contracts.
- **Hosting headers.** Serve the site over HTTPS, and set `X-Frame-Options: DENY` / `frame-ancestors 'none'` on your host. These headers can't be set from the HTML file.

**Not audited.** Get an independent audit before significant value flows through it.
