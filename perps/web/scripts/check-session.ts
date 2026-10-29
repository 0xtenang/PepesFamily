// Proves the app's one-click signing matches LevRouter, using the same src/lib/session.ts code with Node's WebCrypto.
// Anvil account #4 approves a fresh P-256 key (one real transaction on the local chain), then the key signs an Open
// intent: its digest must equal router.hashOpen, and router.open must accept the signature (simulated, nothing sent).
// Also checks the other three digests, simulates a withdraw and a revoke, and confirms tampered or high-s signatures
// are refused. Ends by revoking the key.
// npm run check:session   (local chain only)
import { createWalletClient, http, parseEther, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { deployment, isLocalChain } from '../src/config'
import { chain, publicClient, tradeRouter } from '../src/lib/chain'
import { explainError } from '../src/lib/errors'
import { readQuote } from '../src/lib/reads'
import {
  ACT_CLOSE_OWN,
  ACT_OPEN,
  ACT_WITHDRAW,
  createSessionKey,
  deadlineFrom,
  intentDigest,
  intentJson,
  readSessionState,
  signIntent,
  type Limits,
  type Signer,
  type SignedIntent,
} from '../src/lib/session'

if (!isLocalChain) throw new Error('check:session only runs on the local chain (31337): it uses anvil test accounts.')

// Anvil's public test keys, local chain only: #4 owns the session, #6 stands in for a relayer.
const OWNER_KEY = '0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a'
const SUBMITTER_KEY = '0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e'
const P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n

const owner = privateKeyToAccount(OWNER_KEY)
const submitter = privateKeyToAccount(SUBMITTER_KEY)
const wallet = createWalletClient({ account: owner, chain, transport: http(deployment.rpcUrl) })

let failures = 0
function check(ok: boolean, label: string, detail = '') {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? `: ${detail}` : ''}`)
  if (!ok) failures++
}

const routerFn = (name: string) => ({ ...tradeRouter, functionName: name })
const hashFn = { open: 'hashOpen', close: 'hashClose', withdraw: 'hashWithdraw', revoke: 'hashRevoke' } as const
const submitFn = { open: 'open', close: 'close', withdraw: 'withdraw', revoke: 'revokeBySig' } as const

async function onChainDigest(s: SignedIntent): Promise<Hex> {
  return publicClient.readContract({ ...routerFn(hashFn[s.kind]), args: [s.intent] }) as Promise<Hex>
}

/** Simulates submitting the signed intent as someone else; returns the result or the decoded error. */
async function simulate(s: SignedIntent, sig = s.signature): Promise<{ ok: true; result: unknown } | { ok: false; error: string }> {
  try {
    const { result } = await publicClient.simulateContract({
      account: submitter,
      ...routerFn(submitFn[s.kind]),
      args: [s.intent, sig.r, sig.s],
    })
    return { ok: true, result }
  } catch (e) {
    return { ok: false, error: explainError(e) }
  }
}

// 1. A fresh non-extractable key, approved from #4's wallet with a deposit.
const key = await createSessionKey()
check(key.privateKey.extractable === false, 'private key is non-extractable')
const block = await publicClient.getBlock()
const limits: Limits = {
  expiry: block.timestamp + 3600n,
  actions: ACT_OPEN | ACT_CLOSE_OWN | ACT_WITHDRAW,
  maxLeverage: 10,
  openSlipTicks: 3000, // wide, so the simulated open doesn't trip on the demo prices
  closeSlipTicks: 500,
  maxStakePerTrade: parseEther('0.1'),
  maxOpenStake: parseEther('1'),
  dailyBudget: parseEther('1'),
}
const { request } = await publicClient.simulateContract({
  account: owner,
  ...routerFn('authorize'),
  args: [key.qx, key.qy, limits],
  value: parseEther('0.5'),
})
const receipt = await publicClient.waitForTransactionReceipt({ hash: await wallet.writeContract(request) })
check(receipt.status === 'success', `authorize from ${owner.address}`, `block ${receipt.blockNumber}`)

const generation = (await publicClient.readContract({
  ...routerFn('generationOf'),
  args: [owner.address],
  blockNumber: receipt.blockNumber,
})) as number
const state = await readSessionState(owner.address, key.key)
check(state.live && state.session.generation === generation, 'session is live', `generation ${generation}`)
check(state.session.qx === key.qx && state.session.qy === key.qy, 'router stored the WebCrypto public key')

const signer: Signer = {
  owner: owner.address,
  chainId: deployment.chainId,
  router: tradeRouter.address,
  key: key.key,
  generation,
  privateKey: key.privateKey,
}

// 2. Open: digest, signature shape, and the router accepting it.
let marketId = -1
let entryTick = 0
for (const m of deployment.markets) {
  const q = await readQuote(m.id, true, 2, parseEther('0.01'))
  if (q.reason === 0) {
    marketId = m.id
    entryTick = q.entryTick
    break
  }
}
if (marketId < 0) throw new Error('No market takes a 0.01 ETH 2x long right now, so the open simulation cannot run.')

const open = await signIntent(signer, {
  kind: 'open',
  marketId,
  isLong: true,
  leverage: 2,
  stake: parseEther('0.01'),
  limitTick: entryTick + 500,
})
const openHash = await onChainDigest(open)
check(openHash === open.digest, 'Open digest equals router.hashOpen', open.digest)
check(BigInt(open.signature.s) <= P256_N / 2n, 'signature is low-s')
const latest = (await publicClient.getBlock()).timestamp
const localNow = BigInt(Math.floor(Date.now() / 1000))
const deadlineAhead = open.intent.deadline - latest
const drift = deadlineFrom(latest, localNow) - open.intent.deadline
check(
  deadlineAhead > 0n && deadlineAhead <= 110n && drift >= -5n && drift <= 5n,
  'deadline is 30 s from the later of chain time and this clock, at most 110 s past the latest block',
  `${deadlineAhead} s past the latest block, ${open.intent.deadline - localNow} s past this clock`,
)
// A quiet chain (no block for 45 s) must not hand out a deadline that is already behind the real time.
check(deadlineFrom(1000n, 1045n) === 1075n, 'quiet chain: the deadline counts from this clock', String(deadlineFrom(1000n, 1045n)))
check(deadlineFrom(1000n, 990n) === 1030n, 'clock behind the chain: the deadline counts from the chain', String(deadlineFrom(1000n, 990n)))
check(deadlineFrom(1000n, 1500n) === 1110n, 'clock far ahead: the deadline stays within 110 s of the latest block', String(deadlineFrom(1000n, 1500n)))
console.log('     relayer body:', JSON.stringify(intentJson(open)))
const opened = await simulate(open)
check(opened.ok, `router.open accepts the signature (market ${marketId})`, opened.ok ? `would open position #${opened.result}` : opened.error)

// 3. Refusals: a changed field, and the same signature with high s.
const tampered = { ...open, intent: { ...open.intent, stake: parseEther('0.02') } }
const bad = await simulate(tampered)
check(!bad.ok && /signature/i.test(bad.error), 'a changed stake is refused', bad.ok ? 'accepted!' : bad.error)
const highS = { r: open.signature.r, s: `0x${(P256_N - BigInt(open.signature.s)).toString(16).padStart(64, '0')}` as Hex }
const high = await simulate(open, highS)
check(!high.ok && /signature/i.test(high.error), 'the high-s twin is refused', high.ok ? 'accepted!' : high.error)

// 4. The other intents: digests match, and withdraw / revoke run in simulation.
const close = await signIntent(signer, { kind: 'close', positionId: 123n, limitTick: -191_234 })
check((await onChainDigest(close)) === close.digest, 'Close digest equals router.hashClose')
const withdraw = await signIntent(signer, { kind: 'withdraw', amount: parseEther('0.01') })
check((await onChainDigest(withdraw)) === withdraw.digest, 'Withdraw digest equals router.hashWithdraw')
const wd = await simulate(withdraw)
check(wd.ok, 'router.withdraw accepts the signature', wd.ok ? '' : wd.error)
const revoke = await signIntent(signer, { kind: 'revoke' })
check((await onChainDigest(revoke)) === revoke.digest, 'Revoke digest equals router.hashRevoke')
const rv = await simulate(revoke)
check(rv.ok, 'router.revokeBySig accepts the signature', rv.ok ? '' : rv.error)
check(
  intentDigest(signer.chainId, signer.router, 'open', open.intent) === open.digest,
  'digest is deterministic for the same intent',
)

// 5. Clean up: revoke the key from #4's wallet.
const { request: rq } = await publicClient.simulateContract({ account: owner, ...routerFn('revoke'), args: [key.key] })
await publicClient.waitForTransactionReceipt({ hash: await wallet.writeContract(rq) })
const after = await readSessionState(owner.address, key.key)
check(!after.live, 'key revoked at the end')

console.log(failures === 0 ? '\nAll session checks passed.' : `\n${failures} session check(s) failed.`)
process.exit(failures === 0 ? 0 : 1)
