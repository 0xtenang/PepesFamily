import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { parseEther } from 'viem'
import type { Config, MarketRow, Quote } from '../lib/types'
import { readQuote } from '../lib/reads'
import { exchange } from '../lib/chain'
import { bpsPct, fmtEth, fmtPct, fmtPrice, liquidationRatio, maxWinRatio, tickToPrice } from '../lib/format'
import { explainError } from '../lib/errors'
import type { Run } from '../lib/hooks'
import { isFinal, type OneClick } from '../lib/oneclick'

type Props = {
  market: MarketRow
  config: Config
  balance: bigint | null // trading balance; null when no wallet is connected
  chainNow: bigint
  connected: boolean
  busy: boolean
  run: Run
  oneClick: OneClick
  onSetupOneClick: () => void
}

const LEVERAGES = [2, 5, 10]
const SLIPPAGE_TICKS = 100 // about 1%
const INT24_MAX = 8_388_607
const INT24_MIN = -8_388_608

function limitTickFor(entryTick: number, isLong: boolean, slipTicks: number): number {
  const raw = isLong ? entryTick + slipTicks : entryTick - slipTicks
  return Math.min(INT24_MAX, Math.max(INT24_MIN, raw))
}

function parseStake(text: string): bigint | null {
  try {
    const v = parseEther(text.trim() === '' ? '0' : text.trim())
    return v > 0n ? v : null
  } catch {
    return null
  }
}

function reasonText(q: Quote, config: Config): string | null {
  switch (q.reason) {
    case 0:
      return null
    case 1:
      return 'This coin is not taking new positions right now.'
    case 2:
      return `This coin is locked for ${Math.round(config.rugLockSeconds / 60)} minutes after its rug guard fired.`
    case 3:
      return "This coin's price feed is down, so new positions are off."
    case 4:
      return `This coin's pool holds less than ${fmtEth(config.minLiquidityEth, 2)} ETH, so new positions are off.`
    case 5:
      return `The most leverage allowed here is ${q.maxLeverage}x.`
    case 6:
      return `This side has room for ${fmtEth(q.netRoom)} ETH more position size on this coin. Lower the stake or leverage.`
    case 7:
      return `The pool can cover a stake of up to ${fmtEth(q.poolRoomStake)} ETH at this max win right now.`
    case 8:
      return `The minimum stake is ${fmtEth(config.minStake)} ETH.`
    case 9:
      return `New positions are paused until the hour is up: the pool lost more than ${bpsPct(config.hourlyLossBreakerBps)} this hour.`
    case 10:
      return 'The live price is so far from its 1-minute average that this position would be liquidated as soon as it opened. Lower the leverage or wait for the price to settle.'
    default:
      return 'This trade is not allowed right now.'
  }
}

