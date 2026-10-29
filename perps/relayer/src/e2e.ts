// Local end-to-end check of the gasless relayer. A trader approves a P-256 session key with one wallet tx, then
// opens, closes and withdraws through the relayer's HTTP API without paying gas; bad intents are refused.
//   node src/e2e.ts      (needs the local anvil stack; starts its own relayer on a free port)

import { formatEther, parseEther, type Abi, type Address, type Hex } from 'viem';
import exchangeAbiJson from '../../abi/LevExchange.json' with { type: 'json' };
import lensAbiJson from '../../abi/LevLens.json' with { type: 'json' };
import routerAbiJson from '../../abi/LevRouter.json' with { type: 'json' };
import { runAbuse } from './abuse.ts';
import { clients, loadDeployment, log, why } from './config.ts';
import { start, type Relayer } from './server.ts';
import {
  ACT_CLOSE_OWN,
  ACT_OPEN,
  ACT_WITHDRAW,
  bodyFor,
  createSessionKey,
  deadlineFrom,
  digestOf,
  randomNonce,
  signIntent,
  type IntentOf,
  type Kind,
  type Limits,
  type OpenIntent,
} from './session.ts';

const exchangeAbi = exchangeAbiJson as Abi;
const lensAbi = lensAbiJson as Abi;
const routerAbi = routerAbiJson as Abi;
const OWNER_KEY = '0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e'; // anvil account 6
const INT24_MAX = 8_388_607;
const INT24_MIN = -8_388_608; // no price limit on a long close: these checks are about the relay path
const ZERO = '0x0000000000000000000000000000000000000000';
const HASH_FN = { open: 'hashOpen', close: 'hashClose', withdraw: 'hashWithdraw', revoke: 'hashRevoke' } as const;

const d = loadDeployment();
if (d.chainId !== 31337) throw new Error('local only');
const trader = clients(d, OWNER_KEY);
const { pub } = trader;
const owner = trader.account.address;
const router = d.tradeRouter;

