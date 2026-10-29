import { useEffect, useState } from 'react'
import { formatEther, parseEther } from 'viem'
import type { Account, Config, MarketRow } from '../lib/types'
import { exchange } from '../lib/chain'
import { bpsPct, fmtDuration, fmtEth, fmtPct, fmtSignedEth, fmtTick, tone } from '../lib/format'
import type { Run } from '../lib/hooks'
import { isFinal, type OneClick } from '../lib/oneclick'

const CLOSE_SLIPPAGE_TICKS = 100 // about 1%: how far the exit may move between clicking and the fill
const INT24_MAX = 8_388_607
const INT24_MIN = -8_388_608

type Props = {
  account: Account | null
  markets: MarketRow[]
  config: Config
  now: number
  busy: boolean // a wallet transaction or a one-click order is in flight
  walletBusy: boolean // a wallet transaction is in flight
  connected: boolean
  run: Run
  oneClick: OneClick
}

const STATUS: Record<number, { text: string; cls: string }> = {
  0: { text: 'Open', cls: '' },
  1: { text: 'Can be liquidated', cls: 'tag-down' },
  2: { text: 'At max win', cls: 'tag-up' },
  3: { text: 'Settled by rug guard', cls: 'tag-warn' },
}

function parseAmount(text: string): bigint | null {
  try {
    const v = parseEther(text.trim())
    return v > 0n ? v : null
  } catch {
    return null
  }
}

type BalanceProps = { account: Account | null; connected: boolean; busy: boolean; run: Run; oneClick: OneClick }

export function Balance({ account, connected, busy, run, oneClick }: BalanceProps) {
  const [dep, setDep] = useState('0.5')
  const [wd, setWd] = useState('')
  const depAmt = parseAmount(dep)
  const wdAmt = parseAmount(wd)
  // Withdrawals can go through one-click (always to this wallet); deposits need the wallet, since they move its ETH.
  const wdBlock = oneClick.ready && wdAmt !== null ? oneClick.withdrawBlock(wdAmt, account?.exchangeBalance ?? null) : null
  const wdViaSession = oneClick.ready && wdAmt !== null && wdBlock === null
  const withdrawing = oneClick.progress?.kind === 'withdraw' && !isFinal(oneClick.progress.stage)

  function withdraw() {
    if (!wdAmt) return
    if (wdViaSession) void oneClick.submit('Withdraw from trading balance', { kind: 'withdraw', amount: wdAmt })
    else void run('Withdraw from trading balance', { ...exchange, functionName: 'withdraw', args: [wdAmt] })
  }

  return (
    <section className="panel section" aria-labelledby="h-balance">
      <div className="section-head">
        <h2 id="h-balance">Trading balance</h2>
        {account && <span className="note">Wallet: {fmtEth(account.walletEth)} ETH</span>}
      </div>
      <div className="stat">
        <span className="label">Available to trade</span>
        <span className="value">{account ? fmtEth(account.exchangeBalance, 5) : '–'} ETH</span>
        <span className="hint">Winnings and closed stakes land here. Withdraw any time.</span>
      </div>
      <div className="field">
        <label htmlFor="dep">Deposit ETH</label>
        <div className="input-row">
          <input id="dep" className="input" inputMode="decimal" value={dep} onChange={(e) => setDep(e.target.value)} />
          <button
            type="button"
            className="btn btn-primary"
            disabled={!account || !connected || busy || depAmt === null}
            onClick={() => depAmt && run('Deposit to trading balance', { ...exchange, functionName: 'deposit', value: depAmt })}
          >
            Deposit
          </button>
        </div>
      </div>
      <div className="field">
        <label htmlFor="wd">Withdraw ETH</label>
        <div className="input-row">
          <input id="wd" className="input" inputMode="decimal" value={wd} placeholder="0.0" onChange={(e) => setWd(e.target.value)} />
          <button
            type="button"
            className="btn btn-small"
            disabled={!account || account.exchangeBalance === 0n}
            onClick={() => account && setWd(formatEther(account.exchangeBalance))}
          >
            Max
          </button>
          <button
            type="button"
            className="btn"
            disabled={!account || busy || wdAmt === null || (!wdViaSession && !connected)}
            onClick={withdraw}
          >
            {withdrawing ? 'Withdrawing…' : 'Withdraw'}
          </button>
        </div>
        {wdViaSession && (
          <p className="oneclick-flag">
            <span className="tag tag-accent">One-click</span> No wallet pop-up. It can only go to this wallet.
          </p>
        )}
        {wdBlock && <p className="note">{wdBlock} This withdrawal will use your wallet.</p>}
      </div>
    </section>
  )
}

