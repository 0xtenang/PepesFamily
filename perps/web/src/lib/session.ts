// One-click trading: a P-256 session key made by WebCrypto in this browser, approved once by the wallet
// (LevRouter.authorize), then used to sign EIP-712 orders that the relayer submits. The private key is created
// non-extractable and only ever lives in IndexedDB as a CryptoKey; nothing here exports or logs it.
import {
  bytesToBigInt,
  encodeAbiParameters,
  getAddress,
  hashTypedData,
  hexToBytes,
  keccak256,
  numberToHex,
  toHex,
  type Address,
  type Hex,
} from 'viem'
import { exchange, publicClient, tradeRouter } from './chain'
import { fmtDuration, fmtEth } from './format'

export const ACT_OPEN = 1
export const ACT_CLOSE_OWN = 2 // close positions this key opened
export const ACT_CLOSE_ANY = 4 // close any of the owner's positions
export const ACT_WITHDRAW = 8 // withdraw to the owner's own address

export const MAX_SESSION_SECONDS = 7 * 24 * 3600
export const MAX_SLIP_TICKS = 3000
const DEADLINE_SECONDS = 30n
// The router (and the relayer's check) refuse a deadline more than 120 s past the block they run in. Stay under
// that against the latest block, which is the oldest block anyone will check it against.
const DEADLINE_MAX_AHEAD = 110n
const DAY = 86_400n
const P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n

// ------------------------------------------------------------------ types

/** LevRouter.Limits as viem returns it (uint64 and wider come back as bigint). */
export type Limits = {
  expiry: bigint
  actions: number
  maxLeverage: number
  openSlipTicks: number
  closeSlipTicks: number
  maxStakePerTrade: bigint
  maxOpenStake: bigint
  dailyBudget: bigint
}

export type ChainSession = {
  qx: Hex
  qy: Hex
  limits: Limits
  epoch: number
  generation: number
  dayStart: bigint
  spentToday: bigint
  active: boolean
}

/** Everything needed to sign for one approved key. */
export type Signer = {
  owner: Address
  chainId: number
  router: Address
  key: Hex
  generation: number
  privateKey: CryptoKey
}

/** What this browser keeps per chain, router and owner. */
export type StoredSession = Signer & {
  qx: Hex
  qy: Hex
  limits: Limits
  authorizedBlock: bigint // reads from before this block can't see the session yet
  createdAt: number
}

export type SessionKey = { privateKey: CryptoKey; qx: Hex; qy: Hex; key: Hex }

export type IntentKind = 'open' | 'close' | 'withdraw' | 'revoke'

type Base = { owner: Address; key: Hex; generation: number; nonce: bigint; deadline: bigint }
export type OpenIntent = Base & { marketId: number; isLong: boolean; leverage: number; stake: bigint; limitTick: number }
export type CloseIntent = Base & { positionId: bigint; limitTick: number }
export type WithdrawIntent = Base & { amount: bigint }
export type RevokeIntent = Base

export type IntentFields =
  | { kind: 'open'; marketId: number; isLong: boolean; leverage: number; stake: bigint; limitTick: number }
  | { kind: 'close'; positionId: bigint; limitTick: number }
  | { kind: 'withdraw'; amount: bigint }
  | { kind: 'revoke' }

export type Signature = { r: Hex; s: Hex }

export type SignedIntent = {
  kind: IntentKind
  intent: OpenIntent | CloseIntent | WithdrawIntent | RevokeIntent
  digest: Hex
  signature: Signature
}

// ------------------------------------------------------------- the key

export function keyIdOf(qx: Hex, qy: Hex): Hex {
  return keccak256(encodeAbiParameters([{ type: 'bytes32' }, { type: 'bytes32' }], [qx, qy]))
}

/** A fresh P-256 key. The private half can sign but can never be read out, not even by this app. */
export async function createSessionKey(): Promise<SessionKey> {
  // WebCrypto only exists on secure origins (https, or localhost while developing).
  if (typeof crypto === 'undefined' || !crypto.subtle) {
    throw new Error('This browser can only make a trading key on a secure page (https or localhost).')
  }
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify'])
  // Raw public key: 0x04 || x || y.
  const raw = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey))
  if (raw.length !== 65 || raw[0] !== 4) throw new Error('Unexpected public key format.')
  const qx = toHex(raw.slice(1, 33))
  const qy = toHex(raw.slice(33, 65))
  return { privateKey: pair.privateKey, qx, qy, key: keyIdOf(qx, qy) }
}

// ------------------------------------------------------------- signing