const results: { name: string; ok: boolean; detail: string }[] = [];
function check(name: string, ok: boolean, detail = '') {
  results.push({ name, ok, detail });
  log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`);
}

const read = <T>(address: Address, abi: Abi, functionName: string, args: readonly unknown[] = []) =>
  pub.readContract({ address, abi, functionName, args }) as Promise<T>;
const chainNow = async () => (await pub.getBlock()).timestamp;
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

type Reply = { id?: string; status?: string; error?: string; permanent?: boolean };
type IntentStatus = { status: string; txHash?: Hex; positionId?: string; error?: string; receivedAt: number; sentAt?: number; includedAt?: number };

// Reuse a relayer that is already running (RELAYER_URL, default the local one on 8790): a second process with the
// same key would race it for tx nonces. With nothing there, or RELAYER_URL= (empty), start one on a free port.
async function relayerFor(): Promise<Relayer> {
  const url = (process.env.RELAYER_URL ?? 'http://127.0.0.1:8790').replace(/\/+$/, '');
  if (url) {
    try {
      const res = await fetch(`${url}/health`, { signal: AbortSignal.timeout(2000) });
      const h = (await res.json()) as { chainId?: number; router?: string; relayer?: Address };
      if (h.chainId === d.chainId && String(h.router).toLowerCase() === router.toLowerCase() && h.relayer) {
        log(`using the relayer already running at ${url}`);
        return { url, address: h.relayer, close: async () => {} };
      }
      log(`${url} serves another chain or router; starting our own relayer`);
    } catch {
      // Nothing there.
    }
  }
  return start({ port: 0 });
}

const relayer = await relayerFor();

async function post(body: unknown, raw?: string): Promise<{ code: number; body: Reply }> {
  const res = await fetch(`${relayer.url}/intents`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: raw ?? JSON.stringify(body),
  });
  return { code: res.status, body: (await res.json()) as Reply };
}

async function waitFor(id: string, timeoutMs = 60_000): Promise<IntentStatus> {
  const [who, nonce] = id.split(':');
  const until = Date.now() + timeoutMs;
  for (;;) {
    const st = (await (await fetch(`${relayer.url}/intents/${who}/${nonce}`)).json()) as IntentStatus;
    if (['confirmed', 'failed', 'expired'].includes(st.status) || Date.now() > until) return st;
    await sleep(500);
  }
}

const timing = (st: IntentStatus) =>
  st.sentAt && st.includedAt ? `relay ${st.sentAt - st.receivedAt} ms, mined ${st.includedAt - st.sentAt} ms` : '';

async function run() {
  const health = (await (await fetch(`${relayer.url}/health`)).json()) as Record<string, unknown>;
  check(
    'health',
    health.ok === true && health.chainId === 31337 && health.router === router && BigInt(String(health.balanceWei)) > 0n,
    `relayer ${health.relayer}, ${formatEther(BigInt(String(health.balanceWei)))} ETH`,
  );

  // One wallet tx: approve the session key and deposit 1 ETH.
  const session = await createSessionKey();
  check('session key is non-extractable', session.privateKey.extractable === false, `key ${session.key.slice(0, 18)}…`);
  const limits: Limits = {
    expiry: (await chainNow()) + 86_400n,
    actions: ACT_OPEN | ACT_CLOSE_OWN | ACT_WITHDRAW,
    maxLeverage: 10,
    openSlipTicks: 300,
    closeSlipTicks: 600,
    maxStakePerTrade: parseEther('0.1'),
    maxOpenStake: parseEther('0.5'),
    dailyBudget: parseEther('1'),
  };
  const balance0 = await read<bigint>(d.exchange, exchangeAbi, 'balanceOf', [owner]);
  const { request } = await pub.simulateContract({
    address: router,
    abi: routerAbi,
    functionName: 'authorize',
    args: [session.qx, session.qy, limits],
    value: parseEther('1'),
    account: trader.account,
  });
  const receipt = await pub.waitForTransactionReceipt({ hash: await trader.wallet.writeContract(request) });
  const generation = await read<number>(router, routerAbi, 'generationOf', [owner]);
  const [, live] = await read<[unknown, boolean]>(router, routerAbi, 'sessionOf', [owner, session.key]);
  const balance1 = await read<bigint>(d.exchange, exchangeAbi, 'balanceOf', [owner]);
  check(
    'authorize: session live, 1 ETH deposited',
    receipt.status === 'success' && live && balance1 - balance0 === parseEther('1'),
    `generation ${generation}`,
  );

  // From here on the owner's wallet sends nothing.
  const ownerTxCount = await pub.getTransactionCount({ address: owner });
  const relayerEth0 = await pub.getBalance({ address: relayer.address });
  const base = { owner, key: session.key, generation };
  const sign = <K extends Kind>(kind: K, intent: IntentOf[K]) => signIntent(session.privateKey, kind, intent, d.chainId, router);
  const fresh = async () => ({ nonce: randomNonce(), deadline: deadlineFrom(await chainNow()) });
  async function openIntent(stake: bigint): Promise<OpenIntent> {
    const q = await read<{ entryTick: number }>(d.lens, lensAbi, 'quoteOpen', [0n, true, 2, stake]);
    const limitTick = Math.min(INT24_MAX, q.entryTick + 100); // about 1% worse than the quote
    return { ...base, marketId: 0, isLong: true, leverage: 2, stake, limitTick, ...(await fresh()) };
  }

  // The digest the browser signs must be the one the router verifies.
  const samples: { [K in Kind]: IntentOf[K] } = {
    open: await openIntent(parseEther('0.02')),
    close: { ...base, positionId: 7n, limitTick: -191_234, ...(await fresh()) },
    withdraw: { ...base, amount: parseEther('0.1'), ...(await fresh()) },
    revoke: { ...base, ...(await fresh()) },
  };
  for (const kind of Object.keys(samples) as Kind[]) {
    const ours = digestOf(kind, samples[kind], d.chainId, router);
    const theirs = await read<Hex>(router, routerAbi, HASH_FN[kind], [samples[kind]]);
    check(`hashTypedData == router.${HASH_FN[kind]}`, ours === theirs, ours.slice(0, 18) + '…');
  }

  // Open a 2x long of 0.02 ETH on PLONK.
  const open = await openIntent(parseEther('0.02'));
  const openBody = bodyFor('open', open, await sign('open', open));
  const opened = await post(openBody);
  check('open accepted', opened.code === 202 && opened.body.status === 'pending', `id ${opened.body.id?.slice(0, 14)}…`);
  const openSt = await waitFor(opened.body.id!);
  check('open confirmed', openSt.status === 'confirmed' && !!openSt.positionId, `position ${openSt.positionId}, ${timing(openSt)}`);
  const positionId = BigInt(openSt.positionId ?? 0);
  const pos = await read<{ position: { owner: Address; leverage: number; stake: bigint; isLong: boolean } }>(
    d.lens,
    lensAbi,
    'getPosition',
    [positionId],
  );
  const openedBy = await read<Hex>(router, routerAbi, 'openedBy', [positionId]);
  check(
    'position is the 2x long, opened by this session',
    pos.position.owner === owner && pos.position.leverage === 2 && pos.position.isLong && pos.position.stake === parseEther('0.02') && openedBy === session.key,
  );

  const replay = await post(openBody);
  check('replayed intent rejected', replay.code === 400 && replay.body.error === 'NonceUsed' && replay.body.permanent === true, `${replay.code} ${replay.body.error}`);

  // A close that is too soon (minimum hold 10 s) with a short deadline: retried, then expired. Nothing runs.
  const early = { ...base, positionId, limitTick: INT24_MIN, nonce: randomNonce(), deadline: (await chainNow()) + 4n };
  const earlyRes = await post(bodyFor('close', early, await sign('close', early)));

  log('waiting 11 s (minimum hold)…');
  await sleep(11_000);
  const earlySt = await waitFor(earlyRes.body.id ?? ':');
  check(
    'temporary error retried until the deadline, then expired',
    earlyRes.code === 202 && earlySt.status === 'expired' && (await read<boolean>(router, routerAbi, 'nonceUsed', [owner, early.nonce])) === false,
    `${earlySt.status} after ${earlySt.error}`,
  );

  const close = { ...base, positionId, limitTick: INT24_MIN, ...(await fresh()) };
  const closed = await post(bodyFor('close', close, await sign('close', close)));
  const closeSt = await waitFor(closed.body.id ?? ':');
  const after = await read<{ position: { owner: Address } }>(d.lens, lensAbi, 'getPosition', [positionId]);
  check('close confirmed, position gone', closed.code === 202 && closeSt.status === 'confirmed' && after.position.owner === ZERO, timing(closeSt));

  // Withdraw 0.1 ETH to the owner's wallet.
  const wallet0 = await pub.getBalance({ address: owner });
  const exBal0 = await read<bigint>(d.exchange, exchangeAbi, 'balanceOf', [owner]);
  const withdraw = { ...base, amount: parseEther('0.1'), ...(await fresh()) };
  const withdrawn = await post(bodyFor('withdraw', withdraw, await sign('withdraw', withdraw)));
  const withdrawSt = await waitFor(withdrawn.body.id ?? ':');
  const wallet1 = await pub.getBalance({ address: owner });
  const exBal1 = await read<bigint>(d.exchange, exchangeAbi, 'balanceOf', [owner]);
  check(
    'withdraw confirmed, wallet up 0.1 ETH',
    withdrawSt.status === 'confirmed' && wallet1 - wallet0 === parseEther('0.1') && exBal0 - exBal1 === parseEther('0.1'),
    `wallet +${formatEther(wallet1 - wallet0)} ETH, ${timing(withdrawSt)}`,
  );

  // Refusals.
  const signed = await openIntent(parseEther('0.02'));
  const tampered = { ...signed, stake: parseEther('0.05') };
  const t = await post(bodyFor('open', tampered, await sign('open', signed)));
  check('tampered intent rejected', t.code === 400 && t.body.error === 'BadSignature', `${t.code} ${t.body.error}`);

  const stale = { ...(await openIntent(parseEther('0.02'))), deadline: (await chainNow()) - 1n };
  const e = await post(bodyFor('open', stale, await sign('open', stale)));
  check('expired intent rejected', e.code === 400 && e.body.error === 'BadDeadline', `${e.code} ${e.body.error}`);

  const big = await openIntent(parseEther('0.2'));
  const o = await post(bodyFor('open', big, await sign('open', big)));
  check('over-limit stake rejected', o.code === 400 && o.body.error === 'OverLimit', `${o.code} ${o.body.error}`);

  // Malformed requests never reach the chain.
  const good = bodyFor('open', big, await sign('open', big));
  const shapes = await Promise.all([
    post({ ...good, kind: 'transfer' }),
    post({ ...good, intent: { ...good.intent, stake: 1 } }),
    post({ ...good, intent: { ...good.intent, extra: '1' } }),
    post(null, JSON.stringify({ ...good, pad: 'x'.repeat(9000) })),
  ]);
  check(
    'unknown kind, wrong type, unknown field, oversized body rejected',
    shapes[0].code === 400 && shapes[1].code === 400 && shapes[2].code === 400 && shapes[3].code === 413,
    shapes.map((s) => `${s.code} ${s.body.error}`).join('; '),
  );

  // Gasless: the owner's wallet sent nothing after authorize, the relayer paid.
  const relayerEth1 = await pub.getBalance({ address: relayer.address });
  check(
    'owner paid no gas, relayer did',
    (await pub.getTransactionCount({ address: owner })) === ownerTxCount && relayerEth1 < relayerEth0,
    `relayer spent ${formatEther(relayerEth0 - relayerEth1)} ETH`,
  );

  // The session key revokes itself (logout); after that its intents are refused.
  const revoke = { ...base, ...(await fresh()) };
  const revoked = await post(bodyFor('revoke', revoke, await sign('revoke', revoke)));
  const revokeSt = await waitFor(revoked.body.id ?? ':');
  const [, stillLive] = await read<[unknown, boolean]>(router, routerAbi, 'sessionOf', [owner, session.key]);
  const late = await openIntent(parseEther('0.02'));
  const l = await post(bodyFor('open', late, await sign('open', late)));
  check(
    'revokeBySig confirmed, later intents refused',
    revokeSt.status === 'confirmed' && !stillLive && l.code === 400 && l.body.error === 'SessionInvalid',
    `${l.code} ${l.body.error}`,
  );
}

try {
  await run();
} catch (e) {
  check('e2e ran to the end', false, why(e));
} finally {
  await relayer.close();
}

// Security regression checks (F5, F6, F17, F20, F21, F41, F43). They start their own relayers (so each finding
// runs with the limits it is about) and never share one with the main run above.
try {
  log('running security regression checks (abuse.ts)…');
  await runAbuse(check, d);
} catch (e) {
  check('abuse checks ran to the end', false, why(e));
}

const passed = results.filter((r) => r.ok).length;
console.log('\nRelayer e2e summary');
for (const r of results) console.log(`  ${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.detail ? `  [${r.detail}]` : ''}`);
const ok = passed === results.length;
console.log(`\n${ok ? 'E2E PASSED' : 'E2E FAILED'}: ${passed}/${results.length} checks`);
process.exit(ok ? 0 : 1);
