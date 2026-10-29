import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { Address, TransactionReceipt } from 'viem'
import { readSnapshot } from './reads'
import type { Snapshot } from './types'
import { explainError } from './errors'
import { send, type Wallet, type Write } from './wallet'

const POLL_MS = 3000

export function sameAddress(a: string | null | undefined, b: string | null | undefined): boolean {
  return (a ?? '').toLowerCase() === (b ?? '').toLowerCase()
}

/** Polls everything the app shows. `now()` is the chain's clock, advanced locally between polls. */
export function useSnapshot(address: Address | null) {
  const [snap, setSnap] = useState<Snapshot | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [fetchedAt, setFetchedAt] = useState(0)
  const inFlight = useRef(false)
  const again = useRef(false)
  const addrRef = useRef(address)
  addrRef.current = address

  /** Reads now, or right after the read in flight: that one may have started before a write landed or for the
   *  previous account, so its result alone is not enough. */
  const refresh = useCallback(async () => {
    if (inFlight.current) {
      again.current = true
      return
    }
    inFlight.current = true
    try {
      do {
        again.current = false
        const asked = addrRef.current
        try {
          const s = await readSnapshot(asked)
          // The account changed while this was read: drop it and read for the new one.
          if (!sameAddress(asked, addrRef.current)) {
            again.current = true
            continue
          }
          setSnap(s)
          setFetchedAt(Date.now())
          setError(null)
        } catch (e) {
          if (sameAddress(asked, addrRef.current)) setError(explainError(e))
        }
      } while (again.current)
    } finally {
      inFlight.current = false
    }
  }, [])

  useEffect(() => {
    void refresh()
    // The timer skips a tick while a read runs, so a slow RPC isn't read back to back.
    const t = setInterval(() => {
      if (!inFlight.current) void refresh()
    }, POLL_MS)
    return () => clearInterval(t)
  }, [refresh, address])

  // Never show one account's balance and positions next to another's address, even for a moment.
  const shown = useMemo(
    () => (snap && snap.account && !sameAddress(snap.account.address, address) ? { ...snap, account: null } : snap),
    [snap, address],
  )

  return { snap: shown, error, refresh, fetchedAt }
}

/** Re-renders once a second so countdowns move. Returns the chain time in seconds. */
export function useChainClock(chainNow: bigint | undefined, fetchedAt: number): number {
  const [, setTick] = useState(0)
  useEffect(() => {
    const t = setInterval(() => setTick((x) => x + 1), 1000)
    return () => clearInterval(t)
  }, [])
  if (chainNow === undefined) return Math.floor(Date.now() / 1000)
  return Number(chainNow) + Math.max(0, Math.floor((Date.now() - fetchedAt) / 1000))
}

export type TxState = { label: string; status: 'pending' | 'done' | 'error'; message?: string } | null

export function useTx(wallet: Wallet | null, onDone: () => void) {
  const [tx, setTx] = useState<TxState>(null)
  const run = useCallback(
    async (label: string, call: Write): Promise<TransactionReceipt | null> => {
      if (!wallet) {
        setTx({ label, status: 'error', message: 'Connect a wallet first.' })
        return null
      }
      setTx({ label, status: 'pending' })
      try {
        const receipt = await send(wallet, call)
        setTx({ label, status: 'done' })
        onDone()
        return receipt
      } catch (e) {
        setTx({ label, status: 'error', message: explainError(e) })
        return null
      }
    },
    [wallet, onDone],
  )
  // Confirmations fade after a few seconds; errors stay until dismissed.
  useEffect(() => {
    if (tx?.status !== 'done') return
    const t = setTimeout(() => setTx((cur) => (cur === tx ? null : cur)), 5000)
    return () => clearTimeout(t)
  }, [tx])

  return { tx, run, busy: tx?.status === 'pending', clear: () => setTx(null) }
}

/** Sends a wallet transaction with a status toast. Resolves to the receipt, or null when it failed. */
export type Run = (label: string, call: Write) => Promise<TransactionReceipt | null>