export function Positions({ account, markets, config, now, busy, walletBusy, connected, run, oneClick }: Props) {
  const marketOf = (id: number) => markets.find((m) => m.meta.id === id)
  const symbol = (id: number) => marketOf(id)?.meta.symbol ?? `#${id}`
  const rows = account?.positions ?? []
  const progress = oneClick.progress
  const closing = progress?.kind === 'close' && !isFinal(progress.stage) ? progress.closing : undefined
  const walletOnly = oneClick.ready && rows.some((p) => !oneClick.canClose(p.openedBy))
  const closeSlip = oneClick.state?.session.limits.closeSlipTicks

  // Positions whose one-click close is retrying, ran out of time or failed: they also get a wallet close, and keep
  // it after the toast is dismissed.
  const [stuck, setStuck] = useState<ReadonlySet<bigint>>(() => new Set())
  useEffect(() => {
    const id = progress?.kind === 'close' ? progress.closing : undefined
    if (id === undefined || !(progress!.stage === 'retrying' || progress!.stage === 'expired' || progress!.stage === 'failed')) return
    setStuck((s) => (s.has(id) ? s : new Set(s).add(id)))
  }, [progress])

  /** What the router checks on a one-click close: how far the exit (the worse of the live price and the 1-minute
   *  average) is from that average. Zero when the live price is on the trader's side of the average. */
  const closeGap = (marketId: number, isLong: boolean): number => {
    const m = marketOf(marketId)
    if (!m || m.long.reason === 3) return 0 // feed down: the quote's ticks mean nothing
    const { spotTick, fastTick } = m.long
    return Math.max(0, isLong ? fastTick - spotTick : spotTick - fastTick)
  }
  /** Worst exit the close accepts: the exit it would get now, less the slippage. With the feed down, the exchange
   *  settles at the last good average, which is the position's mark. */
  const closeLimit = (p: (typeof rows)[number]): number => {
    const m = marketOf(p.position.marketId)
    const { isLong } = p.position
    const exit =
      !m || m.long.reason === 3 ? p.markTick : isLong ? Math.min(m.long.spotTick, m.long.fastTick) : Math.max(m.long.spotTick, m.long.fastTick)
    return Math.min(INT24_MAX, Math.max(INT24_MIN, isLong ? exit - CLOSE_SLIPPAGE_TICKS : exit + CLOSE_SLIPPAGE_TICKS))
  }
  const tooFast = (p: (typeof rows)[number]) =>
    oneClick.canClose(p.openedBy) && closeSlip !== undefined && closeGap(p.position.marketId, p.position.isLong) > closeSlip
  const tooFastCount = rows.filter(tooFast).length
  return (
    <section className="panel section" aria-labelledby="h-positions">
      <div className="section-head">
        <h2 id="h-positions">Open positions</h2>
        <p className="note">P&amp;L at the 1-minute average price, capped at the max win.</p>
      </div>
      {!account ? (
        <p className="note">Connect a wallet to see your positions.</p>
      ) : rows.length === 0 ? (
        <p className="note">No open positions. Pick a coin on the Trade tab to open one.</p>
      ) : (
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Coin</th>
                <th>Side</th>
                <th className="n">Stake</th>
                <th className="n">Entry</th>
                <th className="n">Mark</th>
                <th className="n">P&amp;L</th>
                <th className="n">Holding fee</th>
                <th className="n">Equity</th>
                <th>Status</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {rows.map((p) => {
                const pos = p.position
                const openAt = Number(pos.openedAt) + config.minHoldSeconds
                const wait = openAt - now
                const pnlPct = Number(p.pnl) / Number(pos.stake)
                const st = STATUS[p.action] ?? STATUS[0]
                const label = `Close ${symbol(pos.marketId)} ${pos.isLong ? 'long' : 'short'}`
                const decimals = marketOf(pos.marketId)?.decimals ?? 18
                // Through one-click only when this browser's key opened it (or may close any), and the price is calm
                // enough for the session's close slippage; otherwise the wallet, whose only bound is the price limit.
                const viaSession = oneClick.canClose(p.openedBy) && !tooFast(p)
                const closeWithWallet = () => run(label, { ...exchange, functionName: 'close', args: [p.id, closeLimit(p)] })
                const close = () =>
                  viaSession ? oneClick.submit(label, { kind: 'close', positionId: p.id, limitTick: closeLimit(p) }) : closeWithWallet()
                // While this position's own one-click close is retrying, the wallet may still race it to the exit.
                const walletAlso = viaSession && stuck.has(p.id)
                const walletDisabled = walletBusy || !connected || wait > 0 || (busy && closing !== p.id)
                return (
                  <tr key={String(p.id)}>
                    <td>
                      <b>{symbol(pos.marketId)}</b>
                    </td>
                    <td>
                      {pos.isLong ? 'Long' : 'Short'} {pos.leverage}x
                    </td>
                    <td className="n num">{fmtEth(pos.stake)}</td>
                    <td className="n num">{fmtTick(pos.entryTick, decimals)}</td>
                    <td className="n num">{fmtTick(p.markTick, decimals)}</td>
                    <td className={`n num ${tone(p.pnl)}`}>
                      {fmtSignedEth(p.pnl)} <span className="muted">({fmtPct(pnlPct)})</span>
                    </td>
                    <td className="n num">{fmtEth(p.holdFee, 6)}</td>
                    <td className={`n num ${p.equity < 0n ? 'down' : ''}`}>{p.equity < 0n ? fmtSignedEth(p.equity) : fmtEth(p.equity)}</td>
                    <td>{st.cls ? <span className={`tag ${st.cls}`}>{st.text}</span> : st.text}</td>
                    <td className="n">
                      <span className="row-actions">
                        {viaSession && <span className="tag tag-accent" title="Closes with no wallet pop-up">One-click</span>}
                        <button type="button" className="btn btn-small" disabled={busy || wait > 0} onClick={close}>
                          {closing === p.id
                            ? 'Closing…'
                            : wait > 0
                              ? `Close in ${fmtDuration(wait)}`
                              : oneClick.ready && !viaSession
                                ? 'Close with wallet'
                                : 'Close'}
                        </button>
                        {walletAlso && (
                          <button type="button" className="btn btn-small" disabled={walletDisabled} onClick={closeWithWallet}>
                            Close with wallet
                          </button>
                        )}
                      </span>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
      {oneClick.fallback && rows.length > 0 && (
        <p className="banner banner-info">One-click is off for now: {oneClick.fallback} Closes use your wallet instead.</p>
      )}
      {walletOnly && (
        <p className="note">
          Positions marked One-click close with no wallet pop-up. The others were not opened by this browser's key, so they
          close with your wallet.
        </p>
      )}
      {tooFastCount > 0 && closeSlip !== undefined && (
        <p className="banner banner-info">
          The live price is further from its 1-minute average than your {bpsPct(closeSlip)} one-click close slippage, so
          one-click can't close {tooFastCount === 1 ? 'that position' : 'those positions'} now. Close with wallet fills at
          once, at the worse of the live price and the average, as long as that is within about 1% of what it shows now.
        </p>
      )}
      <p className="note">
        Values are in ETH. Closing fills at the worse of the live price and the 1-minute average, and is refused if that
        moved more than about 1% since you clicked. It then takes the close fee and {config.profitFeeBps / 100}% of any
        profit.
      </p>
    </section>
  )
}
