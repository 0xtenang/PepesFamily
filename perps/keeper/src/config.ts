import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  BaseError,
  InsufficientFundsError,
  createPublicClient,
  createWalletClient,
  http,
  type Abi,
  type Account,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type WalletClient,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

export type Market = { id: number; name: string; symbol: string; coin: Address; uniPool: Address; oracle: Address; kind: string };
export type Deployment = {
  chainId: number;
  rpcUrl: string;
  exchange: Address;
  lens: Address;
  tradeRouter: Address;
  pool: Address;
  router: Address;
  weth: Address;
  markets: Market[];
};

// Public anvil test keys. Used only when the chain is the local anvil chain (31337).
export const ANVIL_KEYS = {
  deployer: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
  keeper: '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a',
  prices: '0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97', // anvil account 8: demo-prices' random walk, used by nothing else
  relayer: '0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba',
} as const;

const defaultDeployment = fileURLToPath(new URL('../../contracts/deployments/local.json', import.meta.url));

// viem polls for receipts every 4 s on a chain it knows nothing about. Robinhood Chain and anvil make blocks far
// faster, so poll every 500 ms (like the relayer) and a transaction is confirmed about when it lands.
const POLLING_MS = Number(process.env.POLLING_MS ?? 500);

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
  return {
    account,
    pub: createPublicClient({ chain, transport, pollingInterval: POLLING_MS }),
    wallet: createWalletClient({ chain, transport, account, pollingInterval: POLLING_MS }),
  };
}

export function keyFor(d: Deployment, envName: string, localDefault: Hex): Hex {
  const key = process.env[envName] as Hex | undefined;
  if (key) return key;
  if (d.chainId === 31337) return localDefault;
  throw new Error(`Set ${envName} to the keeper's private key. Anvil test keys are only used on the local chain.`);
}

export function log(...parts: unknown[]) {
  console.log(new Date().toISOString().slice(11, 19), ...parts);
}

const alerted = new Map<string, number>(); // alert key -> last logged at (ms)

/** An "ALERT" log line for a supervisor to catch, repeated at most every ALERT_REPEAT_S (default 1 h) per key. */
export function alert(key: string, ...parts: unknown[]) {
  const repeatMs = Number(process.env.ALERT_REPEAT_S ?? 3600) * 1000;
  const last = alerted.get(key);
  if (last !== undefined && Date.now() - last < repeatMs) return;
  alerted.set(key, Date.now());
  log('ALERT', ...parts);
}

/** First useful line of a viem error: the custom error name if the contract reverted. */
export function why(e: unknown): string {
  const err = e as { shortMessage?: string; message?: string; cause?: { data?: { errorName?: string } } };
  return err.cause?.data?.errorName ?? (err.shortMessage ?? err.message)?.split('\n')[0] ?? String(e);
}

// ------------------------------------------------------------------ sending transactions

export type Call = {
  address: Address;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
  label: string;
  /** Revert reasons that only mean "nothing to do yet": not logged. */
  quiet?: readonly string[];
  /** Log only failures (for routine transactions such as scheduled refreshes). */
  quietSuccess?: boolean;
};
type Sent = { call: Call; hash: Hex; gas: bigint; retried: boolean };
export type Clients = { pub: PublicClient; wallet: WalletClient; account: Account };
export type Sender = ReturnType<typeof createSender>;

const GAS_MARGIN_PCT = BigInt(process.env.GAS_MARGIN_PCT ?? 130); // gas limit = estimate x 1.3 ...
const GAS_MARGIN_MIN = BigInt(process.env.GAS_MARGIN_MIN ?? 25_000); // ... and at least estimate + 25k
const RECEIPT_TIMEOUT_MS = Number(process.env.RECEIPT_TIMEOUT_MS ?? 30_000);
const ESTIMATE_CONCURRENCY = 25;

/**
 * One account's transactions. Every call is simulated first (eth_estimateGas, so a call that would revert costs no
 * gas and its revert reason is logged), sent with a gas margin, and numbered from a local nonce counter, so a batch
 * goes out back to back without waiting for each receipt. Keeper and fee jobs share one Sender, so their nonces never
 * collide. A transaction that runs out of gas anyway is sent once more with twice the gas.
 */
