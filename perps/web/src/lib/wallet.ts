import {
  createWalletClient,
  custom,
  http,
  type Abi,
  type Address,
  type EIP1193Provider,
  type LocalAccount,
  type TransactionReceipt,
  type WalletClient,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { deployment, isLocalChain } from '../config'
import { chain, publicClient } from './chain'

/** Anvil's public test account #1. Only ever used on the local chain (31337). */
const LOCAL_TEST_KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'

export type Wallet = {
  kind: 'injected' | 'local'
  address: Address
  client: WalletClient
  account: Address | LocalAccount
}

declare global {
  interface Window {
    ethereum?: EIP1193Provider
  }
}

export const hasInjected = () => typeof window !== 'undefined' && !!window.ethereum
export const canUseLocalWallet = isLocalChain

export async function connectInjected(): Promise<Wallet> {
  const provider = window.ethereum
  if (!provider) throw new Error('No browser wallet found. Install one, or use the local test wallet on the local chain.')
  const client = createWalletClient({ chain, transport: custom(provider) })
  const [address] = await client.requestAddresses()
  await ensureChain(client)
  return { kind: 'injected', address, client, account: address }
}

export function connectLocal(): Wallet {
  if (!isLocalChain) throw new Error('The local test wallet only works on the local chain.')
  const account = privateKeyToAccount(LOCAL_TEST_KEY)
  const client = createWalletClient({ account, chain, transport: http(deployment.rpcUrl) })
  return { kind: 'local', address: account.address, client, account }
}

export async function walletChainId(w: Wallet): Promise<number> {
  return w.kind === 'local' ? chain.id : w.client.getChainId()
}

export async function ensureChain(client: WalletClient): Promise<void> {
  if ((await client.getChainId()) === chain.id) return
  try {
    await client.switchChain({ id: chain.id })
  } catch (e) {
    // 4902: the wallet doesn't know this chain yet.
    if ((e as { code?: number }).code === 4902 || /4902|Unrecognized chain/i.test(String(e))) {
      await client.addChain({ chain })
      await client.switchChain({ id: chain.id })
    } else {
      throw e
    }
  }
}

export type Write = {
  address: Address
  abi: Abi
  functionName: string
  args?: readonly unknown[]
  value?: bigint
}

/** Simulates first so contract errors come back decoded, then sends and waits for the receipt. */
export async function send(w: Wallet, call: Write): Promise<TransactionReceipt> {
  const { request } = await publicClient.simulateContract({
    account: w.account,
    address: call.address,
    abi: call.abi,
    functionName: call.functionName,
    args: call.args ?? [],
    value: call.value,
  })
  const hash = await w.client.writeContract({ ...request, chain } as Parameters<WalletClient['writeContract']>[0])
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error('The transaction was reverted.')
  return receipt
}
