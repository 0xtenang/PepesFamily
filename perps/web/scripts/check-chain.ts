// Loads everything the app reads, from the configured chain, and prints a short summary.
// npm run check:chain   (VITE_NETWORK and VITE_RPC_URL work here too)
import { deployment } from '../src/config'
import { readSnapshot } from '../src/lib/reads'
import { fmtEth, fmtPct, fmtTick, tickRatio } from '../src/lib/format'

const account = (process.argv[2] as `0x${string}` | undefined) ?? deployment.deployer ?? null
const s = await readSnapshot(account)
console.log(`chain ${deployment.chainId} at ${deployment.rpcUrl}, block time ${s.now}`)
console.log(`pool: NAV ${fmtEth(s.pool.nav)} ETH, cash ${fmtEth(s.pool.cash)}, creator fees ${fmtEth(s.pool.totalDonated)}, free ${fmtEth(s.pool.freeCash)}`)
for (const m of s.markets) {
  const change = tickRatio(m.long.spotTick - m.long.slowTick) - 1
  console.log(
    `${m.meta.symbol.padEnd(6)} price ${fmtTick(m.long.spotTick, m.decimals).padEnd(10)} vs 30 min ${fmtPct(change).padEnd(7)} ` +
      `liquidity ${fmtEth(m.long.liquidityEth, 1)} ETH  max lev long ${m.long.maxLeverage}x short ${m.short.maxLeverage}x  ` +
      `room long ${fmtEth(m.long.netRoom, 2)} short ${fmtEth(m.short.netRoom, 2)}  reason ${m.long.reason}/${m.short.reason}  decimals ${m.decimals}`,
  )
}
console.log(`pool withdrawals: cooldown ${s.pool.withdrawCooldown} s, then a window of ${s.pool.withdrawWindow} s`)
console.log(`config: pool fee share ${s.config.poolFeeShareBps} bps, crowd ${s.config.crowdMultBps} bps, short max win ${s.config.shortMaxWinBps} bps`)
if (s.account) {
  const a = s.account
  console.log(`account ${a.address}: LP shares ${fmtEth(a.lpShares)}, worth ${fmtEth(a.lpValue)} ETH, positions ${a.positions.length}`)
  const r = a.request
  if (r.shares > 0n) {
    console.log(
      `  withdrawal request: ${fmtEth(r.shares)} shares, ${fmtEth(r.assets)} ETH at request, worth ${fmtEth(r.valueNow)} now, ` +
        `pays ${fmtEth(r.payout)}; unlocks at ${r.unlockAt} (in ${Number(r.unlockAt - s.now)} s), window ends at ${r.unlockAt + s.pool.withdrawWindow}`,
    )
  }
}
