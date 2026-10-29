// MemeLev gasless relayer. Takes intents signed by a trader's session key, checks each one by simulating it, and
// submits it to LevRouter, paying the gas. It only ever calls router.open, close, withdraw and revokeBySig, and it
// can only choose when an intent lands (within its deadline), never what it does.
//
//   node src/server.ts             local anvil stack (contracts/deployments/local.json), http://127.0.0.1:8790
//   DEPLOYMENT=… RPC_URL=… RELAYER_PRIVATE_KEY=0x… RELAYER_ORIGINS=https://app.example node src/server.ts
//
//   GET  /health                   { ok, chainId, router, relayer, balanceWei }
//   POST /intents                  { kind, intent, signature } -> 202 { id, status } | 400 { error, permanent } | 429
//   GET  /intents/:owner/:nonce    { status, txHash?, positionId?, error?, receivedAt, sentAt?, includedAt? }

import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';
import { pathToFileURL } from 'node:url';
import {
  BaseError,
  ContractFunctionRevertedError,
  IntrinsicGasTooHighError,
  IntrinsicGasTooLowError,
  WaitForTransactionReceiptTimeoutError,
  getAddress,
  isAddress,
  isAddressEqual,
  parseEventLogs,
  type Abi,
  type Address,
  type Hex,
  type Log,
} from 'viem';
import exchangeAbiJson from '../../abi/LevExchange.json' with { type: 'json' };
import poolAbiJson from '../../abi/LevPool.json' with { type: 'json' };
import routerAbiJson from '../../abi/LevRouter.json' with { type: 'json' };
import uniV3OracleAbiJson from '../../abi/UniV3Oracle.json' with { type: 'json' };
import uniV4OracleAbiJson from '../../abi/UniV4SampledOracle.json' with { type: 'json' };
import { ANVIL_KEYS, clients, keyFor, loadDeployment, log, why } from './config.ts';
import { MAX_DEADLINE_AHEAD, P256_N, PRIMARY_TYPE, ROUTER_FUNCTION, TYPES, toWire, type Kind } from './session.ts';

// Exchange, oracle and pool errors all bubble up through the router; add them so every revert decodes to a
// name instead of a raw selector (e.g. the oracle's Stale and NotEnoughHistory).
const routerOnlyAbi = routerAbiJson as Abi;
const extraErrorAbis = [exchangeAbiJson, uniV3OracleAbiJson, uniV4OracleAbiJson, poolAbiJson] as Abi[];
const seenError = new Set(routerOnlyAbi.filter((x) => x.type === 'error').map((x) => (x as { name: string }).name));
export const routerAbi = [
  ...routerOnlyAbi,
  ...extraErrorAbis.flatMap((abi) =>
    abi.filter((x) => x.type === 'error' && !seenError.has((x as { name: string }).name) && seenError.add((x as { name: string }).name)),
  ),
] as Abi;

const PORT = Number(process.env.RELAYER_PORT ?? 8790);
const HOST = process.env.RELAYER_HOST ?? '127.0.0.1';
const ORIGINS = new Set(
  (process.env.RELAYER_ORIGINS ?? 'http://localhost:5180,http://127.0.0.1:5180')
    .split(',')
    .map((o) => o.trim())
    .filter(Boolean),
);
const TRUST_PROXY = process.env.TRUST_PROXY === '1'; // take the client IP from X-Forwarded-For
const num = (name: string, dflt: number) => Number(process.env[name] ?? dflt);
const TRUST_PROXY_HOPS = Math.max(1, num('TRUST_PROXY_HOPS', 1)); // proxy hops: the real client IP is the Nth from the right

const MAX_BODY = 8 * 1024;
const RETRY_MS = 2000; // re-simulate an intent that failed for a temporary reason
const MAX_RETRY_MS = 8000; // back off: a job that keeps failing temporarily is re-simulated less often
const TTL_MS = 60 * 60 * 1000; // how long finished statuses stay readable
const RECEIPT_TIMEOUT_MS = 60_000;
const MAX_SENDS = 3; // per intent, if our tx reverts but the intent could still run
const OWNER_PER_MINUTE = num('RELAYER_OWNER_PER_MIN', 20);
const IP_PER_MINUTE = num('RELAYER_IP_PER_MIN', 60);
const MAX_PENDING_PER_OWNER = num('RELAYER_MAX_PENDING_PER_OWNER', 2); // junk that fails 'temporarily' can't stall the queue
const MAX_QUEUE = num('RELAYER_MAX_QUEUE', 500); // global cap on pending jobs

