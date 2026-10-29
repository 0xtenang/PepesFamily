import type { ReactNode } from 'react'
import type { Config } from '../lib/types'
import { bpsPct, fmtEth } from '../lib/format'
import { deployment } from '../config'

type Rule = { name: string; better?: boolean; what: ReactNode }

const N = ({ children }: { children: ReactNode }) => <span className="num">{children}</span>

export function Rules({ config: c }: { config: Config }) {
  const mins = (s: number) => `${Math.round(s / 60)} minutes`
  const rules: Rule[] = [
    {
      name: 'Open and close fees',
      what: (
        <>
          <N>{bpsPct(c.openFeeStakeBps)}</N> of the stake or <N>{bpsPct(c.openFeeSizeBps)}</N> of position size, whichever is
          more, each way. Winners also pay <N>{bpsPct(c.profitFeeBps)}</N> of their profit.
        </>
      ),
    },
    {
      name: 'More fees to the pool',
      better: true,
      what: (
        <>
          <N>{bpsPct(c.poolFeeShareBps)}</N> of every trading fee goes to the pool (Inverse gives its pool 20%). The contract
          won't let this drop below 20%.
        </>
      ),
    },
    {
      name: 'Holding fee',
      what: (
        <>
          <N>{bpsPct(c.holdRateBpsPerHour)}</N> of position size per hour after the first{' '}
          <N>{Math.round(c.freeHoldSeconds / 3600)}</N> hour, all of it to the pool.
        </>
      ),
    },
    {
      name: 'Crowded side pays more',
      better: true,
      what: (
        <>
          On each coin, the side with more open size pays <N>{c.crowdMultBps / 10_000}×</N> the holding fee. Lopsided bets
          cost more to hold.
        </>
      ),
    },
    {
      name: 'Shorts treated differently',
      better: true,
      what: (
        <>
          A short wins at most <N>+{bpsPct(c.shortMaxWinBps)}</N> and uses at most <N>{c.maxShortLeverage}x</N>, because most
          memecoins drift down.
        </>
      ),
    },
    {
      name: 'Max win on longs',
      what: (
        <>
          <N>+{bpsPct(c.longMaxWinBps)}</N>, rising to <N>+{bpsPct(c.longMaxWinBps2)}</N> once the pool holds{' '}
          <N>{fmtEth(c.maxWinTier2Cash, 1)} ETH</N> and <N>+{bpsPct(c.longMaxWinBps3)}</N> from{' '}
          <N>{fmtEth(c.maxWinTier3Cash, 1)} ETH</N>. A position closes on its own at the max win.
        </>
      ),
    },
    {
      name: 'Leverage by liquidity',
      what: (
        <>
          10x needs <N>{fmtEth(c.lev10LiquidityEth, 1)} ETH</N> in the coin's pool, 5x needs{' '}
          <N>{fmtEth(c.lev5LiquidityEth, 1)} ETH</N>, otherwise 2x. Below <N>{fmtEth(c.minLiquidityEth, 1)} ETH</N> a coin
          takes no new positions.
        </>
      ),
    },
    {
      name: 'Room per coin',
      what: (
        <>
          The difference between long and short size on one coin stays under{' '}
          <N>{bpsPct(c.netCapLiquidityBps)}</N> of its ETH liquidity and the curator's cap. Trades that even it out are
          always allowed.
        </>
      ),
    },
    {
      name: 'Every winner can be paid',
      what: (
        <>
          New positions are refused once all open max wins together would need more than{' '}
          <N>{bpsPct(c.coverageBps)}</N> of the pool's cash.
        </>
      ),
    },
    {
      name: 'Liquidation',
      what: (
        <>
          A position is liquidated when its equity falls to <N>{bpsPct(c.liqEquityBps)}</N> of the stake. The trader loses
          the stake and never owes more; <N>{bpsPct(c.keeperRewardBps)}</N> of what is left pays whoever liquidates it.
        </>
      ),
    },
    {
      name: 'Rug guard',
      what: (
        <>
          If a coin's 1-minute price falls <N>{bpsPct(c.rugDropBps)}</N> under its 30-minute price, shorts settle with at
          most <N>+{bpsPct(c.rugCapBps)}</N> and the coin takes no new positions for {mins(c.rugLockSeconds)}. Longs keep
          running.
        </>
      ),
    },
    {
      name: 'Loss breaker',
      what: (
        <>
          New positions pause for the rest of the hour if the pool's cash falls{' '}
          <N>{bpsPct(c.hourlyLossBreakerBps)}</N> within that hour. Closing always works.
        </>
      ),
    },
    {
      name: 'Price feed down',
      what: (
        <>
          Once a coin's feed has been reported down for {mins(c.staleSeconds)}, positions close at its last good price.
          Nothing gets stuck.
        </>
      ),
    },
    {
      name: 'Minimums',
      what: (
        <>
          Stake of at least <N>{fmtEth(c.minStake, 4)} ETH</N>. A position can close <N>{c.minHoldSeconds}</N> seconds after it
          opens.
        </>
      ),
    },
    {
      name: 'Everything on-chain',
      better: true,
      what: (
        <>
          Positions, prices, P&amp;L and the pool's books all live in the contracts, with no off-chain engine signing
          withdrawals. Exchange <N>{deployment.exchange}</N>, pool <N>{deployment.pool}</N>.
        </>
      ),
    },
  ]

  return (
    <section className="panel section" aria-labelledby="h-rules">
      <div className="section-head">
        <h2 id="h-rules">Rules</h2>
        <p className="note">Read live from the contract. Tags mark where these rules improve on Inverse.</p>
      </div>
      <div className="rules">
        {rules.map((r) => (
          <div className="rule" key={r.name}>
            <div className="name">
              {r.name}
              {r.better && <span className="tag tag-accent">Better than Inverse</span>}
            </div>
            <p className="what">{r.what}</p>
          </div>
        ))}
      </div>
    </section>
  )
}
