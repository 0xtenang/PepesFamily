import { useState, type ReactNode } from 'react'
import { formatEther, parseEther } from 'viem'
import type { Account, Config } from '../lib/types'
import {
  ACT_CLOSE_ANY,
  ACT_CLOSE_OWN,
  ACT_OPEN,
  ACT_WITHDRAW,
  MAX_SESSION_SECONDS,
  MAX_SLIP_TICKS,
  actionsText,
  budgetFreeIn,
  spentToday,
  type Limits,
} from '../lib/session'
import { isFinal, type IntentProgress, type OneClick } from '../lib/oneclick'
import { bpsPct, fmtDuration, fmtEth, shortAddress } from '../lib/format'

type Props = {
  oneClick: OneClick
  account: Account | null
  config: Config
  now: number
  connected: boolean // wallet on the right chain, needed for the approve / revoke transactions
  busy: boolean
}

const DURATIONS = [
  { label: '1 h', seconds: 3600 },
  { label: '24 h', seconds: 86_400 },
  { label: '3 days', seconds: 3 * 86_400 },
  { label: '7 days', seconds: MAX_SESSION_SECONDS },
]
const LEVERAGES = [2, 5, 10]
const ACTIONS = [
  { bit: ACT_OPEN, label: 'Open positions' },
  { bit: ACT_CLOSE_OWN, label: 'Close positions it opened' },
  { bit: ACT_CLOSE_ANY, label: 'Close any of my positions' },
  { bit: ACT_WITHDRAW, label: 'Withdraw to my wallet' },
]
const DEFAULT_ACTIONS = ACT_OPEN | ACT_CLOSE_OWN | ACT_WITHDRAW
const UINT96_MAX = (1n << 96n) - 1n
// Leave a minute so a 7-day session still fits when the transaction lands a little later.
const EXPIRY_MARGIN = 60
// Below this, one-click orders often won't fill while the price moves.
const LOW_SLIP_TICKS = 50

function parseEth(text: string, allowZero: boolean): bigint | null {
  try {
    const v = parseEther(text.trim() === '' ? '0' : text.trim())
    return v < 0n || (!allowZero && v === 0n) || v > UINT96_MAX ? null : v
  } catch {
    return null
  }
}

/** Percent text to ticks (1 tick is about 0.01%). Empty is not 0: the number must be typed. */
function parseSlip(text: string): number | null {
  const t = text.trim()
  if (t === '') return null
  const v = Number(t)
  if (!Number.isFinite(v) || v < 0) return null
  const ticks = Math.round(v * 100)
  return ticks <= MAX_SLIP_TICKS ? ticks : null
}

const ethText = (wei: bigint) => {
  const s = formatEther(wei)
  const [i, f = ''] = s.split('.')
  return f ? `${i}.${f.slice(0, 6).replace(/0+$/, '')}`.replace(/\.$/, '') : i
}

export function OneClickPanel({ oneClick, account, config, now, connected, busy }: Props) {
  const { status } = oneClick
  const head = (tag: ReactNode) => (
    <div className="section-head">
      <h2 id="h-oneclick">One-click trading</h2>
      {tag}
    </div>
  )

  if (!oneClick.supported) {
    return (
      <section className="panel section" aria-labelledby="h-oneclick">
        {head(<span className="tag">Not available</span>)}
        <p className="note">One-click trading is not deployed on this network yet. Every trade uses your wallet.</p>
      </section>
    )
  }
  if (!account) {
    return (
      <section className="panel section" aria-labelledby="h-oneclick">
        {head(<span className="tag">Off</span>)}
        <p className="note">Connect a wallet to set up one-click trading: approve this browser once, then trade without a wallet pop-up.</p>
      </section>
    )
  }

  const live = oneClick.local && (status.kind === 'live' || status.kind === 'paused' || status.kind === 'checking')
  return (
    <section className="panel section" aria-labelledby="h-oneclick">
      {head(
        status.kind === 'live' ? (
          <span className="tag tag-up">On in this browser</span>
        ) : status.kind === 'paused' ? (
          <span className="tag tag-warn">Paused</span>
        ) : status.kind === 'checking' ? (
          <span className="tag">Checking…</span>
        ) : (
          <span className="tag">Off</span>
        ),
      )}
      {oneClick.storageError && <p className="banner banner-error">{oneClick.storageError}</p>}
      {live && oneClick.notice && <p className="banner banner-info">{oneClick.notice}</p>}
      <Unrevoked oneClick={oneClick} connected={connected} busy={busy} />
      {!oneClick.loaded ? (
        <p className="note">Looking for a trading key in this browser…</p>
      ) : live ? (
        <SessionView oneClick={oneClick} account={account} now={now} connected={connected} busy={busy} />
      ) : (
        <Setup oneClick={oneClick} account={account} config={config} now={now} connected={connected} busy={busy} />
      )}
    </section>
  )
}

