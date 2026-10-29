import type { Config, MarketRow } from '../lib/types'
import { fmtEth, fmtPct, fmtTick, tickRatio, tone } from '../lib/format'

type Props = {
  markets: MarketRow[]
  config: Config
  selected: number
  onSelect: (id: number) => void
}

export function crowdedSide(m: MarketRow): 'long' | 'short' | null {
  if (m.view.longSize > m.view.shortSize) return 'long'
  if (m.view.shortSize > m.view.longSize) return 'short'
  return null
}

function status(m: MarketRow): { text: string; cls: string } | null {
  const r = m.long.reason
  if (r === 3) return { text: 'Feed down', cls: 'tag-warn' }
  if (r === 2) return { text: 'Locked after rug', cls: 'tag-warn' }
  if (r === 1) return { text: 'Paused', cls: 'tag-warn' }
  if (r === 4) return { text: 'Low liquidity', cls: 'tag-warn' }
  return null
}

export function Markets({ markets, config, selected, onSelect }: Props) {
  const mult = config.crowdMultBps / 10_000
  return (
    <section className="panel section" aria-labelledby="h-markets">
      <div className="section-head">
        <h2 id="h-markets">Markets</h2>
        <p className="note">Curated coins. Prices in ETH, read from each coin's Uniswap pool.</p>
      </div>
      <div className="table-scroll">
        <table>
          <thead>
            <tr>
              <th>Coin</th>
              <th className="n">Price</th>
              <th className="n">vs 30 min</th>
              <th className="n">Liquidity</th>
              <th className="n">Max lev.</th>
              <th className="n">Open long / short</th>
              <th>Crowded side</th>
              <th className="n">Room long / short</th>
            </tr>
          </thead>
          <tbody>
            {markets.map((m) => {
              const change = tickRatio(m.long.spotTick - m.long.slowTick) - 1
              const crowd = crowdedSide(m)
              const st = status(m)
              return (
                <tr
                  key={m.meta.id}
                  className="pick"
                  aria-selected={m.meta.id === selected}
                  tabIndex={0}
                  onClick={() => onSelect(m.meta.id)}
                  onKeyDown={(e) => (e.key === 'Enter' || e.key === ' ') && onSelect(m.meta.id)}
                >
                  <td>
                    <div className="coin">
                      <b>{m.meta.symbol}</b>
                      <span>
                        {m.meta.name} {st && <span className={`tag ${st.cls}`}>{st.text}</span>}
                      </span>
                    </div>
                  </td>
                  <td className="n num">{m.long.reason === 3 ? '–' : fmtTick(m.long.spotTick, m.decimals)}</td>
                  <td className={`n num ${tone(Math.round(change * 1000))}`}>{m.long.reason === 3 ? '–' : fmtPct(change)}</td>
                  <td className="n num">{fmtEth(m.long.liquidityEth, 1)} ETH</td>
                  <td className="n num">
                    {m.long.maxLeverage}x / {m.short.maxLeverage}x
                  </td>
                  <td className="n num">
                    {fmtEth(m.view.longSize, 2)} / {fmtEth(m.view.shortSize, 2)}
                  </td>
                  <td>
                    {crowd ? (
                      <span className="tag tag-accent">
                        {crowd === 'long' ? 'Longs' : 'Shorts'} pay {mult}×
                      </span>
                    ) : (
                      <span className="muted">Even</span>
                    )}
                  </td>
                  <td className="n num">
                    {fmtEth(m.long.netRoom, 2)} / {fmtEth(m.short.netRoom, 2)}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      <p className="note">
        Room is how much more position size (ETH) each side can add on that coin. The side with more open size pays{' '}
        {mult}× the holding fee.
      </p>
    </section>
  )
}