// Hard gas ceiling per intent kind. Any intent whose estimate (with headroom) exceeds it is refused for good, so
// a contract owner whose receive() burns gas can't drain the relayer (F5). Generous enough for a P-256 verify
// even without the RIP-7212 precompile; a normal open/close/withdraw is a fraction of these.
const GAS_CAP: Record<Kind, bigint> = { open: 3_000_000n, close: 3_000_000n, withdraw: 2_000_000n, revoke: 1_500_000n };
const GAS_CAP_OVERRIDE = process.env.RELAYER_GAS_CAP ? BigInt(process.env.RELAYER_GAS_CAP) : undefined;
const capFor = (kind: Kind) => GAS_CAP_OVERRIDE ?? GAS_CAP[kind];

// Worth retrying until the deadline. Every other revert is final.
const TEMPORARY = new Set(['PriceMoved', 'TooSoon', 'OracleDown', 'BreakerTripped']);
// A failing price feed reaches us as a custom oracle error or an Error(string); all mean "feed not ready", so
// they are reported as the temporary OracleDown rather than a raw selector or a bare 'Error' (F43).
const ORACLE_TEMPORARY = new Set(['OLD', 'feed down', 'Stale', 'NotEnoughHistory']);
// Router errors thrown in _use() before the signature is verified. A request that fails with one of these was
// never authenticated, so it must not be charged to the named owner's rate budget (F17).
const PRE_AUTH = new Set(['Paused', 'BadDeadline', 'SessionInvalid', 'NonceUsed', 'BadSignature', 'BadKey']);

type Status = 'pending' | 'sent' | 'confirmed' | 'failed' | 'expired';

type Job = {
  id: string; // owner:nonce
  kind: Kind;
  owner: Address;
  key: Hex;
  nonce: bigint;
  deadline: bigint;
  args: readonly [Record<string, unknown>, Hex, Hex];
  canonical: string; // to tell a harmless resubmission from a different intent reusing the nonce
  fromBlock: bigint;
  status: Status;
  error?: string; // final error, or the last temporary one while pending
  txHash?: Hex;
  blockNumber?: bigint;
  positionId?: bigint;
  submitter?: Address;
  sends: number;
  attempts?: number; // temporary-failure re-simulations, for backoff
  exhausted?: boolean; // sent MAX_SENDS times and reverted each time; no more sends, wait out the deadline
  nextTryAt: number;
  // Unix ms, logged for every intent so relay delay can be audited.
  receivedAt: number;
  sentAt?: number;
  includedAt?: number;
};

class HttpError extends Error {
  status: number;
  permanent: boolean;
  constructor(status: number, message: string, permanent = true) {
    super(message);
    this.status = status;
    this.permanent = permanent;
  }
}

const bad = (message: string) => new HttpError(400, message);

// ------------------------------------------------------------- request body

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** v must be an object with exactly these keys. */
function exactKeys(v: unknown, keys: readonly string[], path: string): Record<string, unknown> {
  if (!isObject(v)) throw bad(`${path} must be an object`);
  const extra = Object.keys(v).find((k) => !keys.includes(k));
  if (extra !== undefined) throw bad(`${path}.${extra} is not allowed`);
  const missing = keys.find((k) => !Object.hasOwn(v, k));
  if (missing !== undefined) throw bad(`${path}.${missing} is missing`);
  return v;
}

