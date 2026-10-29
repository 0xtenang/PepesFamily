// Client for the relayer that submits signed one-click orders and pays their gas (see the HTTP API in the
// relayer's README). Everything it returns is treated as data.
import type { Address, Hex } from 'viem'
import { deployment, relayerUrl } from '../config'
import { tradeRouter } from './chain'
import { explainErrorName } from './errors'
import { intentJson, type SignedIntent } from './session'

export type RelayerHealth = { ok: true; relayer: Address } | { ok: false; reason: string }

export type IntentStatus = {
  status: 'pending' | 'sent' | 'confirmed' | 'failed' | 'expired'
  txHash?: Hex
  positionId?: string
  error?: string
  receivedAt: number
  sentAt?: number
  includedAt?: number
}

/** permanent: the relayer won't retry and nothing was traded. unknown: we can't tell whether it got the order. */
export class RelayerError extends Error {
  constructor(
    message: string,
    readonly code: string | null,
    readonly permanent: boolean,
    readonly unknown = false,
  ) {
    super(message)
  }
}

const TIMEOUT_MS = 6000

async function call(path: string, init?: RequestInit): Promise<Response> {
  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS)
  try {
    return await fetch(`${relayerUrl}${path}`, { ...init, signal: ctrl.signal })
  } finally {
    clearTimeout(t)
  }
}

export async function checkRelayer(): Promise<RelayerHealth> {
  if (!relayerUrl) return { ok: false, reason: 'no relayer is set up for this network.' }
  try {
    const res = await call('/health')
    if (res.status === 403) return { ok: false, reason: 'the relayer does not take orders from this site.' }
    if (!res.ok) return { ok: false, reason: 'the relayer is not ready.' }
    const h = (await res.json()) as { ok?: boolean; chainId?: number; router?: string; relayer?: Address; balanceWei?: string }
    if (h.ok !== true) return { ok: false, reason: 'the relayer is not ready.' }
    if (Number(h.chainId) !== deployment.chainId || String(h.router).toLowerCase() !== tradeRouter.address.toLowerCase()) {
      return { ok: false, reason: 'the relayer serves a different chain or contract.' }
    }
    if (h.balanceWei !== undefined && BigInt(h.balanceWei) === 0n) return { ok: false, reason: 'the relayer is out of gas money.' }
    return { ok: true, relayer: h.relayer as Address }
  } catch {
    return { ok: false, reason: 'the relayer is not answering.' }
  }
}

/** Sends a signed order once. Throws RelayerError; `unknown` means it may still have arrived. */
export async function postIntent(signed: SignedIntent): Promise<void> {
  let res: Response
  try {
    res = await call('/intents', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(intentJson(signed)),
    })
  } catch {
    throw new RelayerError('The relayer did not answer.', null, false, true)
  }
  if (res.status === 202 || res.ok) return
  if (res.status === 429) throw new RelayerError('The relayer is busy. Wait a few seconds and try again.', null, true)
  const body = (await res.json().catch(() => ({}))) as { error?: string; permanent?: boolean }
  if (res.status >= 400 && res.status < 500) {
    const code = typeof body.error === 'string' ? body.error : null
    throw new RelayerError(code ? explainErrorName(code) : 'The relayer refused the order.', code, true)
  }
  // 5xx: the relayer may or may not have queued it.
  throw new RelayerError('The relayer had a problem.', null, false, true)
}

/** null when the relayer doesn't know this order (yet). */
export async function getIntentStatus(owner: Address, nonce: bigint): Promise<IntentStatus | null> {
  const res = await call(`/intents/${owner}/${nonce.toString()}`)
  if (res.status === 404) return null
  if (!res.ok) throw new Error(`Relayer status ${res.status}`)
  return (await res.json()) as IntentStatus
}