/** Keys this browser deleted without revoking them on-chain: they stay approved until they expire, so offer the
 *  wallet revoke here, whichever view is showing. */
function Unrevoked({ oneClick, connected, busy }: Pick<Props, 'oneClick' | 'connected' | 'busy'>) {
  const keys = oneClick.unrevoked
  if (keys.length === 0) return null
  const one = keys.length === 1
  return (
    <div className="banner banner-warn stack-tight">
      <p>
        {one ? 'A key this browser logged out of is' : `${keys.length} keys this browser logged out of are`} still approved
        on-chain until {one ? 'it expires' : 'they expire'}, so orders already signed with {one ? 'it' : 'them'} could still
        run. Revoke {one ? 'it' : 'them'} with your wallet to end {one ? 'it' : 'them'} now.
      </p>
      <div className="btn-row">
        {one && (
          <button type="button" className="btn btn-small" disabled={busy || !connected} onClick={() => oneClick.revoke(keys[0])}>
            Revoke it
          </button>
        )}
        <button type="button" className="btn btn-small" disabled={busy || !connected} onClick={() => oneClick.revokeAll()}>
          Revoke all sessions
        </button>
      </div>
    </div>
  )
}

function Explainer({ owner }: { owner: string }) {
  return (
    <ul className="facts">
      <li>This browser gets its own trading key. It can open and close positions within the limits you set here.</li>
      <li>
        It can withdraw only to your wallet, <span className="num">{shortAddress(owner)}</span>. It can never send your ETH
        anywhere else.
      </li>
      <li>The key can't be copied out of this browser. It stops working when it expires, when you log out, or when you revoke it.</li>
    </ul>
  )
}

