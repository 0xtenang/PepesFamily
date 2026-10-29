import type { Address } from 'viem'
import local from '../../../contracts/deployments/local.json'
import robinhood from './robinhood.example.json'

export type MarketMeta = {
  id: number
  name: string
  symbol: string
  coin: Address
  uniPool: Address
  oracle: Address
  kind: string
  decimals?: number // the coin's ERC-20 decimals; read from the coin when left out
}

export type Deployment = {
  chainId: number
  rpcUrl: string
  exchange: Address
  lens: Address // read-only views
  tradeRouter: Address // LevRouter: one-click trading with session keys
  pool: Address
  router: Address // CreatorFeeRouterV2 (creator fees), not the trade router
  weth: Address
  deployer?: Address
  relayerUrl?: string // empty: no relayer, every trade goes through the wallet
  markets: MarketMeta[]
}

const deployments: Record<string, Deployment> = {
  local: local as Deployment,
  robinhood: robinhood as Deployment,
}

// Vite fills import.meta.env in the browser; the Node check script reads process.env instead.
const env: Record<string, string | undefined> =
  (import.meta as { env?: Record<string, string> }).env ??
  (typeof process !== 'undefined' ? process.env : {})

export const NETWORK = env.VITE_NETWORK ?? 'local'

const picked = deployments[NETWORK]
if (!picked) throw new Error(`Unknown VITE_NETWORK "${NETWORK}". Use one of: ${Object.keys(deployments).join(', ')}`)

export const deployment: Deployment = { ...picked, rpcUrl: env.VITE_RPC_URL ?? picked.rpcUrl }

/** Submits one-click trades and pays their gas. VITE_RELAYER_URL overrides the deployment file. */
export const relayerUrl = (env.VITE_RELAYER_URL ?? picked.relayerUrl ?? 'http://127.0.0.1:8790').replace(/\/+$/, '')

export const CHAIN_NAMES: Record<number, string> = {
  31337: 'Local chain',
  4663: 'Robinhood Chain',
  46630: 'Robinhood Chain Testnet',
}

export const isLocalChain = deployment.chainId === 31337
