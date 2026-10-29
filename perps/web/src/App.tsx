import { useCallback, useEffect, useState } from 'react'
import { chain } from './lib/chain'
import { deployment, NETWORK } from './config'
import { useChainClock, useSnapshot, useTx } from './lib/hooks'
import { canUseLocalWallet, connectInjected, connectLocal, ensureChain, hasInjected, walletChainId, type Wallet } from './lib/wallet'
import { explainError } from './lib/errors'
import { fmtEth, shortAddress } from './lib/format'
import { Markets } from './components/Markets'
import { TradePanel } from './components/TradePanel'
import { Balance, Positions } from './components/Positions'
import { Pool } from './components/Pool'
import { Rules } from './components/Rules'
import { IntentToast, OneClickPanel } from './components/OneClick'
import { useOneClick } from './lib/oneclick'

type Tab = 'trade' | 'positions' | 'pool' | 'rules'
const TABS: { id: Tab; label: string }[] = [
  { id: 'trade', label: 'Trade' },
  { id: 'positions', label: 'Positions' },
  { id: 'pool', label: 'Pool' },
  { id: 'rules', label: 'Rules' },
]

const WALLET_KEY = 'memelev.wallet'

function remember(kind: Wallet['kind'] | null) {
  try {
    if (kind) localStorage.setItem(WALLET_KEY, kind)
    else localStorage.removeItem(WALLET_KEY)
  } catch {
    // Storage can be blocked; reconnecting by hand still works.
  }
}

function recall(): string | null {
  try {
    return localStorage.getItem(WALLET_KEY)
  } catch {
    return null
  }
}

function initialTab(): Tab {
  const h = window.location.hash.replace('#', '')
  return (TABS.find((t) => t.id === h)?.id ?? 'trade') as Tab
}