/** One field checked against its Solidity type. Ints up to 48 bits come back as numbers, wider ones as bigints. */
function parseField(type: string, v: unknown, path: string): unknown {
  if (type === 'bool') {
    if (typeof v !== 'boolean') throw bad(`${path} must be a boolean`);
    return v;
  }
  if (typeof v !== 'string') throw bad(`${path} must be a string`);
  if (type === 'address') {
    if (!isAddress(v)) throw bad(`${path} must be an address`);
    return getAddress(v);
  }
  if (type === 'bytes32') {
    if (!/^0x[0-9a-fA-F]{64}$/.test(v)) throw bad(`${path} must be 32 bytes of 0x hex`);
    return v.toLowerCase();
  }
  const m = /^(u?)int(\d+)$/.exec(type);
  if (!m) throw new Error(`no parser for ${type}`);
  if (!/^(0|-?[1-9][0-9]{0,77})$/.test(v)) throw bad(`${path} must be a decimal string`);
  const bits = BigInt(m[2]);
  const n = BigInt(v);
  const [min, max] = m[1] ? [0n, (1n << bits) - 1n] : [-(1n << (bits - 1n)), (1n << (bits - 1n)) - 1n];
  if (n < min || n > max) throw bad(`${path} is out of range for ${type}`);
  return bits <= 48n ? Number(n) : n;
}

function parseBody(raw: unknown) {
  const body = exactKeys(raw, ['kind', 'intent', 'signature'], 'body');
  const kind = body.kind;
  if (typeof kind !== 'string' || !Object.hasOwn(PRIMARY_TYPE, kind)) {
    throw bad('kind must be open, close, withdraw or revoke');
  }
  const fields: readonly { name: string; type: string }[] = TYPES[PRIMARY_TYPE[kind as Kind]];
  const rawIntent = exactKeys(
    body.intent,
    fields.map((f) => f.name),
    'intent',
  );
  const intent: Record<string, unknown> = {};
  for (const f of fields) intent[f.name] = parseField(f.type, rawIntent[f.name], `intent.${f.name}`);
  const sig = exactKeys(body.signature, ['r', 's'], 'signature');
  const r = parseField('bytes32', sig.r, 'signature.r') as Hex;
  const s = parseField('bytes32', sig.s, 'signature.s') as Hex;
  // The router takes only 0 < r < n and 0 < s <= n/2 (low-s); anything else can never verify.
  if (BigInt(r) === 0n || BigInt(r) >= P256_N || BigInt(s) === 0n || BigInt(s) > P256_N / 2n) throw bad('BadSignature');
  return { kind: kind as Kind, intent, r, s };
}

function readBody(req: IncomingMessage): Promise<string> {
  const tooLarge = () => new HttpError(413, 'BodyTooLarge');
  if (Number(req.headers['content-length'] ?? 0) > MAX_BODY) {
    req.resume();
    return Promise.reject(tooLarge());
  }
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size <= MAX_BODY) return void chunks.push(chunk);
      req.removeAllListeners('data');
      req.resume();
      reject(tooLarge());
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

/** Sliding one-minute window per key. take() returns 0 if allowed, else the seconds to wait. */
function limiter(perMinute: number) {
  const hits = new Map<string, number[]>();
  return {
    take(key: string): number {
      const now = Date.now();
      const recent = (hits.get(key) ?? []).filter((t) => now - t < 60_000);
      hits.set(key, recent);
      if (recent.length >= perMinute) return Math.max(1, Math.ceil((recent[0] + 60_000 - now) / 1000));
      recent.push(now);
      return 0;
    },
    sweep() {
      const now = Date.now();
      for (const [key, times] of hits) if (!times.length || now - times[times.length - 1] >= 60_000) hits.delete(key);
    },
  };
}

type Classified = { error: string; temporary: boolean; reverted: boolean };

/**
 * How to treat a failed call. `reverted` is true when the contract refused (a decodable revert), false when the
 * failure was off-chain (RPC/transport or a send the node rejected). A revert's name is temporary only if it is
 * worth retrying until the deadline; every other revert is final. A non-revert failure is retryable RPC trouble,
 * except deterministic send rejections (gas over the block limit, intrinsic gas) which are final (F43).
 */
export function classify(e: unknown): Classified {
  if (e instanceof BaseError) {
    if (e.walk((x) => x instanceof IntrinsicGasTooHighError || x instanceof IntrinsicGasTooLowError)) {
      return { error: 'GasTooHigh', temporary: false, reverted: false };
    }
    const revert = e.walk((x) => x instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      // Error(string) and Panic set errorName to 'Error'/'Panic' and keep the message in `reason`; prefer the
      // reason so the cause isn't lost.
      const named = revert.data?.errorName;
      const name =
        named && named !== 'Error' && named !== 'Panic' ? named : (revert.reason ?? named ?? revert.signature ?? 'Reverted');
      if (ORACLE_TEMPORARY.has(name)) return { error: 'OracleDown', temporary: true, reverted: true };
      return { error: name, temporary: TEMPORARY.has(name), reverted: true };
    }
  }
  return { error: why(e), temporary: true, reverted: false };
}