const TYPES = {
  Open: [
    { name: 'owner', type: 'address' },
    { name: 'key', type: 'bytes32' },
    { name: 'generation', type: 'uint32' },
    { name: 'marketId', type: 'uint32' },
    { name: 'isLong', type: 'bool' },
    { name: 'leverage', type: 'uint8' },
    { name: 'stake', type: 'uint96' },
    { name: 'limitTick', type: 'int24' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint64' },
  ],
  Close: [
    { name: 'owner', type: 'address' },
    { name: 'key', type: 'bytes32' },
    { name: 'generation', type: 'uint32' },
    { name: 'positionId', type: 'uint256' },
    { name: 'limitTick', type: 'int24' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint64' },
  ],
  Withdraw: [
    { name: 'owner', type: 'address' },
    { name: 'key', type: 'bytes32' },
    { name: 'generation', type: 'uint32' },
    { name: 'amount', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint64' },
  ],
  Revoke: [
    { name: 'owner', type: 'address' },
    { name: 'key', type: 'bytes32' },
    { name: 'generation', type: 'uint32' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint64' },
  ],
} as const

const PRIMARY = { open: 'Open', close: 'Close', withdraw: 'Withdraw', revoke: 'Revoke' } as const

/** The EIP-712 digest LevRouter computes in hashOpen / hashClose / hashWithdraw / hashRevoke. */
export function intentDigest(chainId: number, router: Address, kind: IntentKind, intent: SignedIntent['intent']): Hex {
  return hashTypedData({
    domain: { name: 'MemeLev', version: '1', chainId, verifyingContract: router },
    types: TYPES,
    primaryType: PRIMARY[kind],
    message: intent,
  } as Parameters<typeof hashTypedData>[0])
}

/** WebCrypto hashes the 32 digest bytes with SHA-256 and signs that, which is what the router verifies. */
export async function signDigest(privateKey: CryptoKey, digest: Hex): Promise<Signature> {
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, privateKey, hexToBytes(digest)))
  if (sig.length !== 64) throw new Error('Unexpected signature format.')
  const r = bytesToBigInt(sig.slice(0, 32))
  let s = bytesToBigInt(sig.slice(32, 64))
  // The router only takes low-s signatures.
  if (s > P256_N / 2n) s = P256_N - s
  return { r: numberToHex(r, { size: 32 }), s: numberToHex(s, { size: 32 }) }
}

export function randomNonce(): bigint {
  const b = new Uint8Array(32)
  crypto.getRandomValues(b)
  return bytesToBigInt(b)
}

/** 30 s from now. A quiet chain makes no blocks, so its latest block can be older than 30 s, and the block that
 *  includes the order is stamped with the real time. So count from whichever is later, the latest block or this
 *  device's clock, but never more than 110 s past the latest block (a fast device clock can't push it out of range). */
export function deadlineFrom(chainTime: bigint, localTime: bigint): bigint {
  const from = localTime > chainTime ? localTime : chainTime
  const deadline = from + DEADLINE_SECONDS
  const cap = chainTime + DEADLINE_MAX_AHEAD
  return deadline < cap ? deadline : cap
}

export async function chainDeadline(): Promise<bigint> {
  const block = await publicClient.getBlock()
  return deadlineFrom(block.timestamp, BigInt(Math.floor(Date.now() / 1000)))
}

export async function signIntent(signer: Signer, fields: IntentFields): Promise<SignedIntent> {
  const { kind, ...rest } = fields
  const intent = {
    owner: getAddress(signer.owner),
    key: signer.key,
    generation: signer.generation,
    ...rest,
    nonce: randomNonce(),
    deadline: await chainDeadline(),
  } as SignedIntent['intent']
  const digest = intentDigest(signer.chainId, signer.router, kind, intent)
  return { kind, intent, digest, signature: await signDigest(signer.privateKey, digest) }
}

/** The relayer's JSON shape: numbers as decimal strings, bools as booleans, hex as hex. */
export function intentJson(signed: SignedIntent) {
  const intent: Record<string, string | boolean> = {}
  for (const [k, v] of Object.entries(signed.intent)) {
    intent[k] = typeof v === 'boolean' || typeof v === 'string' ? v : String(v)
  }
  return { kind: signed.kind, intent, signature: signed.signature }
}

// ------------------------------------------------------------ storage

const DB_NAME = 'memelev'
const STORE = 'sessions'

export function storageId(chainId: number, router: Address, owner: Address): string {
  return `${chainId}:${router.toLowerCase()}:${owner.toLowerCase()}`
}

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    if (typeof indexedDB === 'undefined') return reject(new Error('This browser has no IndexedDB, which one-click trading needs.'))
    const req = indexedDB.open(DB_NAME, 1)
    req.onupgradeneeded = () => req.result.createObjectStore(STORE)
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(new Error('This browser blocks site storage, which one-click trading needs.'))
  })
}

