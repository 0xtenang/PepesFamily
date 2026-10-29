// Proves the browser's one-click path works against the real relayer. The app's own src/lib/session.ts makes the key
// and signs, and src/lib/relayer.ts talks to the relayer over HTTP with the Origin a page on http://localhost:5180
// sends, under the same CORS checks a browser applies. Anvil account #4 approves a fresh P-256 key (its only wallet
// transaction here), then opens a 2x long and closes it through the relayer without paying gas, and logs out with
// a signed revoke.
//   cd ../relayer && node src/server.ts      (the relayer, on 8790)
//   npm run check:relay                      (local chain only)
import { createWalletClient, http, parseEther, parseEventLogs, zeroAddress, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { deployment, isLocalChain, relayerUrl } from '../src/config'
import { chain, exchange, lens, publicClient, routerAbi, tradeRouter } from '../src/lib/chain'
import { explainErrorName, isTemporary, retryingText } from '../src/lib/errors'
import { readAccount, readQuote } from '../src/lib/reads'
import { checkRelayer, getIntentStatus, postIntent, RelayerError, type IntentStatus } from '../src/lib/relayer'
import {
  ACT_CLOSE_OWN,
  ACT_OPEN,
  canCloseWith,
  checkOpen,
  createSessionKey,
  intentDigest,
  readSessionState,
  sessionStatus,
  signIntent,
  type IntentFields,
  type Limits,
  type SignedIntent,
  type StoredSession,
} from '../src/lib/session'
import type { PositionView } from '../src/lib/types'

if (!isLocalChain) throw new Error('check:relay only runs on the local chain (31337): it uses an anvil test account.')

// Anvil's public test key #4, local chain only.
const OWNER_KEY = '0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a'
const ORIGIN = 'http://localhost:5180' // the web dev server
const STAKE = parseEther('0.02')
const LEVERAGE = 2
const SLIPPAGE_TICKS = 100 // what TradePanel signs: about 1%, capped by the session's openSlipTicks
const INT24_MAX = 8_388_607

const owner = privateKeyToAccount(OWNER_KEY)
const wallet = createWalletClient({ account: owner, chain, transport: http(deployment.rpcUrl) })

let failures = 0
function check(ok: boolean, label: string, detail = '') {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? `: ${detail}` : ''}`)
  if (!ok) failures++
}

// ------------------------------------------- fetch as a page on :5180

// Node's fetch neither sends Origin nor enforces CORS, so do what the browser does for requests to the relayer:
// preflight anything that is not a simple request, send the page's Origin, and refuse a response that doesn't allow
// it (a browser throws a TypeError then).
const nodeFetch = globalThis.fetch
const relayerOrigin = new URL(relayerUrl).origin
const cors = { requests: 0, preflights: 0 }

function corsFailure(what: string): never {
  throw new TypeError(`Failed to fetch: CORS ${what}`)
}

globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
  const url = new URL(input instanceof Request ? input.url : String(input))
  if (url.origin !== relayerOrigin) return nodeFetch(input, init)
  const method = (init?.method ?? 'GET').toUpperCase()
  const headers = new Headers(init?.headers)
  const contentType = headers.get('content-type')
  const simple = method === 'GET' || ((method === 'POST' || method === 'HEAD') && (!contentType || /^text\/plain/.test(contentType)))
  if (!simple) {
    const pre = await nodeFetch(url, {
      method: 'OPTIONS',
      headers: {
        origin: ORIGIN,
        'access-control-request-method': method,
        'access-control-request-headers': [...headers.keys()].join(','),
      },
      signal: init?.signal,
    })
    if (!pre.ok) corsFailure(`preflight got ${pre.status}`)
    if (pre.headers.get('access-control-allow-origin') !== ORIGIN) corsFailure('preflight does not allow this origin')
    const allowed = (pre.headers.get('access-control-allow-headers') ?? '').toLowerCase().split(/\s*,\s*/)
    for (const h of headers.keys()) if (!allowed.includes(h.toLowerCase())) corsFailure(`preflight does not allow header ${h}`)
    const methods = (pre.headers.get('access-control-allow-methods') ?? '').toUpperCase().split(/\s*,\s*/)
    if (method !== 'POST' && !methods.includes(method)) corsFailure(`preflight does not allow ${method}`)
    cors.preflights++
  }
  headers.set('origin', ORIGIN)
  const res = await nodeFetch(url, { ...init, headers })
  if (res.headers.get('access-control-allow-origin') !== ORIGIN) corsFailure(`response (${res.status}) does not allow this origin`)
  cors.requests++
  return res
}) as typeof fetch

// --------------------------------------------------------- helpers

const routerRead = <T>(functionName: string, args: readonly unknown[]) =>
  publicClient.readContract({ ...tradeRouter, functionName, args }) as Promise<T>
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

/** Posts once and follows the order to its end, like useOneClick's deliver(). Returns the final status and every
 *  progress text the app would have shown. */
async function relay(signed: SignedIntent): Promise<{ st: IntentStatus | null; shown: string[]; error?: string }> {
  const shown: string[] = []
  try {
    await postIntent(signed)
  } catch (e) {
    return { st: null, shown, error: e instanceof RelayerError ? `${e.code ?? ''} ${e.message}`.trim() : String(e) }
  }
  const until = Date.now() + 90_000
  for (;;) {
    await sleep(1000)
    const st = await getIntentStatus(signed.intent.owner, signed.intent.nonce)
    if (st && st.status !== 'pending' && st.status !== 'sent') return { st, shown }
    const text = st?.status === 'sent' ? 'Sent, waiting for the block…' : isTemporary(st?.error) ? retryingText(st?.error) : 'Waiting for the relayer…'
    if (shown[shown.length - 1] !== text) shown.push(text)
    if (Date.now() > until) return { st, shown, error: 'still not final after 90 s' }
  }
}

function describe(r: Awaited<ReturnType<typeof relay>>): string {
  if (!r.st) return r.error ?? 'no status'
  const t = r.st.sentAt && r.st.includedAt ? `, relay ${r.st.sentAt - r.st.receivedAt} ms, mined ${r.st.includedAt - r.st.sentAt} ms` : ''
  const err = r.st.error ? `, ${r.st.status === 'failed' ? explainErrorName(r.st.error) : `last error ${r.st.error}`}` : ''
  return `${r.st.status}${err}${t}${r.shown.length ? ` | shown: ${r.shown.join(' -> ')}` : ''}`
}

// ------------------------------------------------------------ run

let local: StoredSession | null = null
let positionId: bigint | null = null

async function run() {
  // 1. The relayer, as the app sees it. A foreign page's Origin is refused, which also shows ours really is sent.
  const foreign = await nodeFetch(`${relayerUrl}/health`, { headers: { origin: 'http://evil.example' } })
  check(foreign.status === 403 && !foreign.headers.get('access-control-allow-origin'), 'relayer refuses a foreign origin', `${foreign.status}`)
  const health = await checkRelayer()
  check(health.ok, `checkRelayer() from ${ORIGIN}`, health.ok ? `relayer ${health.relayer} at ${relayerUrl}` : health.reason)
  if (!health.ok) throw new Error(`relayer not usable: ${health.reason} Start it with: cd ../relayer && node src/server.ts`)

  // 2. One wallet transaction from #4: approve a fresh key made by the app's createSessionKey(), topping up if needed.
  const key = await createSessionKey()
  check(key.privateKey.extractable === false, 'session key is non-extractable', `key ${key.key.slice(0, 18)}…`)
  const block = await publicClient.getBlock()
  const limits: Limits = {
    expiry: block.timestamp + 3600n,
    actions: ACT_OPEN | ACT_CLOSE_OWN,
    maxLeverage: 10,
    openSlipTicks: 300,
    closeSlipTicks: 600,
    maxStakePerTrade: parseEther('0.1'),
    maxOpenStake: parseEther('1'),
    dailyBudget: parseEther('0.5'),
  }
  const balance0 = (await publicClient.readContract({ ...exchange, functionName: 'balanceOf', args: [owner.address] })) as bigint
  const deposit = balance0 < parseEther('0.1') ? parseEther('0.1') : 0n
  const txCount0 = await publicClient.getTransactionCount({ address: owner.address })
  const { request } = await publicClient.simulateContract({
    account: owner,
    ...tradeRouter,
    functionName: 'authorize',
    args: [key.qx, key.qy, limits],
    value: deposit,
  })
  const receipt = await publicClient.waitForTransactionReceipt({ hash: await wallet.writeContract(request) })
  // The generation comes from SessionAuthorized, as useOneClick().authorize reads it.
  const ev = parseEventLogs({ abi: routerAbi, eventName: 'SessionAuthorized', logs: receipt.logs })
    .map((l) => l.args as unknown as { key: Hex; generation: number })
    .find((a) => a.key.toLowerCase() === key.key.toLowerCase())
  check(receipt.status === 'success' && !!ev, `authorize from ${owner.address}`, `generation ${ev?.generation}, deposit ${deposit} wei`)
  if (!ev) throw new Error('no SessionAuthorized event')
  local = {
    owner: owner.address,
    chainId: deployment.chainId,
    router: tradeRouter.address,
    key: key.key,
    qx: key.qx,
    qy: key.qy,
    generation: Number(ev.generation),
    limits,
    privateKey: key.privateKey,
    authorizedBlock: receipt.blockNumber,
    createdAt: Date.now(),
  }
  let state = await readSessionState(owner.address, key.key)
  const now = () => Math.floor(Date.now() / 1000)
  check(sessionStatus(local, state, Number(state.now)).kind === 'live', 'the app sees the session as live')

  // 3. Open a 2x long through the relayer, the way TradePanel builds it.
  let marketId = -1
  let entryTick = 0
  let fee = 0n
  for (const m of deployment.markets) {
    const q = await readQuote(m.id, true, LEVERAGE, STAKE)
    if (q.reason === 0) {
      ;({ entryTick, fee } = q)
      marketId = m.id
      break
    }
  }
  if (marketId < 0) throw new Error('No market takes a 0.02 ETH 2x long right now.')
  const symbol = deployment.markets.find((m) => m.id === marketId)?.symbol
  const balance1 = (await publicClient.readContract({ ...exchange, functionName: 'balanceOf', args: [owner.address] })) as bigint
  const block1 = checkOpen(state, { stake: STAKE, leverage: LEVERAGE, cost: STAKE + fee, balance: balance1 }, now())
  check(block1 === null, 'client-side limit check lets the open through', block1 ?? '')
  const fields: IntentFields = {
    kind: 'open',
    marketId,
    isLong: true,
    leverage: LEVERAGE,
    stake: STAKE,
    limitTick: Math.min(INT24_MAX, entryTick + Math.min(SLIPPAGE_TICKS, limits.openSlipTicks)),
  }
  const open = await signIntent(local, fields)
  const onChain = await routerRead<Hex>('hashOpen', [open.intent])
  check(onChain === open.digest && open.digest === intentDigest(local.chainId, local.router, 'open', open.intent), 'Open digest equals router.hashOpen')
  const opened = await relay(open)
  check(opened.st?.status === 'confirmed' && !!opened.st.positionId, `open 2x long ${symbol} through the relayer`, describe(opened))
  if (opened.st?.status !== 'confirmed' || !opened.st.positionId) throw new Error('open did not confirm')
  positionId = BigInt(opened.st.positionId)

  // The app's own reads now show the position, opened by this key, so Positions offers a one-click close.
  const account = await readAccount(owner.address)
  const row = account.positions.find((p) => p.id === positionId)
  state = await readSessionState(owner.address, key.key)
  check(
    !!row && row.openedBy.toLowerCase() === key.key.toLowerCase() && row.position.stake === STAKE && row.position.isLong,
    `position #${positionId} shows in readAccount(), opened by this key`,
  )
  check(!!row && canCloseWith(local, state, row.openedBy), 'canCloseWith() allows a one-click close')
  check(state.session.spentToday === STAKE + fee, 'the session counted the stake and the open fee', `spentToday ${state.session.spentToday}`)

  // 4. Close it the same way, straight away: the relayer retries TooSoon until the 10 s minimum hold has passed.
  // No price limit here (the lowest exit a long can name): this checks the relay path, not the market.
  const close = await signIntent(local, { kind: 'close', positionId, limitTick: -8_388_608 })
  check((await routerRead<Hex>('hashClose', [close.intent])) === close.digest, 'Close digest equals router.hashClose')
  const closed = await relay(close)
  const after = (await publicClient.readContract({ ...lens, functionName: 'getPosition', args: [positionId] })) as PositionView
  check(closed.st?.status === 'confirmed' && after.position.owner === zeroAddress, `close #${positionId} through the relayer`, describe(closed))
  if (closed.st?.status === 'confirmed') positionId = null

  // 5. Log out: the key revokes itself through the relayer.
  const revoke = await signIntent(local, { kind: 'revoke' })
  const revoked = await relay(revoke)
  state = await readSessionState(owner.address, key.key)
  check(revoked.st?.status === 'confirmed' && !state.live, 'log out (revokeBySig) through the relayer', describe(revoked))
  if (!state.live) local = null

  // 6. Gasless: #4 sent only the authorize.
  const txCount1 = await publicClient.getTransactionCount({ address: owner.address })
  check(txCount1 - txCount0 === 1, 'the owner wallet sent only the authorize', `${txCount1 - txCount0} tx`)
  check(cors.requests > 0 && cors.preflights > 0, 'every relayer call passed the browser CORS checks', `${cors.requests} requests, ${cors.preflights} preflights`)
}