export function App() {
  const [wallet, setWallet] = useState<Wallet | null>(null)
  const [wrongChain, setWrongChain] = useState(false)
  const [walletError, setWalletError] = useState<string | null>(null)
  const [tab, setTab] = useState<Tab>(initialTab)
  const [selected, setSelected] = useState(0)

  const { snap, error, refresh, fetchedAt } = useSnapshot(wallet?.address ?? null)
  const now = useChainClock(snap?.now, fetchedAt)
  const onDone = useCallback(() => void refresh(), [refresh])
  const { tx, run, busy: walletBusy, clear } = useTx(wallet, onDone)
  const oneClick = useOneClick(wallet?.address ?? null, now, run, onDone)
  // One thing at a time: a wallet transaction or a one-click order.
  const busy = walletBusy || oneClick.busy
  const connected = !!wallet && !wrongChain

  useEffect(() => {
    if (window.location.hash !== `#${tab}`) window.location.hash = tab
  }, [tab])

  useEffect(() => {
    const onHash = () => setTab(initialTab())
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

  // Follow account and network changes in a browser wallet.
  useEffect(() => {
    const eth = window.ethereum
    if (!eth || wallet?.kind !== 'injected') return
    const onAccounts = (accounts: unknown) => {
      const list = accounts as `0x${string}`[]
      if (list.length === 0) setWallet(null)
      else setWallet({ ...wallet, address: list[0], account: list[0] })
    }
    const onChain = (id: unknown) => setWrongChain(Number(id) !== chain.id)
    eth.on('accountsChanged', onAccounts)
    eth.on('chainChanged', onChain)
    walletChainId(wallet).then((id) => setWrongChain(id !== chain.id))
    return () => {
      eth.removeListener('accountsChanged', onAccounts)
      eth.removeListener('chainChanged', onChain)
    }
  }, [wallet])

  async function connect(kind: 'injected' | 'local') {
    setWalletError(null)
    try {
      setWallet(kind === 'local' ? connectLocal() : await connectInjected())
      remember(kind)
    } catch (e) {
      setWalletError(explainError(e))
    }
  }

  function disconnect() {
    setWallet(null)
    remember(null)
  }

  // Reconnect the wallet used last time, without prompting.
  useEffect(() => {
    const last = recall()
    if (last === 'local' && canUseLocalWallet) setWallet(connectLocal())
    if (last === 'injected' && window.ethereum) {
      window.ethereum
        .request({ method: 'eth_accounts' })
        .then(async (accounts) => {
          if ((accounts as string[]).length > 0) setWallet(await connectInjected())
        })
        .catch(() => {})
    }
  }, [])

  async function switchNetwork() {
    if (!wallet) return
    try {
      await ensureChain(wallet.client)
      setWrongChain(false)
    } catch (e) {
      setWalletError(explainError(e))
    }
  }

  const market = snap?.markets.find((m) => m.meta.id === selected) ?? snap?.markets[0]
  const positionCount = snap?.account?.positions.length ?? 0
  const notDeployed = deployment.exchange === '0x0000000000000000000000000000000000000000'

  return (
    <div className="wrap">
      <header className="top">
        <div className="brand">
          <h1>MemeLev</h1>
          <span className="net">
            <span className={`dot ${error ? 'off' : ''}`} aria-hidden="true" />
            {chain.name}
            {NETWORK !== 'local' && NETWORK !== 'robinhood' ? ` (${NETWORK})` : ''}
          </span>
        </div>
        <div className="wallet">
          {wallet ? (
            <>
              <span className="pill">
                <span className="num">{shortAddress(wallet.address)}</span>
                <span className="kind">{wallet.kind === 'local' ? 'Local test wallet' : 'Browser wallet'}</span>
              </span>
              {snap?.account && <span className="pill num">{fmtEth(snap.account.exchangeBalance, 4)} ETH to trade</span>}
              {oneClick.ready && (
                <button type="button" className="pill pill-button" onClick={() => setTab('positions')} title="One-click trading is on in this browser">
                  <span className="dot" aria-hidden="true" />
                  One-click on
                </button>
              )}
              {wrongChain && (
                <button type="button" className="btn btn-primary" onClick={switchNetwork}>
                  Switch to {chain.name}
                </button>
              )}
              <button type="button" className="btn" onClick={disconnect}>
                Disconnect
              </button>
            </>
          ) : (
            <>
              <button type="button" className="btn btn-primary" onClick={() => connect('injected')} disabled={!hasInjected()}>
                Connect wallet
              </button>
              {canUseLocalWallet && (
                <button type="button" className="btn" onClick={() => connect('local')}>
                  Use local test wallet
                </button>
              )}
            </>
          )}
        </div>
      </header>

      <nav className="tabs" role="tablist" aria-label="Sections">
        {TABS.map((t) => (
          <button key={t.id} type="button" role="tab" className="tab" aria-selected={tab === t.id} onClick={() => setTab(t.id)}>
            {t.label}
            {t.id === 'positions' && positionCount > 0 && <span className="count">{positionCount}</span>}
          </button>
        ))}
      </nav>

      <div className="stack">
        {walletError && <p className="banner banner-error">{walletError}</p>}
        {!wallet && !hasInjected() && !canUseLocalWallet && (
          <p className="banner banner-info">No browser wallet found. Install one to trade.</p>
        )}
        {notDeployed && (
          <p className="banner banner-warn">
            The contracts are not deployed on {chain.name} yet. Fill in src/config/robinhood.example.json after deploying.
          </p>
        )}
        {error && (
          <p className="banner banner-error">
            Can't read the chain at {deployment.rpcUrl}: {error}
          </p>
        )}

        {!snap ? (
          !error && <p className="note">Loading markets…</p>
        ) : (
          <>
            {tab === 'trade' && (
              <div className="grid-trade">
                <Markets markets={snap.markets} config={snap.config} selected={market?.meta.id ?? 0} onSelect={setSelected} />
                {market ? (
                  <TradePanel
                    market={market}
                    config={snap.config}
                    balance={snap.account?.exchangeBalance ?? null}
                    chainNow={snap.now}
                    connected={connected}
                    busy={busy}
                    run={run}
                    oneClick={oneClick}
                    onSetupOneClick={() => setTab('positions')}
                  />
                ) : (
                  <p className="note">No coins are listed yet.</p>
                )}
              </div>
            )}
            {tab === 'positions' && (
              <div className="stack">
                <Positions
                  account={snap.account}
                  markets={snap.markets}
                  config={snap.config}
                  now={now}
                  busy={busy}
                  walletBusy={walletBusy}
                  connected={connected}
                  run={run}
                  oneClick={oneClick}
                />
                <div className="two">
                  <Balance account={snap.account} connected={connected} busy={busy} run={run} oneClick={oneClick} />
                  <OneClickPanel
                    oneClick={oneClick}
                    account={snap.account}
                    config={snap.config}
                    now={now}
                    connected={connected}
                    busy={busy}
                  />
                </div>
              </div>
            )}
            {tab === 'pool' && <Pool pool={snap.pool} config={snap.config} account={snap.account} now={now} busy={busy} run={run} />}
            {tab === 'rules' && <Rules config={snap.config} />}
          </>
        )}
      </div>

      {(tx || oneClick.progress) && (
        <div className="toasts">
          {tx && (
            <div
              className={`toast banner ${tx.status === 'error' ? 'banner-error' : tx.status === 'done' ? 'banner-ok' : 'banner-info'}`}
              role="status"
              aria-live="polite"
            >
              <span>
                {tx.status === 'pending' && `${tx.label}…`}
                {tx.status === 'done' && `${tx.label}: confirmed.`}
                {tx.status === 'error' && `${tx.label} failed. ${tx.message ?? ''}`}
              </span>
              {tx.status !== 'pending' && (
                <button type="button" onClick={clear} aria-label="Dismiss">
                  Dismiss
                </button>
              )}
            </div>
          )}
          {oneClick.progress && <IntentToast progress={oneClick.progress} onDismiss={oneClick.clearProgress} />}
        </div>
      )}
    </div>
  )
}