export function TradePanel({ market, config, balance, chainNow, connected, busy, run, oneClick, onSetupOneClick }: Props) {
  const [isLong, setIsLong] = useState(true)
  const [lev, setLev] = useState(2)
  const [stakeText, setStakeText] = useState('0.05')
  // Each quote and quote error is kept with the inputs it was read for.
  const [quoted, setQuoted] = useState<{ inputs: string; quote: Quote } | null>(null)
  const [failed, setFailed] = useState<{ inputs: string; error: string } | null>(null)

  const stake = parseStake(stakeText)
  const maxLev = isLong ? market.long.maxLeverage : market.short.maxLeverage
  const id = market.meta.id
  const inputs = `${id}:${isLong}:${lev}:${stake}`
  // A quote counts only for the coin, side, leverage and stake it was read for. Until the new one arrives there is
  // none, so the order can't go out with another coin's price limit, fee or top-up.
  const quote = quoted && stake !== null && quoted.inputs === inputs ? quoted.quote : null
  const quoteError = failed && failed.inputs === inputs ? failed.error : null

  useEffect(() => {
    if (lev > maxLev) setLev(LEVERAGES.filter((l) => l <= maxLev).pop() ?? maxLev)
  }, [lev, maxLev])

  // Re-quote on every input change and every poll (chainNow moves).
  useEffect(() => {
    let live = true
    if (stake === null) {
      setQuoted(null)
      return
    }
    const key = `${id}:${isLong}:${lev}:${stake}`
    const t = setTimeout(() => {
      readQuote(id, isLong, lev, stake)
        .then((q) => {
          if (!live) return
          setQuoted({ inputs: key, quote: q })
          setFailed(null)
        })
        .catch((e) => {
          if (!live) return
          // Don't fall back on an older quote: its price may be stale.
          setQuoted(null)
          setFailed({ inputs: key, error: explainError(e) })
        })
    }, 150)
    return () => {
      live = false
      clearTimeout(t)
    }
  }, [id, isLong, lev, stake, chainNow])

  const preview = useMemo(() => {
    if (!quote || stake === null) return null
    const size = stake * BigInt(lev)
    const entry = tickToPrice(quote.entryTick, market.decimals)
    const liqR = liquidationRatio(isLong, lev, config.liqEquityBps)
    const winR = maxWinRatio(isLong, lev, quote.maxWinBps)
    const mySide = isLong ? market.view.longSize : market.view.shortSize
    const other = isLong ? market.view.shortSize : market.view.longSize
    const crowded = mySide + size > other
    const hourly = (size * BigInt(config.holdRateBpsPerHour) * BigInt(crowded ? config.crowdMultBps : 10_000)) / 10_000n / 10_000n
    const cost = stake + quote.fee
    const topUp = balance === null ? cost : cost > balance ? cost - balance : 0n
    return { size, entry, liqR, winR, crowded, hourly, cost, topUp }
  }, [quote, stake, lev, isLong, config, market.view, market.decimals, balance])

  const problem = quote ? reasonText(quote, config) : null
  const tradeOk = quote !== null && quote.reason === 0 && stake !== null && preview !== null
  // One-click: signed by this browser's session key and sent by the relayer, when the session's limits allow it.
  const sessionBlock =
    oneClick.ready && tradeOk ? oneClick.openBlock({ stake: stake!, leverage: lev, cost: preview!.cost, balance }) : null
  const viaSession = oneClick.ready && tradeOk && sessionBlock === null
  const sessionSlip = oneClick.state?.session.limits.openSlipTicks ?? SLIPPAGE_TICKS
  // What the router checks on a one-click open: how far the entry (the worse of the live price and the 1-minute
  // average) is from that average. A long only pays more when the live price is above the average, a short only when
  // it is below; on the other side the entry is the average itself.
  const fastGap = quote ? Math.max(0, isLong ? quote.spotTick - quote.fastTick : quote.fastTick - quote.spotTick) : 0
  const pending = oneClick.progress?.kind === 'open' && !isFinal(oneClick.progress.stage) ? oneClick.progress : null
  const canSubmit = (viaSession || connected) && !busy && tradeOk
  // After a one-click open ran out of time or failed, or while it likely can't fill, offer the wallet for this one.
  const lastOpenFailed =
    oneClick.progress?.kind === 'open' && (oneClick.progress.stage === 'expired' || oneClick.progress.stage === 'failed')
  const offerWallet = viaSession && connected && (lastOpenFailed || fastGap > sessionSlip)

  async function submit(withWallet = false) {
    if (!quote || stake === null || !preview || !tradeOk || busy) return
    if (withWallet ? !connected : !canSubmit) return
    const label = `Open ${isLong ? 'long' : 'short'} ${lev}x on ${market.meta.symbol}`
    if (viaSession && !withWallet) {
      const limitTick = limitTickFor(quote.entryTick, isLong, Math.min(SLIPPAGE_TICKS, sessionSlip))
      await oneClick.submit(label, { kind: 'open', marketId: id, isLong, leverage: lev, stake, limitTick })
      return
    }
    await run(label, {
      ...exchange,
      functionName: 'open',
      args: [BigInt(id), isLong, lev, stake, limitTickFor(quote.entryTick, isLong, SLIPPAGE_TICKS)],
      value: preview.topUp,
    })
  }

  // Why this trade goes through the wallet although one-click was set up (or how to set it up).
  let walletNote: ReactNode = null
  if (oneClick.supported && oneClick.loaded && balance !== null && !oneClick.ready) {
    if (oneClick.fallback) {
      walletNote = <p className="banner banner-info">One-click is off for now: {oneClick.fallback} Trades use your wallet instead.</p>
    } else if (oneClick.notice) {
      walletNote = <p className="banner banner-info">{oneClick.notice} Trades use your wallet.</p>
    } else if (oneClick.status.kind === 'none') {
      walletNote = (
        <p className="note">
          Each trade asks your wallet.{' '}
          <button type="button" className="linkish" onClick={onSetupOneClick}>
            Turn on one-click trading
          </button>{' '}
          to skip the pop-ups.
        </p>
      )
    }
  }

  const mult = config.crowdMultBps / 10_000
  return (
    <section className="panel section" aria-labelledby="h-trade">
      <div className="section-head">
        <h2 id="h-trade">Trade {market.meta.symbol}</h2>
        <span className="note">{market.meta.name}</span>
      </div>

      <div className="seg" role="group" aria-label="Side">
        <button type="button" aria-pressed={isLong} onClick={() => setIsLong(true)}>
          Long
        </button>
        <button type="button" aria-pressed={!isLong} onClick={() => setIsLong(false)}>
          Short
        </button>
      </div>

      <div className="field">
        <label id="lev-label">Leverage</label>
        <div className="seg" role="group" aria-labelledby="lev-label">
          {LEVERAGES.map((l) => (
            <button key={l} type="button" aria-pressed={lev === l} disabled={l > maxLev} onClick={() => setLev(l)}>
              {l}x
            </button>
          ))}
        </div>
        <p className="note">
          Up to {maxLev}x {isLong ? 'long' : 'short'} on this coin
          {!isLong && config.maxShortLeverage < 10 ? ` (shorts are capped at ${config.maxShortLeverage}x)` : ''}.
        </p>
      </div>

      <div className="field">
        <label htmlFor="stake">Stake (ETH)</label>
        <input
          id="stake"
          className="input"
          inputMode="decimal"
          value={stakeText}
          onChange={(e) => setStakeText(e.target.value)}
          aria-invalid={stake === null}
        />
        <div className="quick">
          {['0.01', '0.05', '0.1', '0.5'].map((v) => (
            <button key={v} type="button" className="btn btn-small" onClick={() => setStakeText(v)}>
              {v}
            </button>
          ))}
        </div>
      </div>

      {stake === null && <p className="banner banner-warn">Enter a stake above zero.</p>}
      {quoteError && <p className="banner banner-error">{quoteError}</p>}

      {quote && preview && (
        <dl className="kv">
          <div>
            <dt>Entry price</dt>
            <dd>
              {fmtPrice(preview.entry)}
              <span className="sub">worse of live price and 1-min average</span>
            </dd>
          </div>
          <div>
            <dt>Position size</dt>
            <dd>{fmtEth(preview.size)} ETH</dd>
          </div>
          <div>
            <dt>Open fee</dt>
            <dd>{fmtEth(quote.fee, 5)} ETH</dd>
          </div>
          <div>
            <dt>Max win</dt>
            <dd>
              +{bpsPct(quote.maxWinBps)}
              <span className="sub">{fmtEth((stake! * BigInt(quote.maxWinBps)) / 10_000n)} ETH before fees</span>
            </dd>
          </div>
          <div>
            <dt>Liquidation price</dt>
            <dd>
              {fmtPrice(preview.entry * preview.liqR)}
              <span className="sub">{fmtPct(preview.liqR - 1)} from entry</span>
            </dd>
          </div>
          <div>
            <dt>Max-win price</dt>
            <dd>
              {preview.winR === null ? 'Not reachable' : fmtPrice(preview.entry * preview.winR)}
              {preview.winR !== null && <span className="sub">{fmtPct(preview.winR - 1)} from entry</span>}
            </dd>
          </div>
          <div>
            <dt>Holding fee after the first hour</dt>
            <dd>
              {fmtEth(preview.hourly, 6)} ETH/h
              <span className="sub">
                {preview.crowded ? `${mult}× — your side would be the crowded one` : 'normal rate — your side is the smaller one'}
              </span>
            </dd>
          </div>
          <div>
            <dt>Taken from your balance</dt>
            <dd>
              {fmtEth(preview.cost, 5)} ETH
              {connected && preview.topUp > 0n && (
                <span className="sub">{fmtEth(preview.topUp, 5)} ETH is deposited from your wallet first</span>
              )}
            </dd>
          </div>
        </dl>
      )}

      {problem && <p className="banner banner-warn">{problem}</p>}
      {sessionBlock && (
        <p className="banner banner-warn">
          {sessionBlock} {connected ? 'This trade will use your wallet instead.' : ''}
        </p>
      )}
      {viaSession && fastGap > sessionSlip && (
        <p className="banner banner-warn">
          The live price is {bpsPct(fastGap)} {isLong ? 'above' : 'below'} its 1-minute average, more than your{' '}
          {bpsPct(sessionSlip)} one-click slippage, so this may not fill until the price settles.
        </p>
      )}
      {walletNote}
      {viaSession && (
        <p className="oneclick-flag">
          <span className="tag tag-accent">One-click</span> No wallet pop-up: signed in this browser, sent by the relayer.
        </p>
      )}

      <button type="button" className="btn btn-primary btn-block" disabled={!canSubmit} onClick={() => void submit()} aria-busy={!!pending}>
        {pending
          ? pending.text
          : viaSession || connected
            ? `Open ${isLong ? 'long' : 'short'} ${lev}x`
            : 'Connect a wallet to trade'}
      </button>
      {offerWallet && (
        <p className="note">
          <button type="button" className="linkish" disabled={busy || !tradeOk} onClick={() => void submit(true)}>
            Open with your wallet instead
          </button>{' '}
          (a wallet transaction, filled within about 1% of the entry price shown).
        </p>
      )}
      <p className="note">
        Fills accept about 1% of price movement. Profits are paid by the pool; the most you can lose is your stake.
      </p>
    </section>
  )
}
