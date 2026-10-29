import { formatEther } from 'viem'

const SUBSCRIPT = '₀₁₂₃₄₅₆₇₈₉'

/** 1.0001^tick. Only for ratios between two ticks (a change, a distance); for a price use tickToPrice. */
export function tickRatio(tick: number): number {
  return Math.pow(1.0001, tick)
}

/** ETH per whole coin. The oracle's tick is WETH base units per coin base unit, so a coin with fewer than 18
 *  decimals needs scaling: 1.0001^tick × 10^(decimals − 18). */
export function tickToPrice(tick: number, decimals: number): number {
  return tickRatio(tick) * Math.pow(10, decimals - 18)
}

/** Memecoin prices in ETH are tiny. The subscript counts the zeros after the decimal point: 0.0000000123 reads as 0.0₇123. */
export function fmtPrice(p: number): string {
  if (!Number.isFinite(p) || p <= 0) return '0'
  if (p >= 1) return p.toLocaleString('en-US', { maximumSignificantDigits: 6 })
  if (p >= 0.001) return p.toPrecision(4)
  // toExponential rounds first, so 9.9996e-8 becomes 1.00e-7 and powers of ten keep three digits.
  const [mantissa, exponent] = p.toExponential(2).split('e')
  const zeros = -Number(exponent) - 1
  const digits = mantissa.replace('.', '')
  const sub = String(zeros)
    .split('')
    .map((d) => SUBSCRIPT[Number(d)])
    .join('')
  return `0.0${sub}${digits}`
}

export function fmtTick(tick: number, decimals: number): string {
  return fmtPrice(tickToPrice(tick, decimals))
}

export function ethNumber(wei: bigint): number {
  return Number(formatEther(wei))
}

export function fmtEth(wei: bigint, digits = 4): string {
  const n = ethNumber(wei)
  return n.toLocaleString('en-US', { maximumFractionDigits: digits, minimumFractionDigits: n === 0 ? 0 : Math.min(2, digits) })
}

export function fmtSignedEth(wei: bigint, digits = 4): string {
  const sign = wei > 0n ? '+' : wei < 0n ? '−' : ''
  return sign + fmtEth(wei < 0n ? -wei : wei, digits)
}

export function fmtPct(x: number, digits = 1): string {
  const sign = x > 0 ? '+' : x < 0 ? '−' : ''
  return `${sign}${Math.abs(x * 100).toFixed(digits)}%`
}

export function bpsPct(bps: number): string {
  const v = bps / 100
  return `${Number.isInteger(v) ? v : v.toFixed(2)}%`
}

export function fmtDuration(seconds: number): string {
  if (seconds <= 0) return 'now'
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  const s = Math.floor(seconds % 60)
  if (h > 0) return `${h} h ${m} min`
  if (m > 0) return `${m} min ${s} s`
  return `${s} s`
}

export function shortAddress(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`
}

/** Coin price at which a position is liquidated (ignores holding fees, which bring it a little closer). */
export function liquidationRatio(isLong: boolean, leverage: number, liqEquityBps: number): number {
  const loss = 1 - liqEquityBps / 10_000
  return isLong ? 1 - loss / leverage : 1 + loss / leverage
}

/** Coin price at which a position reaches its max win, or null when it can't (a short would need a price below zero). */
export function maxWinRatio(isLong: boolean, leverage: number, maxWinBps: number): number | null {
  const win = maxWinBps / 10_000
  const r = isLong ? 1 + win / leverage : 1 - win / leverage
  return r > 0 ? r : null
}

export function tone(x: bigint | number): string {
  return x > 0 ? 'up' : x < 0 ? 'down' : ''
}