export function createSender({ pub, wallet, account }: Clients) {
  let nextNonce: number | undefined;
  let fees: { maxFeePerGas?: bigint; maxPriorityFeePerGas?: bigint } | undefined;
  let lock: Promise<unknown> = Promise.resolve();
  let broke = false; // the last send failed for lack of gas money

  /** Sends one at a time, so nonces are handed out in order. */
  function serial<T>(fn: () => Promise<T>): Promise<T> {
    const next = lock.then(fn, fn);
    lock = next.catch(() => undefined);
    return next;
  }

  /** Gas limit with headroom, or undefined if the call would revert now. */
  async function estimate(call: Call): Promise<bigint | undefined> {
    try {
      const est = await pub.estimateContractGas({ address: call.address, abi: call.abi, functionName: call.functionName, args: call.args, account });
      const scaled = (est * GAS_MARGIN_PCT) / 100n;
      return scaled > est + GAS_MARGIN_MIN ? scaled : est + GAS_MARGIN_MIN;
    } catch (e) {
      const reason = why(e);
      if (!call.quiet?.includes(reason)) log(`${call.label}: skipped (${reason})`);
      return undefined;
    }
  }

  function send(call: Call, gas: bigint, retried = false): Promise<Sent | undefined> {
    return serial(async () => {
      for (let attempt = 0; ; attempt++) {
        try {
          nextNonce ??= await pub.getTransactionCount({ address: account.address, blockTag: 'pending' });
          if (!fees) {
            try {
              const f = await pub.estimateFeesPerGas();
              fees = { maxFeePerGas: f.maxFeePerGas, maxPriorityFeePerGas: f.maxPriorityFeePerGas };
            } catch {
              fees = {}; // no EIP-1559 quote: let viem price each transaction
            }
          }
          const hash = await wallet.writeContract({
            address: call.address,
            abi: call.abi,
            functionName: call.functionName,
            args: call.args,
            account,
            chain: wallet.chain,
            gas,
            nonce: nextNonce,
            ...fees,
          });
          nextNonce++;
          broke = false;
          return { call, hash, gas, retried };
        } catch (e) {
          // The send may have half-happened, or another process used this key: re-read the nonce next time.
          nextNonce = undefined;
          fees = undefined;
          const reason = why(e);
          if (e instanceof BaseError && e.walk((x) => x instanceof InsufficientFundsError)) {
            broke = true;
            alert('keeper-gas-empty', `${account.address} can't pay for gas: ${call.label} not sent (${reason})`);
            return undefined;
          }
          if (attempt === 0 && /nonce|replacement transaction|already known/i.test(`${reason} ${(e as Error).message ?? ''}`)) continue;
          log(`${call.label}: not sent (${reason})`);
          return undefined;
        }
      }
    });
  }

  async function confirm(s: Sent): Promise<boolean> {
    try {
      const r = await pub.waitForTransactionReceipt({ hash: s.hash, timeout: RECEIPT_TIMEOUT_MS });
      if (r.status === 'success') {
        if (!s.call.quietSuccess) log(`${s.call.label}: success`, s.hash);
        return true;
      }
      const outOfGas = r.gasUsed * 100n >= s.gas * 98n;
      log(`${s.call.label}: reverted${outOfGas ? ` (out of gas at ${s.gas})` : ''}`, s.hash);
      if (!outOfGas || s.retried) return false;
      const gas = await estimate(s.call); // undefined if someone else has done it meanwhile
      if (gas === undefined) return false;
      const again = await send(s.call, gas > s.gas * 2n ? gas : s.gas * 2n, true);
      return again ? confirm(again) : false;
    } catch (e) {
      nextNonce = undefined; // a transaction that never lands may leave a gap
      log(`${s.call.label}: no receipt (${why(e)})`, s.hash);
      return false;
    }
  }

  /**
   * Simulates the calls (a few at a time), sends those that would succeed in the given order without waiting for
   * receipts, up to `maxSends`, then waits for all the receipts. `left` counts calls not tried because of the cap.
   */
  async function run(calls: Call[], maxSends = Infinity): Promise<{ sent: number; ok: number; left: number }> {
    fees = undefined; // a fresh fee quote for every batch
    broke = false; // the wallet may have been topped up since
    const confirmations: Promise<boolean>[] = [];
    const routine: Call[] = []; // quietSuccess calls, logged together
    let done = 0;
    while (done < calls.length && confirmations.length < maxSends && !broke) {
      const chunk = calls.slice(done, done + ESTIMATE_CONCURRENCY);
      const gases = await Promise.all(chunk.map(estimate));
      let i = 0;
      for (; i < chunk.length && confirmations.length < maxSends && !broke; i++) {
        const gas = gases[i];
        if (gas === undefined) continue;
        const s = await send(chunk[i], gas);
        if (!s) continue;
        confirmations.push(
          confirm(s).then((ok) => {
            if (ok && s.call.quietSuccess) routine.push(s.call);
            return ok;
          }),
        );
      }
      done += i;
    }
    if (broke && done < calls.length) log(`${calls.length - done} more transactions not sent: no gas money`);
    const results = await Promise.all(confirmations);
    if (routine.length) {
      routine.sort((a, b) => calls.indexOf(a) - calls.indexOf(b));
      log(`${routine.map((c) => c.label).join(', ')}: success`);
    }
    return { sent: confirmations.length, ok: results.filter(Boolean).length, left: broke ? 0 : calls.length - done };
  }

  return {
    run,
    /** One call: simulate, send, wait. True if it landed and succeeded. */
    one: async (call: Call) => (await run([call])).ok === 1,
    get broke() {
      return broke;
    },
  };
}
