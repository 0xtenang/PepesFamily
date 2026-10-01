# Audit brief

This brief explains what the PepesFamily contracts do, what they must guarantee, and where we would like reviewers to look hardest. Everything referenced is in this repository.

## 1. What the system is

PepesFamily is a fixed-supply token launchpad on **Robinhood Chain** (chain ID 4663, an Arbitrum Orbit L2), built on **Uniswap v4**.

- Anyone can launch an ERC-20 with a supply of exactly 1,000,000,000 tokens, paired with either **ETH** or **IMD** (`0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`, a LayerZero OFT).
- At launch the entire supply becomes **single-sided liquidity in a new Uniswap v4 pool**. The pool is created and owned by the launchpad contract, which has **no way to remove it**, so liquidity is locked forever. The token trades from the first block, behaving like `x·y=k` with virtual quote liquidity.
- The launchpad is also the pool's **v4 hook**. It charges **4% of the quote side of every swap**, through any router:
  - **1%** goes to the protocol (`feeRecipient`).
  - **3%** goes to the token's holders, pro rata to their balances, paid in the quote asset and claimed by holders.
- There is **no LP fee** (pool fee = 0), **no mint**, **no admin on tokens**, and **no upgradeability**.

## 2. Scope

### In scope: v2 (live, receives all new launches)

| File | Lines | Deployed at |
| --- | --- | --- |
| `contracts/src/PepesFamily.sol`: launcher, v4 hook, fee vault, LP position owner | 582 | `0x072Fb5A1B65F30d59BcD11BEeD99803675bCE8CC` |
| `contracts/src/PadToken.sol`: launched ERC-20 with pro-rata holder rewards and EIP-2612 permit | 242 | one instance per launch |
| `contracts/src/PepesFamilyRouter.sol`: buy, sell (with permit), launch with initial buy; includes `PermitHelper` | 187 | `0x85D6695CBE0BaF221a4BBd39F0b368B893e70D4b` |
| `contracts/src/PepesFamilyEthRouter.sol`: trades IMD-paired tokens with ETH via the v4 IMD/ETH pool | 181 | `0xce3540Bf1D4b219B7B2055508A83B09A0e1df9eF` |
| `contracts/src/lib/SafeTransfer.sol`: ETH/ERC-20 transfer helpers | 33 | (library) |
| `contracts/script/DeployLib.sol` and `Deploy.s.sol`: start-tick math, hook-address salt mining, deployment parameters | 116 | |

Both routers are created by the `PepesFamily` constructor. The deployment is a single CREATE2 transaction through `0x4e59b44847b379578588920ca78fbf26c0b4956c`, deployed at block 76968615.

### Also live: v1 (holds real value, review requested where it differs)

v1 is still live and its tokens keep trading. The token source is `contracts/src/v1/PadTokenV1.sol` (bytecode-identical to the deployed v1 tokens). The v1 launchpad and routers are at git commit **`a549093`** under the same file names in `contracts/src/`.

| Contract | Address |
| --- | --- |
| PepesFamily v1 | `0x2d7689E48Fd71D9A0f225C673D7b8F8A693368CC` |
| PepesFamilyRouter v1 | `0xA73604EA3C393B47573986ff9Ce5A9EAb61883dC` |
| PepesFamilyEthRouter v1 | `0x79eeE0C12C1284bc046e4494Eea6180695F5028A` |

**v1 → v2 differences:**
- v1 `PadToken.transferFrom` skips the allowance check when the caller is the v1 router. The router only pulls from its own `msg.sender`.
- v1 tokens have no `owner()` and no `permit`.
- v1 routers have no `*WithPermit` functions.
- The v1 ETH router was deployed separately; in v2 the launchpad deploys it.

The hook and fee logic are otherwise the same. Small hardening that landed before the v1 deployment (SafeCast in the hook, non-reverting `distribute`, two-step ownership) is in both.

### Out of scope

- Uniswap v4-core (git submodule, pinned to `46c6834`)
- forge-std
- The website (`web/`). A light review of how it builds transactions and signs permits would be welcome but is optional; see §7.

### Build

