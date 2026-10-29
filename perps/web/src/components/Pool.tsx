import { useState } from 'react'
import { formatEther, parseEther } from 'viem'
import type { Account, Config, PoolState } from '../lib/types'
import { pool as poolContract } from '../lib/chain'
import { bpsPct, fmtDuration, fmtEth } from '../lib/format'
import type { Run } from '../lib/hooks'

type Props = {
  pool: PoolState
  config: Config
  account: Account | null
  now: number
  busy: boolean
  run: Run
}

function parseAmount(text: string): bigint | null {
  try {
    const v = parseEther(text.trim())
    return v > 0n ? v : null
  } catch {
    return null
  }
}

/** LP shares can be worth thousands of ETH each, so show enough digits to see small holdings. */
function fmtShares(v: bigint): string {
  const n = Number(formatEther(v))
  if (n === 0) return '0'
  return n >= 1 ? n.toLocaleString('en-US', { maximumFractionDigits: 4 }) : n.toPrecision(4)
}

export function Pool({ pool, config, account, now, busy, run }: Props) {
  const [dep, setDep] = useState('1')
  const [shares, setShares] = useState('')
  const depAmt = parseAmount(dep)
  const shareAmt = parseAmount(shares)
  const myPct = account && pool.totalSupply > 0n ? Number((account.lpShares * 1_000_000n) / pool.totalSupply) / 10_000 : 0
  const cooldown = Number(pool.withdrawCooldown)
  const windowSecs = Number(pool.withdrawWindow)
  const req = account && account.request.shares > 0n ? account.request : null
  // withdraw() works from unlockAt until unlockAt + withdrawWindow (inclusive), then reverts RequestExpired.
  const unlockIn = req ? Number(req.unlockAt) - now : 0
  const closesIn = req ? Number(req.unlockAt) + windowSecs - now : 0
  const expired = req !== null && closesIn < 0
  const ready = req !== null && unlockIn <= 0 && !expired
  const shortOfCash = req !== null && req.payout > pool.freeCash

  return (
    <div className="stack">
      <section className="panel section" aria-labelledby="h-pool">
        <div className="section-head">
          <h2 id="h-pool">The pool</h2>
          <p className="note">The other side of every position. Creator fees from the platform token flow in here.</p>
        </div>
        <div className="stats">
          <div className="stat">
            <span className="label">Pool value (NAV)</span>
            <span className="value">{fmtEth(pool.nav, 3)}</span>
            <span className="hint">Cash minus what open positions are worth to traders</span>
          </div>
          <div className="stat">
            <span className="label">Share price</span>
            <span className="value">{fmtEth(pool.sharePrice, 4)}</span>
            <span className="hint">ETH per LP share</span>
          </div>
          <div className="stat">
            <span className="label">Creator fees received</span>
            <span className="value">{fmtEth(pool.totalDonated, 3)}</span>
            <span className="hint">ETH added without new shares, so it lifts the share price</span>
          </div>
          <div className="stat">
            <span className="label">Cash</span>
            <span className="value">{fmtEth(pool.cash, 3)}</span>
            <span className="hint">ETH the pool holds</span>
          </div>
          <div className="stat">
            <span className="label">Reserved for max wins</span>
            <span className="value">{fmtEth(pool.totalMaxWin, 3)}</span>
            <span className="hint">If every open position hit its max win</span>
          </div>
          <div className="stat">
            <span className="label">Free cash</span>
            <span className="value">{fmtEth(pool.freeCash, 3)}</span>
            <span className="hint">What LPs can withdraw right now</span>
          </div>
        </div>
        <p className="note">
          Open max wins may use at most {bpsPct(config.coverageBps)} of the pool's cash, so every winner can always be
          paid.
        </p>
      </section>

      <div className="two">
        <section className="panel section" aria-labelledby="h-lp">
          <h2 id="h-lp">Your LP position</h2>
          <dl className="kv">
            <div>
              <dt>LP shares</dt>
              <dd>{account ? fmtShares(account.lpShares) : '–'}</dd>
            </div>
            <div>
              <dt>Worth</dt>
              <dd>{account ? `${fmtEth(account.lpValue, 5)} ETH` : '–'}</dd>
            </div>
            <div>
              <dt>Share of the pool</dt>
              <dd>{account ? `${myPct.toFixed(2)}%` : '–'}</dd>
            </div>
          </dl>
          <div className="field">
            <label htmlFor="lp-dep">Deposit ETH</label>
            <div className="input-row">
              <input id="lp-dep" className="input" inputMode="decimal" value={dep} onChange={(e) => setDep(e.target.value)} />
              <button
                type="button"
                className="btn btn-primary"
                disabled={!account || busy || depAmt === null}
                onClick={() => depAmt && run('Deposit into the pool', { ...poolContract, functionName: 'deposit', value: depAmt })}
              >
                Deposit
              </button>
            </div>
            <p className="note">You get shares at today's pool value, which counts open positions.</p>
          </div>
        </section>

        <section className="panel section" aria-labelledby="h-wd">
          <h2 id="h-wd">Withdraw</h2>
          <p className="note">
            Lock shares first. After {fmtDuration(cooldown)} you have {fmtDuration(windowSecs)} to withdraw them, from free
            cash. You get the lower of their value when you locked them and their value when you withdraw: locked shares
            still take losses but give up gains.
          </p>
          {req && (
            <div className={`banner ${expired ? 'banner-warn' : 'banner-info'}`}>
              {fmtShares(req.shares)} shares locked. At today's pool value they pay{' '}
              <span className="num">{fmtEth(req.payout, 5)}</span> ETH
              {req.valueNow > req.assets ? ', their value when you locked them (they are worth more now)' : ''}.{' '}
              {expired
                ? `This request expired ${fmtDuration(-closesIn)} ago, so it can't be withdrawn. Cancel it to get your shares back, then request again.`
                : unlockIn > 0
                  ? `Ready in ${fmtDuration(unlockIn)}, then you have ${fmtDuration(windowSecs)} to withdraw.`
                  : `Ready to withdraw for ${fmtDuration(closesIn)} more; after that the request expires.`}
              {ready && shortOfCash
                ? ` The pool has only ${fmtEth(pool.freeCash, 5)} ETH of free cash right now, so withdrawing fails until more is free.`
                : ''}
            </div>
          )}
          <div className="field">
            <label htmlFor="lp-shares">Shares to lock</label>
            <div className="input-row">
              <input
                id="lp-shares"
                className="input"
                inputMode="decimal"
                value={shares}
                placeholder="0.0"
                onChange={(e) => setShares(e.target.value)}
              />
              <button
                type="button"
                className="btn btn-small"
                disabled={!account || account.lpShares === 0n}
                onClick={() => account && setShares(formatEther(account.lpShares))}
              >
                Max
              </button>
            </div>
            <button
              type="button"
              className="btn"
              disabled={!account || busy || shareAmt === null}
              onClick={() =>
                shareAmt &&
                run('Lock shares for withdrawal', { ...poolContract, functionName: 'requestWithdraw', args: [shareAmt] }).then(
                  (ok) => ok && setShares(''),
                )
              }
            >
              Request withdrawal
            </button>
            {req && <p className="note">Adding shares to a pending request restarts its cooldown.</p>}
          </div>
          <div className="input-row">
            <button
              type="button"
              className="btn btn-primary"
              disabled={!account || busy || !ready}
              onClick={() => run('Withdraw from the pool', { ...poolContract, functionName: 'withdraw' })}
            >
              Withdraw
            </button>
            <button
              type="button"
              className="btn"
              disabled={!account || busy || !req}
              onClick={() => run('Cancel withdrawal', { ...poolContract, functionName: 'cancelWithdraw' })}
            >
              Cancel request
            </button>
          </div>
        </section>
      </div>
    </div>
  )
}