function Setup({ oneClick, account, config, now, connected, busy }: Omit<Props, 'account'> & { account: Account }) {
  const [depText, setDepText] = useState('0.5')
  const [duration, setDuration] = useState(86_400)
  const [actions, setActions] = useState(DEFAULT_ACTIONS)
  const [maxLev, setMaxLev] = useState(10)
  const [openSlip, setOpenSlip] = useState('2')
  const [closeSlip, setCloseSlip] = useState('5')
  // null: follow the balance after the deposit.
  const [perTradeText, setPerTradeText] = useState<string | null>(null)
  const [openCapText, setOpenCapText] = useState<string | null>(null)
  const [dailyText, setDailyText] = useState<string | null>(null)

  const deposit = parseEth(depText, true)
  const after = account.exchangeBalance + (deposit ?? 0n)
  const auto = { perTrade: after / 4n, openCap: after, daily: after }
  const perTrade = perTradeText === null ? auto.perTrade : parseEth(perTradeText, true)
  const openCap = openCapText === null ? auto.openCap : parseEth(openCapText, true)
  const daily = dailyText === null ? auto.daily : parseEth(dailyText, true)
  const openSlipTicks = parseSlip(openSlip)
  const closeSlipTicks = parseSlip(closeSlip)
  const canOpen = (actions & ACT_OPEN) !== 0
  const canClose = (actions & (ACT_CLOSE_OWN | ACT_CLOSE_ANY)) !== 0

  const problem =
    deposit === null
      ? 'Enter a deposit in ETH (0 is fine).'
      : deposit > account.walletEth
        ? `Your wallet has ${fmtEth(account.walletEth)} ETH.`
        : actions === 0
          ? 'Pick at least one thing the key may do.'
          : openSlip.trim() === '' || closeSlip.trim() === ''
            ? 'Enter the open and close slippage in %, for example 2 and 5.'
            : openSlipTicks === null || closeSlipTicks === null
              ? 'Slippage must be between 0% and 30%.'
              : perTrade === null || openCap === null || daily === null
                ? 'Enter the stake limits in ETH.'
                : canOpen && daily === 0n
                  ? 'Deposit some ETH or set a daily budget above zero, so the key can open positions.'
                  : null
  const lowSlip =
    (canOpen && openSlipTicks !== null && openSlipTicks < LOW_SLIP_TICKS) ||
    (canClose && closeSlipTicks !== null && closeSlipTicks < LOW_SLIP_TICKS)
  const hint = problem
    ? null
    : canOpen && perTrade !== null && perTrade < config.minStake
      ? `The smallest stake allowed is ${fmtEth(config.minStake)} ETH, so raise the per-trade limit to open anything.`
      : lowSlip
        ? `Under ${bpsPct(LOW_SLIP_TICKS)} slippage, one-click orders often won't fill while the price moves, and then need your wallet.`
        : null

  async function enable() {
    if (problem || deposit === null || perTrade === null || openCap === null || daily === null) return
    const seconds = Math.min(duration, MAX_SESSION_SECONDS - EXPIRY_MARGIN)
    const limits: Limits = {
      expiry: BigInt(now + seconds),
      actions,
      maxLeverage: maxLev,
      openSlipTicks: openSlipTicks!,
      closeSlipTicks: closeSlipTicks!,
      maxStakePerTrade: perTrade,
      maxOpenStake: openCap,
      dailyBudget: daily,
    }
    await oneClick.authorize(deposit, limits)
  }

  const toggle = (bit: number) => setActions((a) => (a & bit ? a & ~bit : a | bit))
  const limitField = (id: string, label: string, text: string | null, autoValue: bigint, set: (v: string | null) => void) => (
    <div className="field">
      <label htmlFor={id}>{label}</label>
      <input
        id={id}
        className="input"
        inputMode="decimal"
        value={text ?? ethText(autoValue)}
        onChange={(e) => set(e.target.value)}
        aria-invalid={text !== null && parseEth(text, true) === null}
      />
    </div>
  )

  return (
    <>
      {oneClick.notice && <p className="banner banner-info">{oneClick.notice}</p>}
      <p>Approve this browser once and trade without a wallet pop-up for every order.</p>
      <Explainer owner={account.address} />

      <div className="field">
        <label htmlFor="oc-dep">Deposit to your trading balance (ETH)</label>
        <input id="oc-dep" className="input" inputMode="decimal" value={depText} onChange={(e) => setDepText(e.target.value)} aria-invalid={deposit === null} />
        <p className="note">
          Trading balance after this: <span className="num">{fmtEth(after)}</span> ETH. One-click trades are paid from it.
        </p>
      </div>

      <div className="field">
        <label id="oc-dur">Lasts for</label>
        <div className="seg" role="group" aria-labelledby="oc-dur">
          {DURATIONS.map((d) => (
            <button key={d.seconds} type="button" aria-pressed={duration === d.seconds} onClick={() => setDuration(d.seconds)}>
              {d.label}
            </button>
          ))}
        </div>
      </div>

      <dl className="kv">
        <div>
          <dt>This browser may</dt>
          <dd className="text">{actionsText(actions)}</dd>
        </div>
        <div>
          <dt>Leverage</dt>
          <dd>up to {maxLev}x</dd>
        </div>
        <div>
          <dt>Stake per trade</dt>
          <dd>{perTrade === null ? '–' : `up to ${fmtEth(perTrade)} ETH`}</dd>
        </div>
        <div>
          <dt>Open at once</dt>
          <dd>{openCap === null ? '–' : `up to ${fmtEth(openCap)} ETH`}</dd>
        </div>
        <div>
          <dt>Opened per day</dt>
          <dd>{daily === null ? '–' : `up to ${fmtEth(daily)} ETH`}</dd>
        </div>
        <div>
          <dt>Fills within</dt>
          <dd>
            {openSlipTicks === null ? '–' : bpsPct(openSlipTicks)} open, {closeSlipTicks === null ? '–' : bpsPct(closeSlipTicks)} close
            <span className="sub">of the 1-minute average price</span>
          </dd>
        </div>
      </dl>

      <details className="more">
        <summary>Change limits</summary>
        <div className="stack-tight">
          <fieldset className="checks">
            <legend>The key may</legend>
            {ACTIONS.map((a) => (
              <label key={a.bit} className="check">
                <input type="checkbox" checked={(actions & a.bit) !== 0} onChange={() => toggle(a.bit)} />
                {a.label}
              </label>
            ))}
          </fieldset>
          <div className="field">
            <label id="oc-lev">Max leverage</label>
            <div className="seg" role="group" aria-labelledby="oc-lev">
              {LEVERAGES.map((l) => (
                <button key={l} type="button" aria-pressed={maxLev === l} onClick={() => setMaxLev(l)}>
                  {l}x
                </button>
              ))}
            </div>
          </div>
          <div className="grid-fields">
            {limitField('oc-per', 'Per trade (ETH)', perTradeText, auto.perTrade, setPerTradeText)}
            {limitField('oc-open', 'Open at once (ETH)', openCapText, auto.openCap, setOpenCapText)}
            {limitField('oc-day', 'Per day (ETH)', dailyText, auto.daily, setDailyText)}
          </div>
          <div className="grid-fields">
            <div className="field">
              <label htmlFor="oc-os">Open slippage (%)</label>
              <input id="oc-os" className="input" inputMode="decimal" value={openSlip} onChange={(e) => setOpenSlip(e.target.value)} aria-invalid={openSlipTicks === null} />
            </div>
            <div className="field">
              <label htmlFor="oc-cs">Close slippage (%)</label>
              <input id="oc-cs" className="input" inputMode="decimal" value={closeSlip} onChange={(e) => setCloseSlip(e.target.value)} aria-invalid={closeSlipTicks === null} />
            </div>
          </div>
          <p className="note">
            Stake limits start at 25% of your balance after the deposit per trade, and the whole balance open at once and per
            day. The daily budget counts stakes and open fees and frees up over 24 hours, so it caps what a stolen key could lose in a day.{' '}
            {(perTradeText !== null || openCapText !== null || dailyText !== null) && (
              <button
                type="button"
                className="linkish"
                onClick={() => {
                  setPerTradeText(null)
                  setOpenCapText(null)
                  setDailyText(null)
                }}
              >
                Follow the balance again
              </button>
            )}
          </p>
        </div>
      </details>

      {problem && <p className="banner banner-warn">{problem}</p>}
      {hint && <p className="banner banner-warn">{hint}</p>}
      <button type="button" className="btn btn-primary btn-block" disabled={!connected || busy || problem !== null} onClick={enable}>
        {connected ? 'Turn on one-click trading' : 'Switch your wallet to this network first'}
      </button>
      <p className="note">
        One wallet transaction
        {deposit ? `: deposits ${fmtEth(deposit)} ETH and approves the key` : ': approves the key'}. After that, trades need no
        pop-up and no gas. Our relayer sends them, and the contract checks every one against these limits.
      </p>
      {oneClick.relayer && !oneClick.relayer.ok && (
        <p className="note">Right now {oneClick.relayer.reason} Until it is back, trades keep using your wallet.</p>
      )}
    </>
  )
}

