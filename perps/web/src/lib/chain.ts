import { createPublicClient, defineChain, http, zeroAddress, type Abi } from 'viem'
import { CHAIN_NAMES, deployment } from '../config'
import exchangeAbiJson from '../../../abi/LevExchange.json'
import lensAbiJson from '../../../abi/LevLens.json'
import poolAbiJson from '../../../abi/LevPool.json'
import routerAbiJson from '../../../abi/LevRouter.json'

export const exchangeAbi = exchangeAbiJson as Abi
export const lensAbi = lensAbiJson as Abi
export const poolAbi = poolAbiJson as Abi
// Exchange errors bubble up through the router, so add them to decode every revert by name.
export const routerAbi = [
  ...(routerAbiJson as Abi),
  ...exchangeAbi.filter(
    (x) => x.type === 'error' && !(routerAbiJson as Abi).some((r) => r.type === 'error' && r.name === x.name),
  ),
] as Abi

export const chain = defineChain({
  id: deployment.chainId,
  name: CHAIN_NAMES[deployment.chainId] ?? `Chain ${deployment.chainId}`,
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [deployment.rpcUrl] } },
})

// No Multicall3 on anvil, so reads go out as plain calls, batched into one HTTP request where possible.
export const publicClient = createPublicClient({
  chain,
  transport: http(deployment.rpcUrl, { batch: true }),
})

export const exchange = { address: deployment.exchange, abi: exchangeAbi } as const
export const lens = { address: deployment.lens, abi: lensAbi } as const
export const pool = { address: deployment.pool, abi: poolAbi } as const
export const tradeRouter = { address: deployment.tradeRouter ?? zeroAddress, abi: routerAbi } as const

/** False when the deployment has no LevRouter yet (one-click trading is then off). */
export const hasTradeRouter = tradeRouter.address !== zeroAddress
