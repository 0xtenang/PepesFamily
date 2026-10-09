# PepesFamily

**Website: [pepesfamily.fun](https://www.pepesfamily.fun)**

A Pons-style fixed-supply token launchpad on Robinhood Chain (chain ID 4663), built on **Uniswap v4**. Every launch is paired with either **ETH** or **IMD** (`0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`), and every trade pays a 4% fee that goes partly to holders.

## Live on Robinhood Chain (4663)

Owner and fee recipient for every version: `0x3c8A4d94B3219F6633F2cC94094f4765b30c691C`.

**v5: current. All new launches go here.** v4 plus the creator's choice of where the 3% goes (creator / holders / burn, see "Launchpad v5" below).

| Contract | Address |
| --- | --- |
| PepesFamily v5 (launchpad + v4 hook) | [`0xC26003787503b978033427F77047fAF5551Ca8CC`](https://robinhoodchain.blockscout.com/address/0xC26003787503b978033427F77047fAF5551Ca8CC) |
| PepesFamilyRouter v5 | [`0x515aC666729a73761DA06b323133286C8a968CDf`](https://robinhoodchain.blockscout.com/address/0x515aC666729a73761DA06b323133286C8a968CDf) |
| PepesFamilyEthRouter v5 | [`0x349059fc128bEe463C1Ee6a732F8201907a78035`](https://robinhoodchain.blockscout.com/address/0x349059fc128bEe463C1Ee6a732F8201907a78035) |
| PepesFamilyLens v5 (token list) | [`0xd43CE11019393b4C60304978E3d789D316414B20`](https://robinhoodchain.blockscout.com/address/0xd43CE11019393b4C60304978E3d789D316414B20) |

v5 was deployed at block 83983028 from commit `070e0e7` (recorded in `contracts/deployments/robinhood-v5.json`); all four contracts are verified on Sourcify. v5 tokens use the same `PadToken` source as v4.

**v4: still live.** v3 plus expiry of unclaimed holder rewards: a wallet inactive for more than 7 days loses rewards older than 7 days to the protocol address, which uses them to buy back and burn $Pepes (see "Launchpad v4" below). IMD-only launches.

| Contract | Address |
| --- | --- |
| PepesFamily v4 (launchpad + v4 hook) | [`0x6C08cfB2aB8Dab6d4Bc22ab8F1C248a0268D28cc`](https://robinhoodchain.blockscout.com/address/0x6C08cfB2aB8Dab6d4Bc22ab8F1C248a0268D28cc) |
| PepesFamilyRouter v4 | [`0xDB202196E62413c0eFB59e926EA1BD4817dB7226`](https://robinhoodchain.blockscout.com/address/0xDB202196E62413c0eFB59e926EA1BD4817dB7226) |
| PepesFamilyEthRouter v4 | [`0x19f112328cFb44191704Dba441050008Fe85C361`](https://robinhoodchain.blockscout.com/address/0x19f112328cFb44191704Dba441050008Fe85C361) |

v4 was deployed at block 82010056 from commit `92aae9f` (recorded in `contracts/deployments/robinhood-v4.json`) and its source is verified on Sourcify.

**v3: still live.** Its tokens keep trading; its token source is kept in `src/v3/PadTokenV3.sol`. Same as v2, plus a fix for an audit finding: rewards are never distributed while the Uniswap PoolManager is unlocked by an outside caller, so pool tokens borrowed through v4 flash accounting can't be counted as held (see `AUDIT.md`).

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
| `src/PadToken.sol` | The launched ERC20, with pro-rata holder rewards (v4: with 7-day expiry, see below). |
| `src/v1`, `src/v2`, `src/v3` | Exact token sources of earlier launchpad versions, kept so their tokens can be source-verified. |

### Multichain: Ethereum (in preparation)

The same v5 contracts are being deployed on Ethereum, IMD's home chain, so creators can launch on Robinhood Chain or Ethereum. Per-chain settings live in `contracts/script/Chains.sol`:

| | Robinhood Chain (4663) | Ethereum (1) |
| --- | --- | --- |
| IMD | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| ETH/IMD pool used by the ETH router | 1% fee, tick spacing 100, no hooks | 1% fee, tick spacing 200, no hooks (`0xb07d640f…bfb3`) |
| Launchpad v5 (CREATE2, hook flags `0x28CC`) | `0xC26003787503b978033427F77047fAF5551Ca8CC` | `0xa89083083119B70c06b372dC85Dc6155a8F568CC` (not deployed yet) |

Owner and fee recipient are `0x3c8A…691C` on both. `CHAIN_ID=1 forge script script/PadDeployData.s.sol` prints Ethereum's deployment data; `FORK_RPC_ETH=https://ethereum-rpc.publicnode.com forge test --mc EthereumForkTest` runs launch, split, quoter, ETH-router and expiry tests on Ethereum state. Base will follow once IMD is available there.

### Launchpad v5

v5 keeps v4 (IMD pairs, 7-day reward expiry) and lets each creator choose, at launch and forever, where the 3% goes. The 1% protocol fee is unchanged.

| Preset | Creator | Holders | Burn |
| --- | --- | --- | --- |
| Diamond hands (default) | 0% | 3% | 0% |
| Creator-backed | 2% | 1% | 0% |
| Deflationary | 0% | 0% | 3% |
| Custom | any mix in 0.5% steps, creator at most 2%, total 3% | | |

- **Creator share:** paid in IMD, held as PoolManager claims until anyone calls `collectCreatorFees(token)`, which always pays the token's `creatorPayout` (the creator). The payout address can hand it on in two steps (`setCreatorPayout`, then `acceptCreatorPayout` by the new address). Creator fees don't expire.
- **Holder share:** as in v4, including the 7-day expiry.
- **Burn share:** taken in the token itself from every swap, through any router: a buyer receives that share less, a seller pays it on top. During the swap it is held as a PoolManager claim; `flush(token)` (run by our routers on every trade, or by anyone) burns it to `0x…dEaD`. Nothing is bought on the market, so there is nothing to front-run. The IMD fee is 4% minus the burn share (1% protocol + creator + holders; rounding goes to the protocol).
- **Full fills only:** a swap stopped early by its price limit reverts, so nobody pays the fee or burn of an amount the pool didn't trade (this also closes the partial-fill finding open since v3). Our routers always fill completely.
- The hook takes the fee of the swap's specified currency in `beforeSwap` and the other one in `afterSwap`, for all four swap kinds. `getTokenInfo` / `getTokens` / `marketCap` moved to `PepesFamilyLens` (deployed by the launchpad, `lens()`) to keep the launchpad under the contract size limit; its market cap counts only the supply that isn't burned.
- IMD Swarm [audit](https://explorer.imd.fun/jobs/8f96baf6-1313-4953-a6ef-e6426feaf795) (1 medium, 2 low, 4 info): all fixed, each with a test.
- Tests: every split for all four swap kinds in both currency orders, creator fee collection and payout hand-over, a deflationary token with full exits, a split fuzz, claim backing, and a mainnet-fork check that Uniswap's V4Quoter matches the router with the burn included.

### Launchpad v4

v4 is v3 with one addition: **holder rewards are meant to be claimed.** Launches are IMD-only.

- **Activity:** a wallet is active when it claims, buys (any amount: the hook records the user of the PepesFamily routers, or the transaction's signer for third-party routers), sends tokens, pulls tokens itself, or receives tokens for the first time. Tokens someone else sends don't count, so nobody can keep another wallet's rewards from expiring. Smart-contract wallets buying through third-party routers should claim at least weekly.
- **Expiry:** when a wallet has been inactive for more than 7 days, its unclaimed rewards expire, except what it earned during those last 7 days. Anyone can call `recycle(holder)` (or `recycleMany`) on the token, and `claim()` does it first for the claimer; either way only expired rewards move, and only to the launchpad's `feeRecipient`. Known limit: tokens a wallet receives during its last 7 days count toward its recent balance, so a large gift can delay the expiry of its older rewards by up to 7 days.
- **Buyback and burn (manual):** expired rewards go to the PepesFamily protocol address (`feeRecipient`, `0x3c8A4d94B3219F6633F2cC94094f4765b30c691C`), which buys back and burns $Pepes with them. This step is done by the team and is a trust assumption: burns are published on-chain (IMD in, $Pepes to `0x…dEaD`). An automatic on-chain buyback was built and audited three times (IMD Swarm ec4e3ea7, b803125e, 348884ab); every price guard that kept a predictable public buyer from being front-run opened new issues, so it was replaced by this.
- Everything else is as in v3: 4% hook fee (1% protocol, 3% holders), liquidity locked forever, flash-borrow guard on distributions, renounced tokens with permit. Start market cap 635 IMD.
- IMD Swarm: [audit](https://explorer.imd.fun/jobs/ec4e3ea7-9b37-4113-ae4d-8cdd5ea19424), [re-check](https://explorer.imd.fun/jobs/b803125e-4ee8-464e-9328-ef7c6e1b9a9d), [final check](https://explorer.imd.fun/jobs/348884ab-fe4b-46f9-871d-d613c6b27c06), [final check 2](https://explorer.imd.fun/jobs/cbe092d6-65c8-4742-ada8-22bc471cbe91) (2 low, 3 info: strict claim, documentation, tests).
- Tests: `test/PepesFamily.t.sol` (expiry, activity and fuzz tests, including a ground-truth fuzz over random action sequences and every expiry case from the audits), and on a fork `FORK_RPC=https://robinhood.drpc.org forge test --mc "ForkTest|EthRouterForkTest"`.

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

Vault: [`0xE38cE23F33D5901402352392b49fb6e658801b51`](https://robinhoodchain.blockscout.com/address/0xE38cE23F33D5901402352392b49fb6e658801b51) (source-verified, deployed from commit `e626c32`, recorded in `contracts/deployments/robinhood-world.json`).

Who can play: a wallet holding at least 1 `$EARN` (one NFT), or one with a Pepes World pass from `src/world/PepesWorldVault.sol`. A pass is a one-time, non-refundable deposit of `passPrice` `$Pepes` (100,000 at launch) and never expires. The deposits belong to the team: the owner can withdraw them, claim the IMD rewards they earn as `$Pepes` holdings, grant free passes, and change the price of future passes (existing passes are never revoked). Players pass the price they agreed to (`enter(maxPrice)`), so a price change can never charge them more; withdrawing `$Pepes` claims the IMD they earned first. IMD Swarm [audit](https://explorer.imd.fun/jobs/4e9b1481-d807-4a37-ab7e-f5b3d3a7e066) (3 low, 2 info): all fixed, with tests against the real `$Pepes` token code. The game checks access in the browser only: it holds no prizes, so a bypass gains nothing. Tests: `test/PepesWorld.t.sol`, and on a fork `FORK_RPC=https://robinhood.drpc.org forge test --mc PepesWorldForkTest`.

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
forge test                                           # 116 unit, attack and fuzz tests against a real v4 PoolManager
FORK_RPC=https://robinhood.drpc.org forge test       # + fork tests against live mainnet state
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

`script/Deploy.s.sol` deploys the current version (v4). The owner defaults to `0x3c8A…691C`, and any wallet can pay for the deployment (about 0.0003 ETH). The script mines the hook salt, deploys through the standard CREATE2 factory, and writes `deployments/robinhood-v4.json` (`robinhood.json` records v1).

```bash
cd contracts
forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --interactive
```

Optional environment variables:
- `IMD_START_MCAP` (wei, default `635e18`)
- `OWNER`
- `SALT_START` (where salt mining starts)

Verify on Blockscout:

```bash
forge verify-contract <PAD> src/PepesFamily.sol:PepesFamily --chain-id 4663 --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api --guess-constructor-args
```

## Token source verification

Every launch deploys a new `PadToken` contract, and scanners such as DexScreener and GMGN flag unverified contracts as "not open source". The GitHub Action `.github/workflows/verify-tokens.yml` runs every 15 minutes (or on demand from the Actions tab). It calls `contracts/script/verify-tokens.sh`, which publishes the source of each new token to Sourcify and Blockscout. It needs no keys or secrets. Scanners usually refresh their security checks within a few hours.

## Website

Add each launchpad version's `pad`, `router` and `ethRouter` (from `contracts/deployments/robinhood*.json`) to `CONFIG.pads` at the top of `web/index.html`, then host the file on any static host. For production, point `CONFIG.rpc` at a paid RPC; the public endpoint is rate-limited.

Image upload on the launch form uses the Vercel function `web/api/upload.js`, which pins images to IPFS through Pinata. Set the environment variable `PINATA_JWT` (a Pinata API key JWT with permission to upload files) in the Vercel project; the key never reaches the browser. Without it the Upload button stays hidden and creators paste image links instead.

## Owner powers

- `setFeeRecipient`: changes where the 1% protocol fee goes (on v4 also where expired holder rewards go).
- `setStartTick`: sets the starting market cap for future launches.
- `transferOwnership` + `acceptOwnership`: a two-step handover, so a typo can't lose the admin role.

The owner **can't** change the fee percentages, touch pool liquidity or unexpired holder rewards, pause trading, upgrade the contracts, or add quote assets (v1–v3: ETH and IMD; v4: IMD only). No contract is upgradeable.

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
