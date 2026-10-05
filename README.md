# PepesFamily

**Website: [pepesfamily.fun](https://www.pepesfamily.fun)**

A Pons-style fixed-supply token launchpad on Robinhood Chain (chain ID 4663), built on **Uniswap v4**. Every launch is paired with either **ETH** or **IMD** (`0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`), and every trade pays a 4% fee that goes partly to holders.

## Live on Robinhood Chain (4663)

Owner and fee recipient for every version: `0x3c8A4d94B3219F6633F2cC94094f4765b30c691C`.

**v3: current. All new launches go here.** Same as v2, plus a fix for an audit finding: rewards are never distributed while the Uniswap PoolManager is unlocked by an outside caller, so pool tokens borrowed through v4 flash accounting can't be counted as held (see `AUDIT.md`).

| Contract | Address |
| --- | --- |
| PepesFamily v3 (launchpad + v4 hook) | [`0xC5a1f48C03635b83D79667463785bC2c6BcE28cC`](https://robinhoodchain.blockscout.com/address/0xC5a1f48C03635b83D79667463785bC2c6BcE28cC) |
| PepesFamilyRouter v3 | [`0x8A9b6A990d13f25F6393aCacfB013F980c763a27`](https://robinhoodchain.blockscout.com/address/0x8A9b6A990d13f25F6393aCacfB013F980c763a27) |
| PepesFamilyEthRouter v3 | [`0x891B710b36D0bDb1D6B53CB979696EbE43c2d129`](https://robinhoodchain.blockscout.com/address/0x891B710b36D0bDb1D6B53CB979696EbE43c2d129) |

v3 was deployed at block 77210723 and its source is verified on Sourcify.

**v2: still live.** Its tokens keep trading. The v2 token source is kept in `src/v2/PadTokenV2.sol`, and the rest of v2 is at commit `68ba9e3`.

| Contract | Address |
| --- | --- |
| PepesFamily v2 (launchpad + v4 hook) | [`0x072Fb5A1B65F30d59BcD11BEeD99803675bCE8CC`](https://robinhoodchain.blockscout.com/address/0x072Fb5A1B65F30d59BcD11BEeD99803675bCE8CC) |
| PepesFamilyRouter v2 | [`0x85D6695CBE0BaF221a4BBd39F0b368B893e70D4b`](https://robinhoodchain.blockscout.com/address/0x85D6695CBE0BaF221a4BBd39F0b368B893e70D4b) |
| PepesFamilyEthRouter v2 (trade IMD pairs with ETH) | [`0xce3540Bf1D4b219B7B2055508A83B09A0e1df9eF`](https://robinhoodchain.blockscout.com/address/0xce3540Bf1D4b219B7B2055508A83B09A0e1df9eF) |

v2 was deployed at block 76968615 and its source is verified on Sourcify. v2 tokens have no admin and expose `owner() = 0x0` (shown as renounced). They use standard ERC-20 approvals with no exempt addresses, plus EIP-2612 `permit` for gasless sell approvals.

**v1: still live.** Its tokens, including Pepes, keep trading forever.

| Contract | Address |
| --- | --- |
| PepesFamily v1 | [`0x2d7689E48Fd71D9A0f225C673D7b8F8A693368CC`](https://robinhoodchain.blockscout.com/address/0x2d7689E48Fd71D9A0f225C673D7b8F8A693368CC) |
| PepesFamilyRouter v1 | [`0xA73604EA3C393B47573986ff9Ce5A9EAb61883dC`](https://robinhoodchain.blockscout.com/address/0xA73604EA3C393B47573986ff9Ce5A9EAb61883dC) |
| PepesFamilyEthRouter v1 | [`0x79eeE0C12C1284bc046e4494Eea6180695F5028A`](https://robinhoodchain.blockscout.com/address/0x79eeE0C12C1284bc046e4494Eea6180695F5028A) |

v1 was deployed at block 76719371 and verified on Sourcify. Its token source is kept in `src/v1/PadTokenV1.sol` so v1 tokens can still be verified. The other v1 sources are in git history at commit `a549093`.

## Audits (IMD Swarm)

| Scope | Code | Result | Report |
| --- | --- | --- | --- |
| PepesFamily launchpad (v2 contracts) | `d1ad578` | 1 medium, 3 low, 3 info | [explorer.imd.fun/jobs/a3e708e2…](https://explorer.imd.fun/jobs/a3e708e2-fb57-43ea-a163-d93b916694a2) |
| Pepes token (v1, as deployed) | `8c1869c` (branch `audit-pepes-v1`) | 1 high, 1 medium, 3 low, 6 info; the "honeypot", "owner can change balance" and "suspicious function" scanner warnings were confirmed false positives | [explorer.imd.fun/jobs/46a0c47b…](https://explorer.imd.fun/jobs/46a0c47b-d3ad-4c50-973e-369203a488ce) |

Status of the main findings:
- **High (rewards captured with flash-borrowed pool tokens):** fixed in v3. For v1 and v2 tokens, waiting holder fees are paid out promptly from the Admin page.
- **Medium (fee on partially filled swaps):** open. A swap through a third-party router that sets a tight price limit, and only partly fills, pays 4% of the requested amount. PepesFamily's own routers always fill fully and are not affected.

## How it works

- **Launch:** each launch deploys a `PadToken` with a fixed 1,000,000,000 supply. All of it goes into a new Uniswap v4 pool as single-sided liquidity, running from the launch price to the end of the price curve. The pool is paired with ETH or IMD, the creator's choice. It behaves like `x*y=k` with virtual quote liquidity, so the starting market cap is about 1.5 ETH or about 635 IMD (both roughly $4k on 2026-09-30).
- **Locked liquidity:** the liquidity position belongs to `PepesFamily`, which has no function to remove it, so it is locked forever. `PepesFamily` is also the pools' v4 hook, and the hook blocks anyone else from creating pools or adding liquidity with it.
- **Fees: 4% of the quote side of every swap.** The hook charges it no matter which router sends the swap: our `PepesFamilyRouter`, the Uniswap app, Universal Router, or an aggregator.
  - 1% goes to the protocol. Anyone can call `collectProtocolFees(quote)` to send it to `0x3c8A4d94B3219F6633F2cC94094f4765b30c691C`.
  - 3% goes to the token's holders pro rata, paid in ETH or IMD. The accrual is O(1) and automatic, and holders withdraw with `claim()` on the token.
  - The hook holds fees as PoolManager ERC-6909 claims until they are flushed. `PepesFamilyRouter` flushes on every trade. Credit goes to holders before a buyer receives tokens and after a seller's tokens leave, so a trader doesn't earn from their own trade.
  - For swaps through other routers, fees are flushed at the next PepesFamilyRouter trade or `claim()`. The holders at that moment receive them, which can include that trader.
- **Approvals:** v2 sells use a gasless permit signature (or a normal approval) for the router. v1 sells need no approval. IMD buys need an IMD approval for the router.
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

### Pepes Earn IMD (NFT collection)

Live since 2026-10-05 (block 80291676), all contracts source-verified:

| Contract | Address |
| --- | --- |
| PepesEarnIMD (hook, pool owner) | [`0x41Edd4c96a25e9aC6e4CF80C40EB6B85c77aA8CC`](https://robinhoodchain.blockscout.com/address/0x41Edd4c96a25e9aC6e4CF80C40EB6B85c77aA8CC) |
| $EARN token | [`0xf2363c208B1772C3c9dB7a3fe84d75Bf2881fc20`](https://robinhoodchain.blockscout.com/address/0xf2363c208B1772C3c9dB7a3fe84d75Bf2881fc20) |
| NFT (ERC-721 mirror) | [`0x0e4bf5b83740F9E93ED739b2064165561CE75489`](https://robinhoodchain.blockscout.com/address/0x0e4bf5b83740F9E93ED739b2064165561CE75489) |
| Renderer | [`0xdb42735B94b45195cD175aE74C0AE5B40D9351cB`](https://robinhoodchain.blockscout.com/address/0xdb42735B94b45195cD175aE74C0AE5B40D9351cB) |
| Router / ETH router | [`0x3a6ce89cc881aa054d289C7a9456AF4bc3217bcC`](https://robinhoodchain.blockscout.com/address/0x3a6ce89cc881aa054d289C7a9456AF4bc3217bcC) / [`0xB5f81908d652332850dFFCcd898d7e0e0d70467F`](https://robinhoodchain.blockscout.com/address/0xB5f81908d652332850dFFCcd898d7e0e0d70467F) |

Audits (IMD Swarm): [audit](https://explorer.imd.fun/jobs/e6eda4d8-f50d-47cd-9464-9a272283ccd3), [re-check](https://explorer.imd.fun/jobs/f6d3cd0e-8371-417b-80d6-7b99fc9efa0c), [final check](https://explorer.imd.fun/jobs/a58eb2c6-bfc3-441e-86d8-432c2ab15114); deployed from commit `36c2614`.

On-chain Pepes backed by 2,000 `$EARN` tokens ([DN404](https://github.com/Vectorized/dn404)): each whole `$EARN` held is one NFT (at most 1,999 can be in wallets, since a dust buffer stays burned). `$EARN` trades in a Uniswap v4 pool against IMD with the same 4% hook as PepesFamily v3 (1% protocol, 3% to `$EARN` holders in IMD, claimed manually). NFTs can also be traded on marketplaces (1% ERC-2981 royalty, paid by marketplaces straight to the protocol fee recipient) and sold back to the pool at any time.

| Contract | Role |
| --- | --- |
| `src/earn/PepesEarnIMD.sol` | Pool owner and v4 hook for the collection (not a launchpad: one-time `openPool`, liquidity locked forever; it only accepts a token whose buyback targets are `$Pepes` and the PepesFamily v1 router). Exposes the PepesFamily interface, so `PepesFamilyRouter` and `PepesFamilyEthRouter` are reused unchanged. Holds and swaps nothing for royalties. |
| `src/earn/PepesEarnToken.sol` | `$EARN` (DN404 base): holder rewards as in v3, no owner, no privileged function, no default Permit2 allowance, EIP-7702 wallets receive NFTs. Deploys and links its NFT mirror in its own constructor. Unclaimed rewards of a wallet inactive for more than 30 days (activity = a claim, sending `$EARN`, pulling `$EARN` itself, or receiving at least one whole `$EARN`, i.e. one NFT, such as a whole-token pool buy or a marketplace purchase; dust doesn't count), except what it earned in those 30 days, can be recycled by anyone into a reserve that only `buybackAndBurnPepes` can spend: anyone, once an hour, at most 2% of the `$Pepes` pool's IMD depth per call, all bought `$Pepes` sent to the burn address. |
| `src/earn/PepesEarnMirror.sol` | The ERC-721 side (DN404 mirror), created by the token. ERC-2981 royalty of 1% to `PepesEarnIMD.feeRecipient()`. |
| `src/earn/PepesEarnRenderer.sol` | Draws each NFT as SVG on-chain; traits from `keccak256(id)`. #1 "The King", #777 "Gold Pepe". |

The per-call cap and the hourly pace make sandwiching the buyback cost more in the `$Pepes` pool's fees than it can gain, so it needs no trusted caller; the `$Pepes` pool's hook rejects outside liquidity, so its depth can't be inflated. Royalties are not converted on-chain at all, which removes the swap the re-check found exploitable with just-in-time liquidity. IMD Swarm audit (2026-10-04), re-check and final check: all findings fixed; the tests reproduce the attacks and assert the attacker loses.

Deployment order (one account): `PepesEarnRenderer`, `PepesEarnIMD` (CREATE2, hook flags `0x28CC`), `PepesEarnToken(earnIMD, renderer)` (creates the mirror), then `earnIMD.openPool(token)` from the owner. `script/DeployEarn.s.sol` does all of it and writes `deployments/robinhood-earn.json`; copy those addresses into `CONFIG.earn` in `web/index.html` to switch the site's NFT tab from preview to live. Tests: `test/PepesEarn.t.sol`, and on a mainnet fork `FORK_RPC=https://robinhood.drpc.org forge test --mc PepesEarnForkTest`.

### Pepes World (web game)

A single-player browser game at [pepesfamily.fun/world](https://pepesfamily.fun/world/) (`web/world/index.html`, three.js): walk a tiny Pepe planet and deliver letters to villagers, who are on-chain Pepes Earn IMD NFTs (#1 The King lives in the castle). The player's character is their own NFT, drawn by the renderer. Daily goal and streak are kept in the browser.

Who can play: a wallet holding at least 1 `$EARN` (one NFT), or one with a Pepes World pass from `src/world/PepesWorldVault.sol`. A pass is a one-time, non-refundable deposit of `passPrice` `$Pepes` (50,000 at launch) and never expires. The deposits belong to the team: the owner can withdraw them, claim the IMD rewards they earn as `$Pepes` holdings, grant free passes, and change the price of future passes (existing passes are never revoked). The game checks access in the browser only: it holds no prizes, so a bypass gains nothing. Tests: `test/PepesWorld.t.sol`, and on a fork `FORK_RPC=https://robinhood.drpc.org forge test --mc PepesWorldForkTest`. With `CONFIG.vault` empty in `web/world/index.html`, only NFT holders can play.

Uniswap v4 on Robinhood Chain: PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, V4Quoter `0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94`.

## Setup

Needs [Foundry](https://book.getfoundry.sh/getting-started/installation). Dependencies (forge-std, Uniswap v4-core, DN404) are git submodules:

```bash
git clone --recursive https://github.com/0xtenang/PepesFamily.git
cd PepesFamily/contracts
forge build
```

## Test

```bash
cd contracts
forge test                                           # 34 unit + attack tests against a real v4 PoolManager
FORK_RPC=https://robinhood.drpc.org forge test       # + 7 fork tests against live mainnet state
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

## Token source verification

Every launch deploys a new `PadToken` contract, and scanners such as DexScreener and GMGN flag unverified contracts as "not open source". The GitHub Action `.github/workflows/verify-tokens.yml` runs every 15 minutes (or on demand from the Actions tab). It calls `contracts/script/verify-tokens.sh`, which publishes the source of each new token to Sourcify and Blockscout. It needs no keys or secrets. Scanners usually refresh their security checks within a few hours.

## Website

Copy `pad`, `router` and `block` from `contracts/deployments/robinhood.json` into `CONFIG` at the top of `web/index.html`, then host the file on any static host. For production, point `CONFIG.rpc` at a paid RPC; the public endpoint is rate-limited.

Image upload on the launch form uses the Vercel function `web/api/upload.js`, which pins images to IPFS through Pinata. Set the environment variable `PINATA_JWT` (a Pinata API key JWT with permission to upload files) in the Vercel project; the key never reaches the browser. Without it the Upload button stays hidden and creators paste image links instead.

## Owner powers

- `setFeeRecipient`: changes where the 1% protocol fee goes.
- `setStartTick`: sets the starting market cap for future launches.
- `transferOwnership` + `acceptOwnership`: a two-step handover, so a typo can't lose the admin role.

The owner **can't** change the fee percentages, touch pool liquidity or holder rewards, pause trading, upgrade the contracts, or add quote assets other than ETH and IMD. No contract is upgradeable.

## Security

**What the contracts guarantee (each one covered by tests):**
- **Liquidity is locked.** The position belongs to `PepesFamily`, which has no remove function. The hook reverts on any outside pool creation or liquidity add.
- **Hook entry points only accept the PoolManager**, and `launchFor` only accepts the router. The unlock callbacks can only be reached through the contracts' own `unlock` calls.
- **The routers only move `msg.sender`'s funds.** v2 tokens have no allowance exemptions at all. v1 tokens let their router pull the caller's own tokens without an allowance.
- **Fees can't be redirected.** Anyone can trigger `collectProtocolFees`/`flush`, but the funds only go to `feeRecipient` or the token's holders. The fee claims (ERC-6909) can only be spent by `PepesFamily`.
- **Casts are checked.** Fee math uses checked casts (`SafeCast`), so extreme swap sizes revert instead of truncating.
- **Payouts can't get stuck.** `distribute()` never reverts, so an unusual quote balance can't block trades or claims. `claim()` is reentrancy-guarded and updates state before paying.
- **The website is hardened:**
  - all token names and metadata are HTML-escaped
  - only `https://`/`ipfs://` images and links are shown
  - ethers.js is pinned with Subresource Integrity (SRI)
  - a Content-Security-Policy restricts where code can load from
  - IMD approvals are for the exact amount, never unlimited

**Audit finding (fixed in v3, affects v1 and v2 tokens):** inside a Uniswap v4 unlock anyone can flash-borrow a pool's tokens and be counted as a holder if a reward distribution runs at that moment. They could capture part of the holder fees still waiting to be paid out, or, as a trader, part of their own 3%. Token balances, selling and already-earned rewards are not affected. v3 never distributes while an outside caller has the PoolManager unlocked. For v1/v2 tokens, pay out waiting holder fees regularly from the Admin page (a normal transaction, outside any unlock); then there is nothing to capture.

**Known risks, by design:**
- **Dividend sniping.** Someone can buy just before a big trade to catch part of its 3% holder fee, then sell. They pay 4% on each side, so it only pays off against trades much larger than their own position. Every reflection-style token has this trade-off.
- **Late flushes for other routers.** Fees from swaps through other routers (the Uniswap app, aggregators) reach holders at the next flush, so that trader can share in their own fee.
- **Launch sniping.** Bots can buy in the launch block. Creators can buy first, atomically, with `PepesFamilyRouter.launch(..., initialBuy, ...)`.
- **IMD risk.** IMD is a LayerZero OFT whose owner controls its bridge configuration. That is an IMD-level risk, outside these contracts.
- **Hosting headers.** Serve the site over HTTPS, and set `X-Frame-Options: DENY` / `frame-ancestors 'none'` on your host. These headers can't be set from the HTML file.

**Not audited.** Get an independent audit before significant value flows through it.