function SessionView({ oneClick, account, now, connected, busy }: Omit<Props, 'account' | 'config'> & { account: Account }) {
  const st = oneClick.state
  const local = oneClick.local!
  const s = st?.session
  const l = s?.limits ?? local.limits
  const left = Number(l.expiry) - now
  const used = s ? spentToday(s, now) : 0n
  const pct = l.dailyBudget > 0n ? Math.min(100, Number((used * 10_000n) / l.dailyBudget) / 100) : 0
  const relayerDown = oneClick.relayer && !oneClick.relayer.ok
  const paused = oneClick.status.kind === 'paused'
  const ends = new Date(Number(l.expiry) * 1000)

  return (
    <>
      {paused && (
        <p className="banner banner-warn">One-click trading is paused for everyone right now. Your wallet still works.</p>
      )}
      {relayerDown && oneClick.status.kind === 'live' && (
        <p className="banner banner-warn">
          One-click is on hold: {oneClick.relayer!.ok ? '' : oneClick.relayer!.reason} Trades use your wallet until it is back.
        </p>
      )}
      <p>
        Trades from this browser are signed by its own key and sent without a wallet pop-up. Withdrawals can only go to{' '}
        <span className="num">{shortAddress(account.address)}</span>.
      </p>
      <div className="stats stats-2">
        <div className="stat">
          <span className="label">Ends in</span>
          <span className="value">{fmtDuration(left)}</span>
          <span className="hint">
            {ends.toLocaleString(undefined, { weekday: 'short', hour: '2-digit', minute: '2-digit' })}
          </span>
        </div>
        <div className="stat">
          <span className="label">Daily budget in use</span>
          <span className="value">
            {fmtEth(used)} <span className="muted">/ {fmtEth(l.dailyBudget)}</span>
          </span>
          <span className="meter" role="meter" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(pct)} aria-label="Daily budget in use">
            <span className={pct >= 80 ? 'hot' : ''} style={{ width: `${pct}%` }} />
          </span>
          <span className="hint">
            {!s ? 'ETH of stake and fees opened' : used === 0n ? 'All free' : `Frees up over time, all free in ${fmtDuration(budgetFreeIn(s, now))}`}
          </span>
        </div>
      </div>
      <dl className="kv">
        <div>
          <dt>This browser may</dt>
          <dd className="text">{actionsText(l.actions)}</dd>
        </div>
        <div>
          <dt>Leverage</dt>
          <dd>up to {l.maxLeverage}x</dd>
        </div>
        <div>
          <dt>Stake per trade</dt>
          <dd>up to {fmtEth(l.maxStakePerTrade)} ETH</dd>
        </div>
        <div>
          <dt>Open now</dt>
          <dd>
            {st ? fmtEth(st.openStake) : '–'} of {fmtEth(l.maxOpenStake)} ETH
          </dd>
        </div>
        <div>
          <dt>Fills within</dt>
          <dd>
            {bpsPct(l.openSlipTicks)} open, {bpsPct(l.closeSlipTicks)} close
            <span className="sub">of the 1-minute average price</span>
          </dd>
        </div>
      </dl>
      <div className="btn-row">
        <button type="button" className="btn" disabled={busy} onClick={() => oneClick.logout()}>
          Log out on this device
        </button>
        <button type="button" className="btn" disabled={busy || !connected} onClick={() => oneClick.revoke()}>
          Revoke
        </button>
        <button type="button" className="btn" disabled={busy || !connected} onClick={() => oneClick.revokeAll()}>
          Revoke all sessions
        </button>
      </div>
      <p className="note">
        {paused || relayerDown
          ? `Log out deletes the key from this browser, but while ${paused ? 'one-click is paused' : 'the relayer is down'} it can't revoke it on-chain, so it stays approved until it expires. Revoke ends it with a wallet transaction.`
          : 'Log out deletes the key from this browser and revokes it with no pop-up. Revoke does the same with a wallet transaction.'}{' '}
        Revoke all also ends one-click on your other devices and cancels any order still waiting.
      </p>
    </>
  )
}