async function withStore<T>(mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await openDb()
  try {
    return await new Promise<T>((resolve, reject) => {
      const tx = db.transaction(STORE, mode)
      const req = fn(tx.objectStore(STORE))
      tx.oncomplete = () => resolve(req.result)
      tx.onerror = () => reject(tx.error ?? new Error('Browser storage failed.'))
      tx.onabort = () => reject(tx.error ?? new Error('Browser storage failed.'))
    })
  } finally {
    db.close()
  }
}

/** Fails early (before any wallet transaction) when storage is blocked. */
export async function checkStorage(): Promise<void> {
  ;(await openDb()).close()
}

export async function loadSession(chainId: number, router: Address, owner: Address): Promise<StoredSession | null> {
  const s = await withStore<StoredSession | undefined>('readonly', (st) => st.get(storageId(chainId, router, owner)))
  return s ?? null
}

// The CryptoKey is stored by structured clone, which keeps it non-extractable.
export async function saveSession(s: StoredSession): Promise<void> {
  await withStore('readwrite', (st) => st.put(s, storageId(s.chainId, s.router, s.owner)))
}

// Keys this browser deleted without revoking them on-chain (logout while the relayer was down or one-click was
// paused). Only the public key ids are kept, so the app can keep offering to revoke them from the wallet.
const UNREVOKED_PREFIX = 'memelev.unrevoked:'

export function loadUnrevoked(chainId: number, router: Address, owner: Address): Hex[] {
  try {
    const v: unknown = JSON.parse(localStorage.getItem(UNREVOKED_PREFIX + storageId(chainId, router, owner)) ?? '[]')
    return Array.isArray(v) ? v.filter((k): k is Hex => typeof k === 'string' && /^0x[0-9a-fA-F]{64}$/.test(k)) : []
  } catch {
    return []
  }
}

export function saveUnrevoked(chainId: number, router: Address, owner: Address, keys: Hex[]): void {
  try {
    const id = UNREVOKED_PREFIX + storageId(chainId, router, owner)
    if (keys.length > 0) localStorage.setItem(id, JSON.stringify(keys))
    else localStorage.removeItem(id)
  } catch {
    // Storage can be blocked; the warning then lasts until the page closes.
  }
}

/** Deletes the stored key. With `key`, only if that is still the one stored (a newer approval stays). */
export async function deleteSession(chainId: number, router: Address, owner: Address, key?: Hex): Promise<void> {
  const id = storageId(chainId, router, owner)
  await withStore<unknown>('readwrite', (st) => {
    const req = st.get(id)
    req.onsuccess = () => {
      const cur = req.result as StoredSession | undefined
      if (cur && (!key || cur.key.toLowerCase() === key.toLowerCase())) st.delete(id)
    }
    return req
  })
}

// ------------------------------------------------------- chain state

export type SessionState = {
  session: ChainSession
  live: boolean
  paused: boolean
  epoch: number
  openStake: bigint
  now: bigint
  blockNumber: bigint
}

/** The session as the router sees it, plus what the client-side limit checks need, all at one block. */
export async function readSessionState(owner: Address, key: Hex): Promise<SessionState> {
  const block = await publicClient.getBlock()
  const at = { blockNumber: block.number }
  const read = <T,>(c: typeof tradeRouter | typeof exchange, functionName: string, args: readonly unknown[] = []) =>
    publicClient.readContract({ ...c, functionName, args, ...at }) as Promise<T>
  const [[session, live], paused, epoch, openStake] = await Promise.all([
    read<readonly [ChainSession, boolean]>(tradeRouter, 'sessionOf', [owner, key]),
    read<boolean>(tradeRouter, 'paused'),
    read<number>(tradeRouter, 'epochOf', [owner]),
    read<bigint>(exchange, 'openStakeOf', [owner]),
  ])
  return { session, live, paused, epoch, openStake, now: block.timestamp, blockNumber: block.number }
}

export type SessionStatus =
  | { kind: 'none' }
  | { kind: 'checking' }
  | { kind: 'live' }
  | { kind: 'paused'; reason: string }
  | { kind: 'ended'; reason: string }

export function sessionStatus(local: StoredSession | null, state: SessionState | null, now: number): SessionStatus {
  if (!local) return { kind: 'none' }
  if (!state || state.blockNumber < local.authorizedBlock) return { kind: 'checking' }
  const s = state.session
  if (!s.active || s.generation !== local.generation) return { kind: 'ended', reason: 'it was revoked.' }
  if (s.epoch !== state.epoch) return { kind: 'ended', reason: 'all sessions were revoked.' }
  if (state.now > s.limits.expiry || now > Number(s.limits.expiry)) return { kind: 'ended', reason: 'it expired.' }
  if (state.paused) return { kind: 'paused', reason: 'one-click trading is paused for everyone right now.' }
  return { kind: 'live' }
}