/** Leave nothing behind if a step failed: close the position and revoke the key from #4's wallet. */
async function cleanUp() {
  if (positionId !== null) {
    const p = (await publicClient.readContract({ ...lens, functionName: 'getPosition', args: [positionId] })) as PositionView
    if (p.position.owner !== zeroAddress) {
      const { request } = await publicClient.simulateContract({ account: owner, ...exchange, functionName: 'close', args: [positionId, -8_388_608] })
      await publicClient.waitForTransactionReceipt({ hash: await wallet.writeContract(request) })
      console.log(`     cleanup: closed position #${positionId} from the wallet`)
    }
  }
  if (local) {
    const [, live] = await routerRead<readonly [unknown, boolean]>('sessionOf', [owner.address as Address, local.key])
    if (live) {
      const { request } = await publicClient.simulateContract({ account: owner, ...tradeRouter, functionName: 'revoke', args: [local.key] })
      await publicClient.waitForTransactionReceipt({ hash: await wallet.writeContract(request) })
      console.log('     cleanup: revoked the key from the wallet')
    }
  }
}

try {
  await run()
} catch (e) {
  check(false, 'ran to the end', e instanceof Error ? e.message : String(e))
} finally {
  await cleanUp().catch((e) => check(false, 'cleanup', e instanceof Error ? e.message : String(e)))
}

console.log(failures === 0 ? '\nAll relay checks passed.' : `\n${failures} relay check(s) failed.`)
process.exit(failures === 0 ? 0 : 1)