- Solidity `0.8.26`, `via_ir = true`, optimizer 200 runs
- EVM `cancun` (the hook uses transient storage)
- `bytecode_hash = "none"`
- Dependencies are git submodules: `git clone --recursive`, then `cd contracts && forge build`
- Sources are verified on Sourcify for every deployed contract and on Blockscout for the v1 launchpad and the Pepes token

## 3. Roles and trust

| Role | Can do | Cannot do |
| --- | --- | --- |
| `owner` of PepesFamily (v1 and v2: `0x3c8A…691C`) | `setFeeRecipient`; `setStartTick(quote, tick)` (starting price for **future** launches, bounded and spacing-aligned); two-step `transferOwnership` / `acceptOwnership` | Change fee rates; touch pools, liquidity, holder rewards or tokens; pause; upgrade; add quote assets |
| `feeRecipient` | Receives protocol fees | Anything else |
| Anyone | `launch`; `flush(token)`; `collectProtocolFees(quote)` (always pays `feeRecipient`); `PadToken.distribute()`; trade through any v4 router | |
| Uniswap v4 PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951` | Calls hook callbacks and `unlockCallback` | |

**External dependencies we trust:**
- The canonical v4 PoolManager on Robinhood Chain.
- IMD behaving as a plain ERC-20, with no fee-on-transfer and no rebasing. Its owner controls LayerZero peers, which affects IMD's supply but not our accounting.
- The no-hook IMD/ETH v4 pool (fee 10000, tick spacing 100), used by the ETH router.

## 4. How it works

**Launch** (`PepesFamily._launch`):
1. Deploys a `PadToken`, which mints 1B to the launchpad.
2. Builds the pool key: `{quote, token}` sorted, `fee = 0`, `tickSpacing = 200`, `hooks = this`.
3. Initializes the pool at the configured start tick. The tick's sign flips by currency order.
4. In `unlockCallback`, adds single-sided token liquidity over `[minUsableTick, start]` (token is currency1) or `[start, maxUsableTick]` (token is currency0), settles the tokens, and burns the rounding leftover (`LIQUIDITY_BUFFER = 1e9` wei plus dust) to `0x…dEaD`.

The position is owned by the launchpad (salt 0). There is no remove path.

**Hook permissions** (address low 14 bits = `0x28CC`, mined via CREATE2):
- `beforeInitialize` and `beforeAddLiquidity` always revert. The launchpad's own calls skip hooks, because v4 skips hooks when the caller is the hook.
- `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta` and `afterSwapReturnDelta` charge the fee.

**Fee** (`beforeSwap` / `afterSwap` / `_chargeFee`):
- If the quote is the specified currency, `beforeSwap` takes it:
  - exact-in: `fee = amount·400/10000`
  - exact-out: `fee = amount·400/9600`, so the fee is 4% of gross

  The fee is returned as `+fee` on the specified delta and passed to `afterSwap` through transient slot `FEE_SLOT`.
- Otherwise `afterSwap` takes it from the unspecified (quote) side:
  - exact-in sell: 4% of the output
  - exact-out buy: `·400/9600` of the input
- `_chargeFee` splits the fee 1/4 protocol and 3/4 holders, records it in `pendingProtocolFees[quote]` and `pendingHolderFees[token]`, and **mints the same amount of ERC-6909 claims** to the launchpad. That mint settles the hook's credit inside the swap.

**Fee payout:**
- `flush(token)` burns the holder share of the claims and `take`s the real currency to the token contract, then calls `PadToken.distribute()`. It works inside someone else's unlock (if `isUnlocked()`) or opens its own.
- Both routers call it mid-trade: after a buyer's input is settled and before the buyer's tokens are taken; after a seller's tokens are settled. As a result, a trader never earns from their own trade on these routers.
- `PadToken.claim()` also calls `flush` first.
- `collectProtocolFees(quote)` does the same for the protocol share and pays `feeRecipient`.

**Holder rewards** (`PadToken`):
- Uses the "magnified dividend per share" pattern (`MAGNITUDE = 2^128`) with per-account `int256` corrections on every transfer.
- Excluded accounts: PoolManager, launchpad, router, the token itself, `0x0`, `0x…dEaD`. `eligibleSupply` tracks the non-excluded balance.
- `distribute()` spreads `balance − accountedBalance`. It is a no-op while `eligibleSupply < 1e18` (funds wait), and it never reverts.

**Routers:**
- `PepesFamilyRouter`: exact-in buy/sell/launch-with-buy in a single `unlock`. It settles ETH from `msg.value` or pulls IMD/tokens from `msg.sender`, and has slippage and deadline checks.
- `PepesFamilyEthRouter`: two swaps in one `unlock` (ETH→IMD→token or token→IMD→ETH). The IMD legs net out inside the PoolManager, and any remainder is returned to the user.
- `PermitHelper` applies an EIP-2612 permit and tolerates it being front-run, as long as the allowance is already in place.

## 5. Invariants the code must hold

1. **Locked liquidity.** No call sequence by anyone, including the owner, reduces the launchpad's liquidity in any launched pool. No third party can initialize a pool with this hook or add liquidity to one.
2. **Fee correctness.** For every swap on a launched pool, through any router, in any of the four modes (exact-in/out × buy/sell), the hook takes exactly 4% of the trader's gross quote amount (±1 wei rounding), split 1% / 3%.
3. **Claim solvency.** For each currency, the launchpad's ERC-6909 claim balance equals the sum of `pendingHolderFees[t]` over tokens with that quote, plus `pendingProtocolFees[quote]`.
4. **Reward solvency.** For each token, `accountedBalance ≤ quote.balanceOf(token)`. The sum of all holders' `withdrawableDividendOf` is at most `accountedBalance`. Claims can never pay out more than was distributed.
5. **Supply.** `totalSupply` is constant at 1e27. The sum of balances equals 1e27. `eligibleSupply` equals the sum of non-excluded balances.
6. **Transfers move only future rewards.** Moving tokens never changes either party's already-accrued rewards.
7. **Routers are stateless and only spend `msg.sender`'s assets.** They hold no funds between transactions and cannot be made to pull another account's tokens or IMD.
8. **Access control.**
   - Hook callbacks and every `unlockCallback` revert unless the caller is the PoolManager.
   - `launchFor` reverts unless the caller is the router.
   - Owner functions revert unless the caller is the owner.
9. **Liveness.** No action by the owner or any third party can stop holders from selling or claiming. This includes a griefed permit, an odd quote balance in a token, and a `flush` called mid-unlock.

## 6. Where to look hardest

**1. Hook delta accounting** (`beforeSwap`, `afterSwap`, `_chargeFee`)
- Sign conventions for specified vs unspecified currency across both currency orderings.
- The `·400/9600` exact-out formulas.
- `toInt128` casts.
- The `FEE_SLOT` transient handoff:
  - several swaps in one transaction or one `unlock`
  - a swap whose `beforeSwap` writes the slot when the matching `afterSwap` might not run
  - interaction with other hooks or routers
- **Partial fills.** When a swap stops at `sqrtPriceLimitX96`, the fee is computed on the requested amount, not the executed one. Is the trader ever charged more than 4% of what actually traded? Can a caller's delta flip sign? We believe the effect is limited to the trader's own swap, but we would like confirmation.

**2. ERC-6909 claims and `flush`/`collect` inside a foreign unlock**
- Anyone can trigger `flush`, `collectProtocolFees` or `PadToken.claim` while the PoolManager is unlocked by an arbitrary contract.
- `burn` + `take` there moves real currency out of the PoolManager. Check the interaction with that locker's pending `sync`/`settle` (synced reserves) and with deltas.
- Can this ever be used to drain the PoolManager, or to make the launchpad's own accounting wrong?

**3. Launch liquidity math** (`_addLaunchLiquidity`, `DeployLib.startTickForMarketCap`)
- Liquidity from amount for both orientations, and rounding: `owed ≤ TOTAL_SUPPLY − LIQUIDITY_BUFFER`.
- `maxLiquidityPerTick`.
- The bounds of `setStartTick`, and whether an extreme tick can brick launches or misprice them.
- The behaviour of the curve at its ends (min/max usable ticks).

**4. Reward accounting** (`PadToken`)
- `int256` correction overflow bounds, rounding dust, and the `MIN_ELIGIBLE_SUPPLY` gate.
- The exclusion list. The v2 ETH router is *not* excluded and should never hold tokens; third-party routers that transiently hold tokens could earn rewards in between.
- Self-transfers and transfers to excluded addresses.
- `claim()` reentrancy (ETH is sent to arbitrary receivers).
- The `distribute` early return when the balance drops below `accountedBalance`.

**5. Permit (v2 token and routers)**
- EIP-712 domain correctness: the name used, chain-id fork handling.
- Nonce handling, signature malleability, expiry.
- `PermitHelper`'s `try/catch`: can it accept a sale without a valid authorization from `msg.sender`?

**6. v1 router allowance exemption** (`PadTokenV1.transferFrom`, v1 `PepesFamilyRouter`)
- Please confirm that no path lets the v1 router move tokens from anyone but its own `msg.sender`, including through `launch`, `unlockCallback` or crafted pool keys.
- GoPlus currently flags v1 tokens `is_honeypot=1` / `owner_change_balance=1` because of this pattern. We believe it is a false positive and would value an independent opinion.

**7. Routers**
- `msg.value` handling and refunds, especially the ETH router's leftover-ETH refund using `address(this).balance`, and force-sent ETH.
- Settle amounts vs deltas, minimum-output checks, and leftover-IMD handling in the two-hop route.
- Behaviour if the IMD/ETH pool moves between quote and execution.

**8. Chain specifics**
- Robinhood Chain is Arbitrum Orbit. `createdBlock` comes from ArbSys (`arbBlockNumber()` at `0x64`) with a fallback to `block.number`.
- Transient storage availability.
- Reliance on `block.timestamp` for deadlines.

## 7. Website (optional, light)

`web/index.html` is a single static page (ethers v6, pinned with SRI, behind a Content-Security-Policy). Areas worth a look:
- Rendering of creator-supplied on-chain metadata (names, descriptions, image and link URLs) with respect to XSS.
- Construction of EIP-712 permit requests.
- Default slippage of 5% and deadlines.
- The rule that the ETH-route and launch options are only offered once the target contract has code on-chain.

## 8. Known and accepted behaviour (not bugs, unless you see an impact we missed)

- **Fee timing on other routers.** For trades through routers other than ours, holder fees sit pending until the next `flush`. Whoever holds at that moment is credited, which can include the trader.
- **Dividend sniping.** Buying just before a large trade to capture part of its 3% is possible. It costs 4% in and 4% out.
- **Launch-block sniping.** Possible. Creators can buy atomically in the launch transaction.
- **Unclaimed early fees.** Holder fees from before any holder has at least 1 token wait in the token contract and go to the holders present at the next distribution.
- **Lost transfers.** Tokens sent directly to the launchpad or the PoolManager are lost; they are excluded from rewards.
- **Locked donations.** Donations to a pool go to the locked position and cannot be recovered.

## 9. Tests

```bash
cd contracts
forge test                                       # 31 unit + attack tests against a real v4 PoolManager
FORK_RPC=https://robinhood.drpc.org forge test   # + 7 fork tests on live Robinhood Chain state
```

The tests cover:
- all four swap modes through a third-party router, for both currency orders
- pro-rata payouts, and transfers moving only future rewards
- full exits
- the hook blocking outside pool creation and liquidity
- access control on hooks and callbacks
- oversized swaps reverting
- `distribute` never blocking trading
- fee theft attempts
- two-step ownership
- permit: valid use, wrong signer, replay, expiry, and front-run tolerance
- a fuzzed solvency check
- fork tests using the real PoolManager, IMD, the IMD/ETH pool and Uniswap's deployed V4Quoter

The tests do not include formal invariant/stateful fuzzing of §5. We would welcome suggestions or additions there.

## 10. Contact

Repository owner: `0xtenang` on GitHub. Owner and fee wallet: `0x3c8A4d94B3219F6633F2cC94094f4765b30c691C`.