/** Whether orders signed by this key would still run (now, or once a pause lifts): the router hasn't ended it. */
export function stillApproved(state: SessionState): boolean {
  const s = state.session
  return s.active && s.epoch === state.epoch && state.now <= s.limits.expiry
}

/** The stored unrevoked keys that the chain still approves; drops the rest from storage. A key that can't be
 *  checked right now is kept, so the warning errs on the safe side. */
export async function stillApprovedKeys(chainId: number, router: Address, owner: Address): Promise<Hex[]> {
  const keys = loadUnrevoked(chainId, router, owner)
  if (keys.length === 0) return []
  const approved = await Promise.all(keys.map((k) => readSessionState(owner, k).then(stillApproved, () => true)))
  const keep = keys.filter((_, i) => approved[i])
  if (keep.length !== keys.length) saveUnrevoked(chainId, router, owner, keep)
  return keep
}

/** Budget in use now, as the router counts it: each open adds its stake and open fee, and the budget frees up
 *  linearly, a full daily budget per day since the last open. */
export function spentToday(s: ChainSession, now: number): bigint {
  const elapsed = BigInt(Math.floor(now)) - s.dayStart
  const freed = elapsed > 0n ? (elapsed * s.limits.dailyBudget) / DAY : 0n
  return s.spentToday > freed ? s.spentToday - freed : 0n
}

/** Seconds until `amount` more of the budget is free (0 when it already is). */
export function budgetFreeIn(s: ChainSession, now: number, amount = s.limits.dailyBudget): number {
  const over = spentToday(s, now) + amount - s.limits.dailyBudget
  if (over <= 0n) return 0
  if (s.limits.dailyBudget === 0n) return Infinity
  return Number((over * DAY + s.limits.dailyBudget - 1n) / s.limits.dailyBudget)
}

// ------------------------------------------------------ limit checks

/** Why one-click can't place this open, in plain words, or null when it can. Mirrors LevRouter.open. */
export function checkOpen(
  state: SessionState,
  o: { stake: bigint; leverage: number; cost: bigint; balance: bigint | null },
  now: number,
): string | null {
  const s = state.session
  const l = s.limits
  if ((l.actions & ACT_OPEN) === 0) return 'Your one-click session is not allowed to open positions.'
  if (Number(l.expiry) - now < 10) return 'Your one-click session ends in a few seconds.'
  if (o.leverage > l.maxLeverage) return `One-click allows up to ${l.maxLeverage}x leverage.`
  if (o.stake > l.maxStakePerTrade) return `One-click allows a stake of up to ${fmtEth(l.maxStakePerTrade)} ETH per trade.`
  if (state.openStake + o.stake > l.maxOpenStake) {
    return `One-click allows ${fmtEth(l.maxOpenStake)} ETH of open stake in total, and ${fmtEth(state.openStake)} ETH is open now.`
  }
  const spent = spentToday(s, now)
  if (spent + o.cost > l.dailyBudget) {
    return (
      `This would pass your one-click daily budget: ${fmtEth(spent)} of ${fmtEth(l.dailyBudget)} ETH in use. ` +
      `Enough frees up in ${fmtDuration(budgetFreeIn(s, now, o.cost))}.`
    )
  }
  if (o.balance !== null && o.balance < o.cost) {
    return `One-click trades are paid from your trading balance (${fmtEth(o.balance)} ETH); this one needs ${fmtEth(o.cost, 5)} ETH.`
  }
  return null
}

/** Mirrors LevRouter.close: this key opened it and may close its own, or it may close any. */
export function canCloseWith(local: StoredSession, state: SessionState, openedBy: Hex): boolean {
  const a = state.session.limits.actions
  if ((a & ACT_CLOSE_ANY) !== 0) return true
  return (a & ACT_CLOSE_OWN) !== 0 && openedBy.toLowerCase() === local.key.toLowerCase()
}

export function checkWithdraw(state: SessionState, amount: bigint, balance: bigint | null): string | null {
  if ((state.session.limits.actions & ACT_WITHDRAW) === 0) return 'Your one-click session is not allowed to withdraw.'
  if (balance !== null && amount > balance) return 'Your trading balance is too low.'
  return null
}

export function actionsText(actions: number): string {
  const parts: string[] = []
  if (actions & ACT_OPEN) parts.push('open')
  if (actions & ACT_CLOSE_ANY) parts.push('close any position')
  else if (actions & ACT_CLOSE_OWN) parts.push('close what it opened')
  if (actions & ACT_WITHDRAW) parts.push('withdraw to your wallet')
  const text = parts.join(', ')
  return text ? text[0].toUpperCase() + text.slice(1) : 'Nothing'
}
