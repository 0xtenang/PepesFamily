# Audit brief: Pepes token (PepesFamily v1)

This branch is the PepesFamily **v1** code exactly as deployed on Robinhood Chain (chain ID 4663). It is frozen at commit `a549093` plus this file. The `main` branch has since moved to v2. Please audit v1 as it is here.

## The token in question

**Pepes** `0xE2C46c7068566740A33A4C93f5445B07BCfE5644` is an instance of `contracts/src/PadToken.sol`, deployed by the v1 launchpad. Its source is verified on Blockscout (exact match) and on Sourcify.

GoPlus currently reports `is_honeypot = 1` and `owner_change_balance = 1` for it. Everything else is clean: not mintable, no owner, no blacklist, not pausable, not a proxy, no self-destruct, no hidden owner. **We want an independent answer: can anyone block holders from selling, change balances, mint, or take holders' tokens or rewards?**

| Contract | Address | Source |
| --- | --- | --- |
| Pepes token (PadToken v1) | `0xE2C46c7068566740A33A4C93f5445B07BCfE5644` | `contracts/src/PadToken.sol` |
| PepesFamily v1 (launcher, Uniswap v4 hook, fee vault) | `0x2d7689E48Fd71D9A0f225C673D7b8F8A693368CC` | `contracts/src/PepesFamily.sol` |
| PepesFamilyRouter v1 | `0xA73604EA3C393B47573986ff9Ce5A9EAb61883dC` | `contracts/src/PepesFamilyRouter.sol` |
| PepesFamilyEthRouter v1 | `0x79eeE0C12C1284bc046e4494Eea6180695F5028A` | `contracts/src/PepesFamilyEthRouter.sol` |
| Uniswap v4 PoolManager (out of scope) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | submodule `contracts/lib/v4-core` |
| IMD (the pair asset; out of scope) | `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` | LayerZero OFT |

## What the contracts are for

PepesFamily is a fixed-supply token launchpad built on Uniswap v4.

- Launching deploys a `PadToken` with exactly 1,000,000,000 supply. The whole supply becomes single-sided liquidity in a new v4 pool, paired with ETH or IMD (Pepes is paired with IMD).
- The launchpad owns that liquidity and has no function to remove it.
- The launchpad is also the pool's hook. It takes 4% of the quote side of every swap: 1% for the protocol and 3% for the token's holders, pro rata, claimed with `PadToken.claim()`.
- The token has no mint, no owner and no admin functions.
- The launchpad owner can only call `setFeeRecipient`, `setStartTick` (future launches only), and two-step `transferOwnership` / `acceptOwnership`.

## Look at hardest

**1. The flagged pattern: `PadToken.transferFrom` skips the allowance check when `msg.sender == router`** (the immutable v1 `PepesFamilyRouter`).
- We believe the router can only ever pull tokens from its own caller: `sell` → `_swap` → `unlockCallback` uses `d.user = msg.sender`.
- Please check every path through the router: `buy`, `sell`, `launch`, `unlockCallback`, and crafted pool keys or tokens. Confirm no one, including the owner, can move another holder's Pepes.
- The router has no owner and no admin functions.

**2. Can selling be blocked?**
- The hook's `beforeSwap` / `afterSwap` fee logic.
- Whether any owner action, third-party call or state (for example a reverting `flush`/`distribute`, pending fees, or a quote balance below `accountedBalance`) can make sells or claims revert.
- `beforeInitialize` and `beforeAddLiquidity` always revert, so no one else can create pools or add liquidity with this hook.

**3. Can balances or supply change any other way?**
- `totalSupply` is a constant (1e27). Balances only change in `_transfer`.
- Check the reward accounting (magnified dividend per share, `int256` corrections, the exclusion list) for anything that touches balances or pays out more than was distributed.

**4. The fee and claims flow**
- The hook mints ERC-6909 claims for fees during swaps.
- `flush` and `collectProtocolFees` (callable by anyone, including mid-unlock) burn claims and `take` real currency.
- Can this be abused against holders, the pool, or the PoolManager?

## Known behaviour (not bugs)

- The 4% fee is charged by the pool hook, not the token. Scanners therefore read the token as having 0% tax.
- Fees from trades through other routers reach holders at the next `flush`.
- A trader can capture part of the holder share by buying before a large trade (dividend sniping). It costs 4% in and 4% out.
- The `0x…dEaD` balance (1,000,000,303 wei) is launch-time rounding dust burned when liquidity was added. It is not an ownership transfer: the token has no owner.

## Build and tests

```bash
git clone --recursive -b audit-pepes-v1 https://github.com/0xtenang/PepesFamily.git
cd PepesFamily/contracts && forge test
```

Settings: Solidity 0.8.26, `via_ir`, optimizer 200, EVM cancun, `bytecode_hash = "none"`.
