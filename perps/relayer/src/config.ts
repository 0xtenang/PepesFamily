import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createPublicClient, createWalletClient, http, type Address, type Chain, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

export type Deployment = {
  chainId: number;
  rpcUrl: string;
  exchange: Address;
  lens: Address;
  tradeRouter: Address;
  pool: Address;
  markets: { id: number; name: string; symbol: string }[];
};

// Public anvil test keys. Used only when the chain is the local anvil chain (31337).
export const ANVIL_KEYS = {
  deployer: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
  relayer: '0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba',
} as const;

const defaultDeployment = fileURLToPath(new URL('../../contracts/deployments/local.json', import.meta.url));

export function loadDeployment(): Deployment {
  const d = JSON.parse(readFileSync(process.env.DEPLOYMENT ?? defaultDeployment, 'utf8')) as Deployment;
  if (process.env.RPC_URL) d.rpcUrl = process.env.RPC_URL;
  return d;
}

export function clients(d: Deployment, key: Hex) {
  const chain: Chain = {
    id: d.chainId,
    name: d.chainId === 4663 ? 'Robinhood Chain' : d.chainId === 46630 ? 'Robinhood Chain Testnet' : 'Local',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [d.rpcUrl] } },
  };
  const account = privateKeyToAccount(key);
  const transport = http(d.rpcUrl);
  // Poll receipts every 500 ms so includedAt is close to the real inclusion time.
  return {
    account,
    pub: createPublicClient({ chain, transport, pollingInterval: 500 }),
    wallet: createWalletClient({ chain, transport, account }),
  };
}

export function keyFor(d: Deployment, envName: string, localDefault: Hex): Hex {
  const key = process.env[envName] as Hex | undefined;
  if (key) return key;
  if (d.chainId === 31337) return localDefault;
  throw new Error(`Set ${envName}. Anvil test keys are only used on the local chain.`);
}

export function log(...parts: unknown[]) {
  console.log(new Date().toISOString().slice(11, 23), ...parts);
}

/** First useful line of a viem error. */
export function why(e: unknown): string {
  const err = e as { shortMessage?: string; message?: string };
  return err.shortMessage ?? err.message?.split('\n')[0] ?? String(e);
}
