// One-click trading state for the connected owner: the key stored in this browser, the session as the router
// sees it, the relayer's health, and the order in flight. Orders go out one at a time, each signed once and
// posted once, then watched until the relayer or the chain says how it ended.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { getAddress, parseEventLogs, type Address, type Hex } from 'viem'
import { deployment } from '../config'
import { hasTradeRouter, publicClient, routerAbi, tradeRouter } from './chain'
import { explainError, explainErrorName, isTemporary, retryingText } from './errors'
import { shortAddress } from './format'
import { sameAddress, type Run } from './hooks'
import { checkRelayer, getIntentStatus, postIntent, RelayerError, type IntentStatus, type RelayerHealth } from './relayer'
import {
  canCloseWith,
  checkOpen,
  checkStorage,
  checkWithdraw,
  createSessionKey,
  deleteSession,
  loadSession,
  loadUnrevoked,
  readSessionState,
  saveSession,
  saveUnrevoked,
  sessionStatus,
  signIntent,
  stillApproved,
  stillApprovedKeys,
  storageId,
  type IntentFields,
  type IntentKind,
  type Limits,
  type SessionKey,
  type SessionState,
  type SignedIntent,
  type StoredSession,
} from './session'

const STATE_POLL_MS = 3000
const HEALTH_POLL_MS = 10_000
const STATUS_POLL_MS = 1000
const GRACE_S = 4n // after the deadline, give the relayer a moment to report before asking the chain
const GIVE_UP_MS = 180_000
// Tabs of this app tell each other when a stored key changes, so none keeps using or showing a stale one.
const CHANNEL = 'memelev-oneclick'

export type IntentStage = 'signing' | 'sending' | 'queued' | 'retrying' | 'sent' | 'confirmed' | 'failed' | 'expired'

export type IntentProgress = {
  seq: number
  label: string
  kind: IntentKind
  stage: IntentStage
  text: string
  closing?: bigint // position being closed
  positionId?: bigint // position just opened
  txHash?: Hex
  error?: string // the last contract or relayer error name, once it failed or ran out of time
}

export const isFinal = (stage: IntentStage) => stage === 'confirmed' || stage === 'failed' || stage === 'expired'

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const sameKey = (a: Hex | null | undefined, b: Hex | null | undefined) => (a ?? '').toLowerCase() === (b ?? '').toLowerCase()

/** Runs `fn` holding a browser-wide lock (Web Locks), or tells it the lock is taken. Without Web Locks it just runs. */
async function withTabLock<T>(name: string, fn: (got: boolean) => Promise<T>): Promise<T> {
  const locks = typeof navigator !== 'undefined' ? navigator.locks : undefined
  if (!locks?.request) return fn(true)
  return locks.request(name, { ifAvailable: true }, (held) => fn(held !== null)) as Promise<T>
}

function doneText(kind: IntentKind, positionId?: bigint): string {
  if (kind === 'open') return positionId !== undefined ? `Opened position #${positionId}.` : 'Opened.'
  if (kind === 'close') return 'Closed. What came back is in your trading balance.'
  if (kind === 'withdraw') return 'Sent to your wallet.'
  return 'The key is revoked on-chain too.'
}

function expiredText(kind: IntentKind, lastError: string | undefined): string {
  if (lastError === 'PriceMoved') {
    if (kind === 'close') {
      return (
        'The price kept moving further from its 1-minute average than your one-click close slippage allows, until the ' +
        'order’s 30 s deadline passed. Nothing was traded. To close now, use Close with wallet on the position.'
      )
    }
    const tail = kind === 'open' ? ' Try again once it settles, or open with your wallet.' : ' Try again.'
    return `The price kept moving too fast before the order’s 30 s deadline. Nothing was traded.${tail}`
  }
  if (isTemporary(lastError)) return `${explainErrorName(lastError!)} The order ran out of time, so nothing was traded.`
  return 'The order was not sent in time, so nothing was traded. Try again.'
}