const STAGE_TAG: Record<IntentProgress['stage'], string> = {
  signing: 'tag-accent',
  sending: 'tag-accent',
  queued: 'tag-accent',
  retrying: 'tag-warn',
  sent: 'tag-accent',
  confirmed: 'tag-up',
  failed: 'tag-down',
  expired: 'tag-warn',
}

/** Progress of the one-click order in flight. */
export function IntentToast({ progress, onDismiss }: { progress: IntentProgress; onDismiss: () => void }) {
  const done = isFinal(progress.stage)
  const cls = progress.stage === 'confirmed' ? 'banner-ok' : progress.stage === 'failed' ? 'banner-error' : progress.stage === 'expired' ? 'banner-warn' : 'banner-info'
  return (
    <div className={`toast banner ${cls}`} role="status" aria-live="polite">
      <span className="toast-body">
        <span className="toast-title">
          <b>{progress.label}</b> <span className={`tag ${STAGE_TAG[progress.stage]}`}>No wallet pop-up</span>
        </span>
        <span>
          {progress.text}
          {progress.txHash && <span className="num muted"> {shortAddress(progress.txHash)}</span>}
        </span>
      </span>
      {done && (
        <button type="button" onClick={onDismiss} aria-label="Dismiss">
          Dismiss
        </button>
      )}
    </div>
  )
}
