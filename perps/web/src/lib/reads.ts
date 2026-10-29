import {
  BaseError,
  ContractFunctionRevertedError,
  ContractFunctionZeroDataError,
  parseAbi,
  parseEther,
  zeroAddress,
  type Address,
  type Hex,
} from 'viem'
import { deployment, type MarketMeta } from '../config'
import { exchange, hasTradeRouter, lens, pool, publicClient, tradeRouter } from './chain'
import type { Account, Config, MarketRow, MarketView, PoolState, PositionView, Quote, Snapshot } from './types'

const OVERVIEW_STAKE = parseEther('0.01')
const NO_KEY: Hex = '0x0000000000000000000000000000000000000000000000000000000000000000'

function readEx<T>(functionName: string, args: readonly unknown[] = []): Promise<T> {
  return publicClient.readContract({ ...exchange, functionName, args }) as Promise<T>
}

// Market, quote and position views live on LevLens; the exchange keeps balances and raw state.
function readLens<T>(functionName: string, args: readonly unknown[] = []): Promise<T> {
  return publicClient.readContract({ ...lens, functionName, args }) as Promise<T>
}

function readPool<T>(functionName: string, args: readonly unknown[] = []): Promise<T> {
  return publicClient.readContract({ ...pool, functionName, args }) as Promise<T>
}

export function readConfig(): Promise<Config> {
  return readEx<Config>('getConfig')
}

export function readQuote(marketId: number, isLong: boolean, leverage: number, stake: bigint): Promise<Quote> {
  return readLens<Quote>('quoteOpen', [BigInt(marketId), isLong, leverage, stake])
}

const erc20Abi = parseAbi(['function decimals() view returns (uint8)'])
const decimalsCache = new Map<string, number>() // a coin's decimals never change

/** The coin's decimals: from the deployment file, else read once from the coin. A coin without decimals()
 *  counts as 18; a network error fails the read like any other. */
async function coinDecimals(meta: MarketMeta): Promise<number> {
  if (meta.decimals !== undefined) return meta.decimals
  const id = meta.coin.toLowerCase()
  const hit = decimalsCache.get(id)
  if (hit !== undefined) return hit
  let d: number
  try {
    d = Number(await publicClient.readContract({ address: meta.coin, abi: erc20Abi, functionName: 'decimals' }))
  } catch (e) {
    const noFunction =
      e instanceof BaseError &&
      !!e.walk((x) => x instanceof ContractFunctionRevertedError || x instanceof ContractFunctionZeroDataError)
    if (!noFunction) throw e
    d = 18
  }
  decimalsCache.set(id, d)
  return d
}

export async function readMarkets(): Promise<MarketRow[]> {
  const count = Number(await readEx<bigint>('marketCount'))
  const ids = Array.from({ length: count }, (_, i) => i)
  return Promise.all(
    ids.map(async (id) => {
      const known = deployment.markets.find((m) => m.id === id)
      const [view, long, short, decimals] = await Promise.all([
        readLens<MarketView>('getMarket', [BigInt(id)]),
        readQuote(id, true, 0, OVERVIEW_STAKE),
        readQuote(id, false, 0, OVERVIEW_STAKE),
        // A market missing from the deployment file has no known coin address, so its prices assume 18 decimals.
        known ? coinDecimals(known) : Promise.resolve(18),
      ])
      const meta = known ?? {
        id,
        name: `Market ${id}`,
        symbol: `#${id}`,
        coin: view.oracle,
        uniPool: view.oracle,
        oracle: view.oracle,
        kind: 'unknown',
      }
      return { meta, decimals, view, long, short }
    }),
  )
}

export async function readPoolState(): Promise<PoolState> {
  const [nav, cash, sharePrice, totalDonated, freeCash, totalSupply, totalMaxWin, withdrawCooldown, withdrawWindow] =
    await Promise.all([
      readPool<bigint>('nav'),
      readPool<bigint>('cash'),
      readPool<bigint>('sharePrice'),
      readPool<bigint>('totalDonated'),
      readPool<bigint>('freeCash'),
      readPool<bigint>('totalSupply'),
      readEx<bigint>('totalMaxWin'),
      readPool<bigint>('withdrawCooldown'),
      readPool<bigint>('withdrawWindow'),
    ])
  return { nav, cash, sharePrice, totalDonated, freeCash, totalSupply, totalMaxWin, withdrawCooldown, withdrawWindow }
}

export async function readAccount(address: Address): Promise<Account> {
  const [walletEth, exchangeBalance, lpShares, request, ids] = await Promise.all([
    publicClient.getBalance({ address }),
    readEx<bigint>('balanceOf', [address]),
    readPool<bigint>('balanceOf', [address]),
    // LevPool.WithdrawRequest: shares, assets (value when requested), unlockAt.
    readPool<readonly [bigint, bigint, bigint]>('withdrawRequests', [address]),
    readEx<readonly bigint[]>('positionIdsOf', [address]),
  ])
  const redeem = (shares: bigint) => (shares > 0n ? readPool<bigint>('previewRedeem', [shares]) : Promise.resolve(0n))
  // openedBy says which session key (if any) opened a position, so the app knows what one-click may close.
  const openedBy = (id: bigint): Promise<Hex> =>
    hasTradeRouter
      ? (publicClient.readContract({ ...tradeRouter, functionName: 'openedBy', args: [id] }) as Promise<Hex>)
      : Promise.resolve(NO_KEY)
  const [shares, assets, unlockAt] = request
  const [lpValue, valueNow, views] = await Promise.all([
    redeem(lpShares),
    redeem(shares),
    Promise.all(
      ids.map(async (id) => {
        const [view, by] = await Promise.all([readLens<PositionView>('getPosition', [id]), openedBy(id)])
        return { id, openedBy: by, ...view }
      }),
    ),
  ])
  // A position closed between the two reads comes back empty.
  const positions = views.filter((p) => p.position.owner !== zeroAddress)
  positions.sort((a, b) => Number(b.id - a.id))
  return {
    address,
    walletEth,
    exchangeBalance,
    lpShares,
    lpValue,
    // withdraw() pays the lower of the value at request and the value now.
    request: { shares, assets, unlockAt, valueNow, payout: valueNow < assets ? valueNow : assets },
    positions,
  }
}

export async function readSnapshot(address: Address | null): Promise<Snapshot> {
  const [block, config, markets, poolState, account] = await Promise.all([
    publicClient.getBlock(),
    readConfig(),
    readMarkets(),
    readPoolState(),
    address ? readAccount(address) : Promise.resolve(null),
  ])
  return { now: block.timestamp, config, markets, pool: poolState, account }
}
