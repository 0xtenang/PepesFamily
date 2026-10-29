import type { Address, Hex } from 'viem'
import type { MarketMeta } from '../config'

// Shapes returned by viem for the LevExchange / LevLens / LevPool structs (uint<=48 come back as number, wider as bigint).

export type Config = {
  openFeeStakeBps: number
  openFeeSizeBps: number
  profitFeeBps: number
  poolFeeShareBps: number
  holdRateBpsPerHour: number
  crowdMultBps: number
  freeHoldSeconds: number
  liqEquityBps: number
  keeperRewardBps: number
  longMaxWinBps: number
  longMaxWinBps2: number
  longMaxWinBps3: number
  maxWinTier2Cash: bigint
  maxWinTier3Cash: bigint
  shortMaxWinBps: number
  maxShortLeverage: number
  lev5LiquidityEth: bigint
  lev10LiquidityEth: bigint
  minLiquidityEth: bigint
  netCapLiquidityBps: number
  coverageBps: number
  rugDropBps: number
  rugCapBps: number
  rugLockSeconds: number
  minHoldSeconds: number
  staleSeconds: number
  hourlyLossBreakerBps: number
  minStake: bigint
}

export type MarketView = {
  oracle: Address
  active: boolean
  maxLeverage: number
  netCapEth: bigint
  refTick: number
  lastGoodTick: number
  lastGoodAt: bigint
  downSince: bigint
  rugEpoch: number
  rugAt: bigint
  longSize: bigint
  shortSize: bigint
  longStake: bigint
  shortStake: bigint
  longMaxWin: bigint
  shortMaxWin: bigint
}

export type Quote = {
  reason: number
  spotTick: number
  fastTick: number
  slowTick: number
  entryTick: number
  liquidityEth: bigint
  maxLeverage: number
  fee: bigint
  maxWinBps: number
  netRoom: bigint
  poolRoomStake: bigint
}

export type Position = {
  owner: Address
  marketId: number
  rugEpoch: number
  openedAt: bigint
  isLong: boolean
  leverage: number
  entryTick: number
  maxWinBps: number
  stake: bigint
  feeIndex: bigint
}

export type PositionView = {
  position: Position
  size: bigint
  markTick: number
  pnl: bigint
  holdFee: bigint
  equity: bigint
  action: number
}

export type MarketRow = {
  meta: MarketMeta
  decimals: number // the coin's ERC-20 decimals, for turning ticks into ETH prices
  view: MarketView
  long: Quote
  short: Quote
}

export type PoolState = {
  nav: bigint
  cash: bigint
  sharePrice: bigint
  totalDonated: bigint
  freeCash: bigint
  totalSupply: bigint
  totalMaxWin: bigint
  withdrawCooldown: bigint
  withdrawWindow: bigint // after the cooldown, a request must be used within this, or cancelled and redone
}

export type Account = {
  address: Address
  walletEth: bigint
  exchangeBalance: bigint
  lpShares: bigint
  lpValue: bigint
  // assets: value when requested. payout: what withdraw() pays now, the lower of that and the shares' value now.
  request: { shares: bigint; assets: bigint; unlockAt: bigint; valueNow: bigint; payout: bigint }
  positions: (PositionView & { id: bigint; openedBy: Hex })[] // openedBy: session key that opened it, or zero
}

export type Snapshot = {
  now: bigint
  config: Config
  markets: MarketRow[]
  pool: PoolState
  account: Account | null
}