function failedText(kind: IntentKind, error: string | undefined): string {
  if (!error) return 'The order failed, so nothing was traded.'
  // The session only closes the owner's own positions, so for a close these mean someone (the wallet, a keeper) got there first.
  if (kind === 'close' && (error === 'NotPositionOwner' || error === 'NotOpen')) return 'This position is already closed.'
  return explainErrorName(error)
}

async function nonceUsedOnChain(owner: Address, nonce: bigint, blockNumber: bigint): Promise<boolean> {
  return publicClient.readContract({ ...tradeRouter, functionName: 'nonceUsed', args: [owner, nonce], blockNumber }) as Promise<boolean>
}

export function useOneClick(owner: Address | null, now: number, run: Run, onDone: () => void) {
  const chainId = deployment.chainId
  const router = tradeRouter.address
  const [local, setLocalState] = useState<StoredSession | null>(null)
  const [loaded, setLoaded] = useState(false)
  const [storageError, setStorageError] = useState<string | null>(null)
  const [state, setState] = useState<SessionState | null>(null)
  const [relayer, setRelayer] = useState<RelayerHealth | null>(null)
  const [progress, setProgress] = useState<IntentProgress | null>(null)
  const [notice, setNotice] = useState<string | null>(null) // how the last session on this device ended
  const [unrevoked, setUnrevokedState] = useState<Hex[]>([]) // keys deleted here that may still be approved on-chain
  const localRef = useRef<StoredSession | null>(null)
  const ownerRef = useRef(owner) // the owner now, for async work that started under another one
  ownerRef.current = owner
  const version = useRef(0) // bumps on every local change, so reads started before it are dropped
  const lock = useRef(false)
  const seq = useRef(0)
  const channel = useRef<BroadcastChannel | null>(null)

  const setLocal = useCallback((s: StoredSession | null) => {
    version.current++
    localRef.current = s
    setLocalState(s)
    setState(null)
  }, [])

  /** Tells this app's other tabs that the keys stored for `o` changed. */
  const announce = useCallback(
    (o: Address) => {
      try {
        channel.current?.postMessage({ id: storageId(chainId, router, o) })
      } catch {
        // Another tab still catches up when it gets focus.
      }
    },
    [chainId, router],
  )

  const setUnrevoked = useCallback(
    (o: Address, change: (keys: Hex[]) => Hex[]) => {
      const before = loadUnrevoked(chainId, router, o)
      const keys = change(before).filter((k, i, all) => all.findIndex((x) => sameKey(x, k)) === i)
      saveUnrevoked(chainId, router, o, keys)
      if (sameAddress(ownerRef.current, o)) setUnrevokedState(keys)
      announce(o)
    },
    [chainId, router, announce],
  )

  // Load this browser's key for the connected owner.
  useEffect(() => {
    setLocal(null)
    setLoaded(false)
    setNotice(null)
    setUnrevokedState([])
    if (!owner || !hasTradeRouter) {
      setLoaded(true)
      return
    }
    let live = true
    loadSession(chainId, router, owner)
      .then((s) => {
        if (!live) return
        setLocal(s)
        setStorageError(null)
      })
      .catch((e) => live && setStorageError(explainError(e)))
      .finally(() => live && setLoaded(true))
    stillApprovedKeys(chainId, router, owner).then((keys) => live && setUnrevokedState(keys))
    return () => {
      live = false
    }
  }, [owner, chainId, router, setLocal])

  // Another tab turned one-click on or off, or logged out: follow what is stored now.
  const sync = useCallback(async () => {
    const o = ownerRef.current
    if (!o || !hasTradeRouter) return
    const v = version.current
    let stored: StoredSession | null
    try {
      stored = await loadSession(chainId, router, o)
    } catch {
      return
    }
    if (v !== version.current || !sameAddress(ownerRef.current, o)) return
    setUnrevokedState(loadUnrevoked(chainId, router, o))
    const cur = localRef.current
    if (sameKey(cur?.key, stored?.key)) return
    setLocal(stored)
    setNotice(stored ? null : 'One-click was turned off in another tab of this browser.')
  }, [chainId, router, setLocal])

  useEffect(() => {
    if (!hasTradeRouter) return
    let ch: BroadcastChannel | null = null
    try {
      ch = typeof BroadcastChannel === 'undefined' ? null : new BroadcastChannel(CHANNEL)
    } catch {
      ch = null
    }
    channel.current = ch
    const onMessage = (e: MessageEvent) => {
      const o = ownerRef.current
      if (o && (e.data as { id?: unknown } | null)?.id === storageId(chainId, router, o)) void sync()
    }
    // Also re-check on focus, for browsers without BroadcastChannel.
    const onFocus = () => void sync()
    const onVisible = () => document.visibilityState === 'visible' && void sync()
    ch?.addEventListener('message', onMessage)
    window.addEventListener('focus', onFocus)
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      ch?.removeEventListener('message', onMessage)
      ch?.close()
      channel.current = null
      window.removeEventListener('focus', onFocus)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [chainId, router, sync])

  const refreshState = useCallback(async () => {
    const cur = localRef.current
    if (!cur) return
    const v = version.current
    try {
      const st = await readSessionState(cur.owner, cur.key)
      if (v === version.current) setState(st)
    } catch {
      // Keep the last state; the app already shows a banner when the chain can't be read.
    }
  }, [])

  useEffect(() => {
    if (!local) return
    refreshState()
    const t = setInterval(refreshState, STATE_POLL_MS)
    return () => clearInterval(t)
  }, [local, refreshState])

  const refreshHealth = useCallback(async () => setRelayer(await checkRelayer()), [])
  useEffect(() => {
    if (!owner || !hasTradeRouter) return
    refreshHealth()
    const t = setInterval(refreshHealth, HEALTH_POLL_MS)
    return () => clearInterval(t)
  }, [owner, refreshHealth])

  /** Deletes the key from this browser. With `all`, whatever is stored for its owner, not only this key. */
  const forget = useCallback(
    async (cur: StoredSession, why: string, all = false) => {
      await deleteSession(cur.chainId, cur.router, cur.owner, all ? undefined : cur.key).catch(() => {})
      announce(cur.owner)
      if (sameKey(localRef.current?.key, cur.key)) setLocal(null)
      if (sameAddress(ownerRef.current, cur.owner)) setNotice(why)
    },
    [setLocal, announce],
  )

  // When the chain says the session is over, drop the dead key. Only chain reads decide this, never the local clock.
  const chainStatus = useMemo(() => sessionStatus(local, state, 0), [local, state])
  useEffect(() => {
    if (local && chainStatus.kind === 'ended') void forget(local, `Your one-click session ended: ${chainStatus.reason}`)
  }, [local, chainStatus, forget])

  const status = sessionStatus(local, state, now)
  const usable = status.kind === 'live'
  const ready = usable && relayer?.ok === true
  // Why a session this browser holds can't be used right now (lower case, ends with a full stop).
  const fallback =
    !local || status.kind === 'checking'
      ? null
      : status.kind === 'paused'
        ? status.reason
        : usable && relayer && !relayer.ok
          ? relayer.reason
          : null

  // ----------------------------------------------------------- orders

  /** Posts a signed order once, then follows it to the end. Never re-sends it. With `quick`, stops as soon as
   *  the relayer can't be reached instead of waiting out the deadline (fine for a revoke, not for a trade). */
  const deliver = useCallback(
    async (
      signed: SignedIntent,
      update: (stage: IntentStage, text: string, extra?: Partial<IntentProgress>) => void,
      quick = false,
    ) => {
      update('sending', 'Sending to the relayer…')
      try {
        await postIntent(signed)
        update('queued', 'Waiting for the relayer…')
      } catch (e) {
        if (e instanceof RelayerError && !e.unknown) {
          update('failed', e.code ? failedText(signed.kind, e.code) : e.message, { error: e.code ?? undefined })
          return false
        }
        setRelayer({ ok: false, reason: 'the relayer is not answering.' })
        if (quick) {
          update('failed', 'The relayer did not answer.')
          return false
        }
        // It may have arrived. Watch it until its deadline passes, then the chain has the last word.
        update('queued', 'The relayer did not answer. Checking whether it got the order…')
      }

      const { owner: who, nonce, deadline } = signed.intent
      const started = Date.now()
      let lastError: string | undefined
      for (;;) {
        await sleep(STATUS_POLL_MS)
        let st: IntentStatus | null = null
        try {
          st = await getIntentStatus(who, nonce)
        } catch {
          // Unreachable for now; the chain check below still ends the wait.
        }
        if (st) {
          if (st.error) lastError = st.error
          const pid = st.positionId ? BigInt(st.positionId) : undefined
          if (st.status === 'confirmed') {
            update('confirmed', doneText(signed.kind, pid), { txHash: st.txHash, positionId: pid })
            return true
          }
          if (st.status === 'failed') {
            update('failed', failedText(signed.kind, st.error), { txHash: st.txHash, error: st.error })
            if (st.error === 'SessionInvalid' || st.error === 'NotAllowed' || st.error === 'Paused') void refreshState()
            return false
          }
          if (st.status === 'expired') {
            update('expired', expiredText(signed.kind, lastError), { error: lastError })
            return false
          }
          if (st.status === 'sent') update('sent', 'Sent, waiting for the block…', { txHash: st.txHash })
          else if (isTemporary(st.error)) update('retrying', retryingText(st.error))
        }
        // Once the chain's clock passes the deadline the order can never run, so its nonce settles the outcome.
        const block = await publicClient.getBlock().catch(() => null)
        if (block && block.timestamp > deadline + GRACE_S) {
          const used = await nonceUsedOnChain(who, nonce, block.number).catch(() => null)
          if (used === true) {
            update('confirmed', doneText(signed.kind))
            return true
          }
          if (used === false) {
            update('expired', expiredText(signed.kind, lastError), { error: lastError })
            return false
          }
        }
        if (Date.now() - started > GIVE_UP_MS) {
          update('failed', "Couldn't find out what happened to this order. Check your positions and balance.")
          return false
        }
      }
    },
    [refreshState],
  )

  const tracker = useCallback((label: string, kind: IntentKind, closing?: bigint) => {
    const id = ++seq.current
    let cur: IntentProgress = { seq: id, label, kind, stage: 'signing', text: 'Signing in this browser…', closing }
    setProgress(cur)
    return (stage: IntentStage, text: string, extra: Partial<IntentProgress> = {}) => {
      cur = { ...cur, ...extra, stage, text }
      setProgress(cur)
    }
  }, [])

  /** Signs and sends one order through the relayer. Resolves true when it ran on-chain. */
  const submit = useCallback(
    async (label: string, fields: IntentFields): Promise<boolean> => {
      const signer = localRef.current
      if (!signer || lock.current) return false
      lock.current = true
      const update = tracker(label, fields.kind, fields.kind === 'close' ? fields.positionId : undefined)
      try {
        let signed: SignedIntent
        try {
          signed = await signIntent(signer, fields)
        } catch (e) {
          update('failed', explainError(e))
          return false
        }
        return await deliver(signed, update)
      } finally {
        lock.current = false
        onDone()
        void refreshState()
      }
    },
    [tracker, deliver, onDone, refreshState],
  )

  // ------------------------------------------------------- the session

  /** One wallet transaction: deposits `deposit` and approves a fresh key made in this browser. */
  const authorize = useCallback(
    async (deposit: bigint, limits: Limits): Promise<boolean> => {
      if (!owner) return false
      const o = owner
      try {
        await checkStorage()
      } catch (e) {
        setStorageError(explainError(e))
        return false
      }
      // One approval at a time per account in this browser, so two tabs can't each approve a key.
      return withTabLock(`${CHANNEL}:${storageId(chainId, router, o)}`, async (got) => {
        if (!got) {
          setNotice('One-click is being turned on for this account in another tab of this browser.')
          return false
        }
        // Another tab may have turned it on since this one loaded: use that key rather than approving a second one.
        let existing: StoredSession | null
        try {
          existing = await loadSession(chainId, router, o)
        } catch (e) {
          setStorageError(explainError(e))
          return false
        }
        if (existing) {
          const st = await readSessionState(existing.owner, existing.key).catch(() => null)
          if (sessionStatus(existing, st, 0).kind !== 'ended') {
            if (sameAddress(ownerRef.current, o)) {
              setLocal(existing)
              setNotice('One-click is already on for this account in this browser (turned on in another tab), so no second key was approved.')
            }
            return false
          }
        }
        let k: SessionKey
        try {
          k = await createSessionKey()
        } catch (e) {
          setStorageError(explainError(e))
          return false
        }
        const receipt = await run('Turn on one-click trading', {
          ...tradeRouter,
          functionName: 'authorize',
          args: [k.qx, k.qy, limits],
          value: deposit,
        })
        if (!receipt) return false
        const ev = parseEventLogs({ abi: routerAbi, eventName: 'SessionAuthorized', logs: receipt.logs })
          .filter((l) => l.address.toLowerCase() === router.toLowerCase())
          .map((l) => l.args as unknown as { key: Hex; generation: number })
          .find((a) => a.key.toLowerCase() === k.key.toLowerCase())
        const generation =
          ev?.generation ??
          ((await publicClient.readContract({
            ...tradeRouter,
            functionName: 'generationOf',
            args: [o],
            blockNumber: receipt.blockNumber,
          })) as number)
        const s: StoredSession = {
          owner: getAddress(o),
          chainId,
          router,
          key: k.key,
          qx: k.qx,
          qy: k.qy,
          generation: Number(generation),
          limits,
          privateKey: k.privateKey,
          authorizedBlock: receipt.blockNumber,
          createdAt: Date.now(),
        }
        const stillHere = () => sameAddress(ownerRef.current, s.owner)
        try {
          await saveSession(s)
        } catch (e) {
          if (stillHere()) setStorageError(`The key could not be saved in this browser, so one-click is off. ${explainError(e)}`)
          return false
        }
        announce(s.owner)
        // The wallet switched accounts while the transaction was pending: the key is kept for the account that
        // approved it, but not used for the one connected now.
        if (!stillHere()) {
          setNotice(`One-click was turned on for ${shortAddress(s.owner)}, the account that approved it. Switch back to it to use one-click.`)
          return true
        }
        setNotice(null)
        setStorageError(null)
        setLocal(s)
        return true
      })
    },
    [owner, chainId, router, run, setLocal, announce],
  )

  /** Wallet transaction that revokes one key: this browser's, or one it deleted that is still approved. */
  const revoke = useCallback(
    async (key?: Hex) => {
      const cur = localRef.current
      const o = ownerRef.current
      const target = key ?? cur?.key
      if (!o || !target) return
      const r = await run('Revoke the one-click key', { ...tradeRouter, functionName: 'revoke', args: [target] })
      if (!r) return
      setUnrevoked(o, (keys) => keys.filter((k) => !sameKey(k, target)))
      if (cur && sameKey(cur.key, target)) await forget(cur, 'One-click is off: you revoked this browser’s key.')
      else if (sameAddress(ownerRef.current, o)) setNotice('That key is revoked on-chain now, so nothing can use it.')
    },
    [run, forget, setUnrevoked],
  )

  const revokeAll = useCallback(async () => {
    const o = ownerRef.current
    if (!o) return
    const r = await run('Revoke all one-click sessions', { ...tradeRouter, functionName: 'revokeAll' })
    if (!r) return
    const why = 'One-click is off: you revoked every session, on every device.'
    setUnrevoked(o, () => [])
    const cur = localRef.current
    if (cur && sameAddress(cur.owner, o)) {
      await forget(cur, why, true)
    } else {
      // Every key of this owner is dead now, including any a stale tab stored.
      await deleteSession(chainId, router, o).catch(() => {})
      announce(o)
      if (sameAddress(ownerRef.current, o)) setNotice(why)
    }
  }, [run, forget, setUnrevoked, chainId, router, announce])

  /** Revokes the key through the relayer (no gas, no pop-up) and always deletes it from this browser. Only a live
   *  session can revoke itself by signature: while one-click is paused, or the chain can't be read, or the relayer is
   *  down, the key is deleted here but stays approved on-chain, and the panel offers to revoke it from the wallet. */
  const logout = useCallback(async () => {
    const cur = localRef.current
    if (!cur || lock.current) return
    lock.current = true
    try {
      // Ask the chain now instead of trusting the last poll.
      const st = await readSessionState(cur.owner, cur.key).catch(() => null)
      const chain = sessionStatus(cur, st, 0)
      // A stale tab may have stored another key for this owner: this browser logs out of that one too.
      const stored = await loadSession(cur.chainId, cur.router, cur.owner).catch(() => null)
      const other = stored && !sameKey(stored.key, cur.key) ? stored : null
      const otherApproved = other
        ? await readSessionState(other.owner, other.key).then(stillApproved, () => true)
        : false

      const why =
        chain.kind === 'paused'
          ? 'one-click is paused for everyone, and a paused router takes no signed revoke'
          : chain.kind === 'checking'
            ? 'the chain could not be read'
            : relayer?.ok !== true
              ? relayer && !relayer.ok
                ? relayer.reason
                : 'the relayer is not answering'
              : null
      // Sign the revoke before the key is deleted.
      const signed =
        chain.kind === 'live' && why === null ? await signIntent(cur, { kind: 'revoke' }).catch(() => null) : null
      const notRevoked = (reason: string) =>
        `Logged out on this device: its trading key is deleted from this browser, but it was not revoked on-chain (${reason.replace(/\.$/, '')}).`
      const otherText = other ? ' Another key this browser held for this account is deleted too.' : ''

      const kept: Hex[] = otherApproved && other ? [other.key] : []
      if (chain.kind === 'ended') {
        await forget(cur, `Logged out on this device: its trading key is deleted, and its session had already ended on-chain.${otherText}`, true)
      } else if (!signed) {
        kept.push(cur.key)
        await forget(cur, notRevoked(why ?? 'it could not sign the revoke') + otherText, true)
      } else {
        await forget(cur, `Logged out on this device: its trading key is deleted. Revoking it on-chain…${otherText}`, true)
      }
      if (kept.length > 0) setUnrevoked(cur.owner, (keys) => [...keys, ...kept])
      if (!signed) return

      const update = tracker('Log out on this device', 'revoke')
      const ok = await deliver(signed, update, true)
      const mine = sameAddress(ownerRef.current, cur.owner)
      if (ok) {
        if (mine) setNotice(`Logged out on this device: its trading key is deleted and revoked on-chain, so nothing can use it.${otherText}`)
        return
      }
      const msg = notRevoked('the relayer could not do it')
      update('expired', msg)
      if (mine) setNotice(msg + otherText)
      setUnrevoked(cur.owner, (keys) => [...keys, cur.key])
    } finally {
      lock.current = false
    }
  }, [relayer, forget, tracker, deliver, setUnrevoked])

  // Confirmations fade; failures stay until dismissed.
  useEffect(() => {
    if (progress?.stage !== 'confirmed') return
    const t = setTimeout(() => setProgress((p) => (p === progress ? null : p)), 6000)
    return () => clearTimeout(t)
  }, [progress])

  // ------------------------------------------------- client-side checks

  const openBlock = (o: { stake: bigint; leverage: number; cost: bigint; balance: bigint | null }) =>
    state && usable ? checkOpen(state, o, now) : null
  const canClose = (openedBy: Hex) => ready && !!local && !!state && canCloseWith(local, state, openedBy)
  const withdrawBlock = (amount: bigint, balance: bigint | null) => (state && usable ? checkWithdraw(state, amount, balance) : null)

  return {
    supported: hasTradeRouter,
    loaded,
    storageError,
    local,
    state,
    status,
    relayer,
    ready,
    fallback,
    notice,
    progress,
    unrevoked,
    busy: progress !== null && !isFinal(progress.stage),
    openBlock,
    canClose,
    withdrawBlock,
    submit,
    authorize,
    revoke,
    revokeAll,
    logout,
    clearProgress: () => setProgress(null),
    clearNotice: () => setNotice(null),
  }
}

export type OneClick = ReturnType<typeof useOneClick>