const iso = (ms?: number) => (ms === undefined ? undefined : new Date(ms).toISOString());

// ------------------------------------------------------------------ server

export type Relayer = { url: string; address: Address; close: () => Promise<void> };

// The rate and queue limits default to the module constants (env-configurable); start() can also override them
// per instance, which the regression tests use to drive one finding at a time.
export type StartOpts = {
  port?: number;
  host?: string;
  ownerPerMin?: number;
  ipPerMin?: number;
  maxPendingPerOwner?: number;
  maxQueue?: number;
  trustProxy?: boolean;
  trustProxyHops?: number;
};

export async function start(opts: StartOpts = {}): Promise<Relayer> {
  const ownerPerMin = opts.ownerPerMin ?? OWNER_PER_MINUTE;
  const ipPerMin = opts.ipPerMin ?? IP_PER_MINUTE;
  const maxPendingPerOwner = opts.maxPendingPerOwner ?? MAX_PENDING_PER_OWNER;
  const maxQueue = opts.maxQueue ?? MAX_QUEUE;
  const trustProxy = opts.trustProxy ?? TRUST_PROXY;
  const trustProxyHops = opts.trustProxyHops ?? TRUST_PROXY_HOPS;
  const d = loadDeployment();
  const { account, pub, wallet } = clients(d, keyFor(d, 'RELAYER_PRIVATE_KEY', ANVIL_KEYS.relayer));
  const router = d.tradeRouter;
  const chainId = await pub.getChainId();
  if (chainId !== d.chainId) throw new Error(`RPC is on chain ${chainId} but the deployment is for ${d.chainId}`);

  const jobs = new Map<string, Job>(); // by lowercase owner:nonce
  const reserving = new Set<string>(); // slots being admitted right now, so two identical POSTs can't both queue
  const queue: Job[] = []; // pending, oldest first
  // Owners with a tx in flight. Their next intent waits for it, so it is simulated against the state it will meet.
  const busy = new Set<Address>();
  const byOwner = limiter(ownerPerMin);
  const byIp = limiter(ipPerMin);
  let nextNonce: number | undefined; // our own tx nonce; only the queue touches it, one tx at a time
  let stopped = false;

  const call = (kind: Kind, args: Job['args']) =>
    ({ address: router, abi: routerAbi, functionName: ROUTER_FUNCTION[kind], args, account }) as const;

  // Simulate and price a call in one RPC: on success returns the gas estimate (so the gas ceiling can be
  // enforced), on failure the classified error. estimateContractGas reverts exactly as the call would.
  async function probe(kind: Kind, args: Job['args']): Promise<{ ok: true; gas: bigint } | ({ ok: false } & Classified)> {
    try {
      return { ok: true, gas: await pub.estimateContractGas(call(kind, args)) };
    } catch (e) {
      return { ok: false, ...classify(e) };
    }
  }

  function audit(j: Job) {
    log(
      `${j.kind} ${j.status}`,
      j.id,
      JSON.stringify({
        receivedAt: iso(j.receivedAt),
        sentAt: iso(j.sentAt),
        includedAt: iso(j.includedAt),
        waitMs: j.sentAt && j.sentAt - j.receivedAt,
        mineMs: j.includedAt && j.sentAt && j.includedAt - j.sentAt,
        txHash: j.txHash,
        block: j.blockNumber?.toString(),
        positionId: j.positionId?.toString(),
        error: j.error,
      }),
    );
  }

  function dequeue(j: Job) {
    const i = queue.indexOf(j);
    if (i >= 0) queue.splice(i, 1);
  }

  function finish(j: Job, status: Status, error?: string) {
    j.status = status;
    j.error = error;
    dequeue(j);
    audit(j);
  }

  function retryLater(j: Job, error: string) {
    j.error = error;
    j.attempts = (j.attempts ?? 0) + 1;
    // Back off so a job that keeps failing temporarily (e.g. a signer-chosen impossible limitTick, F6) doesn't
    // get re-simulated every 2 s for its whole life and crowd out fresh intents.
    j.nextTryAt = Date.now() + Math.min(RETRY_MS * j.attempts, MAX_RETRY_MS);
  }

  // ---------------------------------------------------------- the queue

  async function submit(j: Job, gas: bigint) {
    const c = call(j.kind, j.args);
    // gas was just estimated by step() and checked against the ceiling; keep the usual 1.2x headroom.
    const gasLimit = (gas * 12n) / 10n;
    nextNonce ??= await pub.getTransactionCount({ address: account.address, blockTag: 'pending' });
    const hash = await wallet.writeContract({ ...c, gas: gasLimit, nonce: nextNonce });
    nextNonce++;
    j.status = 'sent';
    j.txHash = hash;
    j.sentAt = Date.now();
    j.sends++;
    dequeue(j);
    busy.add(j.owner);
    log(`${j.kind} sent`, j.id, hash);
    void watch(j, hash);
  }

  /** NonceUsed on an accepted job: the intent can no longer run. It almost always ran (our send, or a backup's),
   *  so look for its IntentExecuted before calling it failed, which would make a client re-open a duplicate (F21). */
  async function onNonceUsed(j: Job) {
    const toBlock = (await pub.getBlock()).number;
    const ev = await executed(j, toBlock);
    if (ev || j.kind === 'revoke') {
      if (ev) {
        j.submitter = ev.submitter;
        if (j.kind === 'open') j.positionId = ev.positionIdOrAmount;
      }
      if (j.kind === 'close') j.positionId = j.args[0].positionId as bigint;
      return finish(j, 'confirmed');
    }
    finish(j, 'failed', 'NonceUsed'); // no execution found: the nonce was cancelled with cancelNonce
  }

  async function step(j: Job, chainNow: bigint) {
    try {
      if (chainNow > j.deadline) return finish(j, 'expired', j.error ?? 'BadDeadline');
      if (j.exhausted) {
        // Sent MAX_SENDS times and reverted each time. Don't send again, but the signed intent is still valid
        // until its deadline, so wait and see if it lands rather than reporting failed too early (F21).
        if (await nonceUsed(j, (await pub.getBlock()).number)) return onNonceUsed(j);
        return retryLater(j, j.error ?? 'Reverted');
      }
      const p = await probe(j.kind, j.args);
      if (p.ok) {
        if ((p.gas * 12n) / 10n > capFor(j.kind)) return finish(j, 'failed', 'GasTooHigh');
        return await submit(j, p.gas);
      }
      if (p.error === 'NonceUsed') return onNonceUsed(j);
      if (p.temporary) return retryLater(j, p.error);
      if (p.error === 'BadDeadline') return finish(j, 'expired', j.error ?? p.error);
      finish(j, 'failed', p.error);
    } catch (e) {
      // Gas estimate or send failed. Resync our nonce in case the send half-happened.
      nextNonce = undefined;
      const c = classify(e);
      if (c.error === 'NonceUsed') return onNonceUsed(j); // the send threw but the tx may have landed
      if (c.error === 'BadDeadline') return finish(j, 'expired', j.error ?? c.error); // not a failure, it timed out
      if (c.temporary) retryLater(j, c.error);
      else finish(j, 'failed', c.error);
    }
  }

  let pumping = false;
  async function pump() {
    if (pumping || stopped) return;
    pumping = true;
    try {
      for (;;) {
        const now = Date.now();
        const ready = queue.filter((j) => j.nextTryAt <= now && !busy.has(j.owner));
        if (!ready.length || stopped) break;
        const chainNow = (await pub.getBlock()).timestamp;
        for (const j of ready) if (!busy.has(j.owner) && j.status === 'pending') await step(j, chainNow);
      }
    } catch (e) {
      log('queue:', why(e));
    } finally {
      pumping = false;
    }
  }

  // ------------------------------------------------------- after sending

  const nonceUsed = (j: Job, blockNumber?: bigint) =>
    pub.readContract({ address: router, abi: routerAbi, functionName: 'nonceUsed', args: [j.owner, j.nonce], blockNumber }) as Promise<boolean>;

  type Executed = { owner: Address; nonce: bigint; positionIdOrAmount: bigint; submitter: Address };
  const matches = (j: Job) => (l: { address: Address; args: unknown }) => {
    const a = l.args as Executed;
    return isAddressEqual(l.address, router) && isAddressEqual(a.owner, j.owner) && a.nonce === j.nonce;
  };

  /** IntentExecuted for this intent: from our receipt, or from the logs if someone else landed it. */
  async function executed(j: Job, toBlock: bigint, logs?: Log[]): Promise<Executed | undefined> {
    const found = logs
      ? parseEventLogs({ abi: routerAbi, eventName: 'IntentExecuted', logs }).find(matches(j))
      : (
          await pub.getContractEvents({
            address: router,
            abi: routerAbi,
            eventName: 'IntentExecuted',
            args: { owner: j.owner, key: j.key },
            fromBlock: j.fromBlock,
            toBlock,
          })
        ).find(matches(j));
    return found?.args as Executed | undefined;
  }

  async function confirm(j: Job, toBlock: bigint, logs?: Log[]) {
    const ev = await executed(j, toBlock, logs); // revokeBySig emits SessionRevoked instead, so it has none
    if (ev) j.submitter = ev.submitter;
    if (ev && j.kind === 'open') j.positionId = ev.positionIdOrAmount;
    if (j.kind === 'close') j.positionId = j.args[0].positionId as bigint;
    finish(j, 'confirmed');
  }

  async function settle(j: Job, hash: Hex) {
    let receipt;
    try {
      receipt = await pub.waitForTransactionReceipt({ hash, timeout: RECEIPT_TIMEOUT_MS });
    } catch (e) {
      if (!(e instanceof WaitForTransactionReceiptTimeoutError)) throw e;
      // Not mined yet. Done if someone else landed the intent or its deadline is behind us; else keep waiting.
      const block = await pub.getBlock();
      if (await nonceUsed(j, block.number)) return confirm(j, block.number);
      if (block.timestamp > j.deadline) return finish(j, 'expired', 'NotIncluded');
      throw e;
    }
    j.includedAt = Date.now();
    j.blockNumber = receipt.blockNumber;
    // The router marks the nonce used only when the intent runs, so this is the ground truth.
    if (await nonceUsed(j, receipt.blockNumber)) {
      return confirm(j, receipt.blockNumber, receipt.status === 'success' ? receipt.logs : undefined);
    }
    // Our tx reverted and the intent has not run (say the price moved after the simulation): back to the queue.
    if (j.sends >= MAX_SENDS) {
      // Out of sends. The signed intent stays valid until its deadline and its calldata is now public, so keep
      // it pending (no more sends) until the deadline settles it, rather than reporting failed now (F21).
      j.exhausted = true;
      j.status = 'pending';
      j.error = 'Reverted';
      j.nextTryAt = Date.now() + RETRY_MS;
      queue.push(j);
      return;
    }
    log(`${j.kind} reverted, retrying`, j.id, hash);
    j.status = 'pending';
    j.error = 'Reverted';
    j.nextTryAt = Date.now();
    queue.push(j);
  }

  async function watch(j: Job, hash: Hex) {
    try {
      await settle(j, hash);
    } catch (e) {
      // RPC trouble or still not mined: look again shortly. The owner stays busy until we know.
      log(`${j.kind} watch`, j.id, why(e));
      if (!stopped) setTimeout(() => void watch(j, hash), RETRY_MS);
      return;
    }
    busy.delete(j.owner);
    void pump();
  }

  // ------------------------------------------------------------ handlers

  async function postIntent(req: IncomingMessage, ip: string): Promise<[number, object, Record<string, string>?]> {
    const receivedAt = Date.now();
    const limited = (seconds: number): [number, object, Record<string, string>] => [
      429,
      { error: 'RateLimited', permanent: false, retryAfter: seconds },
      { 'retry-after': String(seconds) },
    ];
    const wait = byIp.take(ip);
    if (wait) return limited(wait);

    let raw: unknown;
    const text = await readBody(req);
    try {
      raw = JSON.parse(text);
    } catch {
      throw bad('body must be JSON');
    }
    const { kind, intent, r, s } = parseBody(raw);
    const owner = intent.owner as Address;
    const nonce = intent.nonce as bigint;
    const deadline = intent.deadline as bigint;

    const id = `${owner}:${nonce}`;
    const slot = id.toLowerCase();
    const canonical = JSON.stringify([kind, toWire(intent), r, s]);
    const prev = jobs.get(slot);
    if (prev && (prev.status === 'pending' || prev.status === 'sent')) {
      if (prev.canonical === canonical) return [202, { id, status: prev.status }];
      throw bad('NonceInFlight');
    }
    // Reserve the slot synchronously, before the first await, so two identical POSTs racing through getBlock and
    // the simulation can't both be queued (the later would then wrongly report 'failed NonceUsed') (F41).
    if (reserving.has(slot)) throw bad('NonceInFlight');
    reserving.add(slot);
    try {
      const reject = (error: string): [number, object] => {
        log(`${kind} rejected`, id, JSON.stringify({ receivedAt: iso(receivedAt), error }));
        return [400, { error, permanent: true }];
      };
      // Charge the owner's rate budget only once the request is authenticated, so junk naming a victim can't use
      // up the victim's 20/min budget and lock them out (F17).
      const chargeOwner = () => {
        const w = byOwner.take(owner);
        return w ? limited(w) : undefined;
      };

      const block = await pub.getBlock().catch(() => {
        throw new HttpError(503, 'RpcUnavailable', false);
      });
      if (deadline < block.timestamp || deadline > block.timestamp + MAX_DEADLINE_AHEAD) return reject('BadDeadline');

      const args = [intent, r, s] as const;
      const p = await probe(kind, args);

      // A non-revert failure during this simulation means the RPC is unreachable, so the signature was never
      // checked; answer 503 instead of queuing an unauthenticated intent (F43).
      if (!p.ok && p.temporary && !p.reverted) throw new HttpError(503, 'RpcUnavailable', false);

      // Authenticated means the simulation got past _use()'s signature and session checks: either it succeeded
      // or it reverted for a reason that comes after _use() (OverLimit, PriceMoved, …), never a PRE_AUTH one.
      const authenticated = p.ok || (p.reverted && !PRE_AUTH.has(p.error));
      if (!authenticated) return reject((p as { error: string }).error); // owner NOT charged

      const over = chargeOwner();
      if (over) return over;

      if (!p.ok && !p.temporary) return reject(p.error); // authenticated, but a permanent revert (OverLimit, …)
      if (p.ok && (p.gas * 12n) / 10n > capFor(kind)) return reject('GasTooHigh'); // gas ceiling (F5)

      // This intent will be queued. Bound how many an owner (and everyone) can keep pending, so junk that fails
      // 'temporarily' can't stall the serial queue (F6).
      const pendingForOwner =
        queue.reduce((n, x) => (isAddressEqual(x.owner, owner) ? n + 1 : n), 0) + (busy.has(owner) ? 1 : 0);
      if (pendingForOwner >= maxPendingPerOwner || queue.length >= maxQueue) return limited(5);

      const j: Job = {
        id,
        kind,
        owner,
        key: intent.key as Hex,
        nonce,
        deadline,
        args,
        canonical,
        fromBlock: block.number,
        status: 'pending',
        error: p.ok ? undefined : p.error,
        sends: 0,
        nextTryAt: p.ok ? 0 : Date.now() + RETRY_MS,
        receivedAt,
      };
      jobs.set(slot, j);
      queue.push(j);
      log(`${kind} accepted`, id, JSON.stringify({ receivedAt: iso(receivedAt), firstSimulation: p.ok ? 'ok' : p.error }));
      void pump();
      return [202, { id, status: 'pending' }];
    } finally {
      reserving.delete(slot);
    }
  }

  function view(j: Job) {
    return {
      id: j.id,
      kind: j.kind,
      status: j.status,
      txHash: j.txHash,
      positionId: j.positionId?.toString(),
      error: j.error,
      receivedAt: j.receivedAt,
      sentAt: j.sentAt,
      includedAt: j.includedAt,
      blockNumber: j.blockNumber?.toString(),
      submitter: j.submitter,
    };
  }

  let balance = { wei: 0n, at: 0 };
  async function health() {
    if (Date.now() - balance.at > 5000) balance = { wei: await pub.getBalance({ address: account.address }), at: Date.now() };
    return {
      ok: true,
      chainId: d.chainId,
      router,
      relayer: account.address,
      balanceWei: balance.wei.toString(),
      queued: queue.length,
      inFlight: busy.size,
    };
  }

  function reply(res: ServerResponse, status: number, body: object, headers: Record<string, string> = {}) {
    res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers });
    res.end(JSON.stringify(body));
  }

  // Rate-limit key for an IP. IPv6 is grouped by /64 so one /64 (any VPS gets one) can't mint endless buckets.
  const ipKey = (ip: string) => {
    const a = ip.replace(/^::ffff:/i, '').split('%')[0]; // drop IPv4-mapped prefix and any zone
    if (a.includes(':') && !a.includes('::')) return `${a.split(':').slice(0, 4).join(':')}::/64`;
    return a;
  };
  const ipOf = (req: IncomingMessage) => {
    const forwarded = req.headers['x-forwarded-for'];
    if (trustProxy && typeof forwarded === 'string') {
      // A trusted proxy appends the real client IP on the right. Take the Nth entry from the right (one per
      // proxy hop), never the leftmost, which the client controls and could rotate to dodge the limit (F20).
      const parts = forwarded.split(',').map((x) => x.trim()).filter(Boolean);
      const pick = parts[parts.length - trustProxyHops];
      if (pick) return ipKey(pick);
    }
    return ipKey(req.socket.remoteAddress ?? 'unknown');
  };

  async function handle(req: IncomingMessage, res: ServerResponse) {
    try {
      const origin = req.headers.origin;
      if (origin !== undefined) {
        if (!ORIGINS.has(origin)) return reply(res, 403, { error: 'OriginNotAllowed', permanent: true });
        res.setHeader('access-control-allow-origin', origin);
        res.setHeader('vary', 'origin');
      }
      if (req.method === 'OPTIONS') {
        res.writeHead(204, {
          'access-control-allow-methods': 'GET, POST, OPTIONS',
          'access-control-allow-headers': 'content-type',
          'access-control-max-age': '600',
        });
        return res.end();
      }
      const path = new URL(req.url ?? '/', 'http://relayer').pathname;
      if (path === '/health' && req.method === 'GET') return reply(res, 200, await health());
      if (path === '/intents') {
        if (req.method !== 'POST') return reply(res, 405, { error: 'MethodNotAllowed', permanent: true });
        const [status, body, headers] = await postIntent(req, ipOf(req));
        return reply(res, status, body, headers);
      }
      const m = /^\/intents\/(0x[0-9a-fA-F]{40})\/(0|[1-9][0-9]{0,77})$/.exec(path);
      const j = m && req.method === 'GET' ? jobs.get(`${m[1]}:${m[2]}`.toLowerCase()) : undefined;
      if (j) return reply(res, 200, view(j));
      reply(res, 404, { error: 'NotFound', permanent: true });
    } catch (e) {
      if (e instanceof HttpError) {
        return reply(res, e.status, { error: e.message, permanent: e.permanent }, e.status === 413 ? { connection: 'close' } : {});
      }
      log('request failed:', why(e));
      reply(res, 500, { error: 'Internal', permanent: false });
    }
  }

  const server = createServer((req, res) => void handle(req, res));
  const ticker = setInterval(() => void pump(), 500);
  const sweeper = setInterval(() => {
    const now = Date.now();
    for (const [slot, j] of jobs) {
      if (j.status !== 'pending' && j.status !== 'sent' && now - j.receivedAt > TTL_MS) jobs.delete(slot);
    }
    byOwner.sweep();
    byIp.sweep();
  }, 60_000);

  const host = opts.host ?? HOST;
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(opts.port ?? PORT, host, () => resolve());
  });
  const url = `http://${host}:${(server.address() as AddressInfo).port}`;
  log(`relayer ${account.address} on chain ${chainId}, router ${router}, listening on ${url}`);
  if ((await pub.getBalance({ address: account.address })) === 0n) log('warning: relayer has no ETH for gas');

  async function close() {
    stopped = true;
    clearInterval(ticker);
    clearInterval(sweeper);
    await new Promise<void>((resolve) => {
      server.close(() => resolve());
      server.closeAllConnections();
    });
  }

  return { url, address: account.address, close };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const relayer = await start();
  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.on(signal, () => void relayer.close().then(() => process.exit(0)));
  }
}
