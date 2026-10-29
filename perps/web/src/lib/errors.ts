import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from 'viem'

const MESSAGES: Record<string, string> = {
  MarketClosed: 'This coin is not taking new positions right now.',
  MarketLocked: 'This coin is locked for an hour after its rug guard fired.',
  StakeTooSmall: 'The stake is below the minimum.',
  LeverageNotAllowed: 'That leverage is not allowed for this coin and side.',
  PriceMoved: 'The price moved more than about 1% before your order landed. Try again.',
  CoinFull: 'This coin has no room left on this side. Try a smaller size or the other side.',
  PoolFull: 'The pool cannot cover more max wins right now. Try a smaller stake.',
  InsufficientBalance: 'Your trading balance is too low.',
  NotPositionOwner: 'Only the owner of this position can close it.',
  NotOpen: 'That position is already closed.',
  TooSoon: 'A position can be closed 10 seconds after it opens.',
  OracleDown:
    "This coin's price feed is down. Once it has been reported down for 10 minutes, positions close at the last good price.",
  NotLiquidatable: 'This position is not at the liquidation level.',
  NotAtMaxWin: 'This position has not reached its max win.',
  NoRug: 'The price has not crashed far enough for the rug guard.',
  NotRugged: 'This position was not open when the rug guard fired.',
  BreakerTripped: 'New positions are paused until the hour is up, because the pool lost too much this hour.',
  LiquidityTooLow: "This coin's pool has too little ETH for new positions.",
  TransferFailed: 'The ETH transfer failed.',
  DepositTooSmall: 'The deposit is below the minimum.',
  NoRequest: 'You have no withdrawal request.',
  StillLocked: 'Your withdrawal is still in its cooldown.',
  RequestExpired:
    'Your withdrawal request expired: its window to withdraw has closed. Cancel it to get your shares back, then request again.',
  BadValue: 'That amount is not allowed. It must be above zero.',
  NotEnoughFreeCash: 'The pool needs that cash to cover open max wins. Try a smaller amount later.',
  PoolEmpty: 'The pool has no value left to deposit against.',
  ERC20InsufficientBalance: 'You do not have that many LP shares.',
  Unauthorized: 'This account is not allowed to do that.',
  // LevRouter (one-click trading)
  Paused: 'One-click trading is paused for everyone right now. Your wallet still works.',
  BadLimits: 'Those one-click limits are not allowed. Check the expiry (at most 7 days), leverage (at most 10x) and slippage (at most 30%).',
  BadKey: "This browser's trading key was not accepted. Try again.",
  BadDeadline: 'The signed order arrived too late. Nothing was traded; try again.',
  SessionInvalid: 'Your one-click session has ended (expired or revoked). Set it up again.',
  NotAllowed: 'Your one-click session is not allowed to do that.',
  NonceUsed: 'That order was already sent once.',
  BadSignature: "The order's signature did not match this browser's trading key.",
  OverLimit: 'That is over your one-click limits.',
  // Relayer
  Reverted: 'The order kept failing on-chain, so the relayer gave up. Nothing was traded; try again.',
  NotIncluded: 'The order was not included in a block before its deadline. Nothing was traded; try again.',
  RpcUnavailable: 'The relayer cannot reach the chain right now. Try again shortly.',
  Internal: 'The relayer had a problem. Try again shortly.',
  RateLimited: 'The relayer is busy. Wait a few seconds and try again.',
  NonceInFlight: 'An order with the same number is already on its way.',
  GasTooHigh: 'The relayer will not send this order: it would cost far more gas than a normal trade. Nothing was traded.',
  BodyTooLarge: 'The relayer refused the order as too large.',
  OriginNotAllowed: 'The relayer does not take orders from this site.',
}

/** Errors that can pass on their own; the relayer keeps retrying these until the order's deadline. */
const TEMPORARY = new Set(['PriceMoved', 'TooSoon', 'OracleDown', 'BreakerTripped'])

export function isTemporary(name: string | undefined): boolean {
  return !!name && TEMPORARY.has(name)
}

/** Plain words for a contract error name, or for a message that is not one. */
export function explainErrorName(name: string): string {
  return MESSAGES[name] ?? (/^[A-Z][A-Za-z0-9]+$/.test(name) ? `The contract refused: ${name}.` : name)
}

/** Shown while the relayer retries an order that failed for a temporary reason. */
export function retryingText(name: string | undefined): string {
  if (name === 'PriceMoved') return 'Price moving fast, retrying…'
  if (name === 'TooSoon') return 'This position is too new to close yet, retrying…'
  if (name === 'OracleDown') return "This coin's price feed is not answering, retrying…"
  if (name === 'BreakerTripped') return 'New positions are paused for the hour, retrying…'
  return 'Retrying…'
}

export function explainError(e: unknown): string {
  if (e instanceof BaseError) {
    if (e.walk((err) => err instanceof UserRejectedRequestError)) return 'You rejected the request in your wallet.'
    const revert = e.walk((err) => err instanceof ContractFunctionRevertedError)
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName
      if (name) return explainErrorName(name)
      if (revert.reason) return revert.reason
    }
    return e.shortMessage
  }
  if (e instanceof Error) return e.message
  return String(e)
}
