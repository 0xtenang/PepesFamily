// Abuse / regression checks for the relayer security fixes (F5, F6, F17, F20, F21, F41, F43). They run against
// the local anvil stack and drive the real HTTP relayer. e2e.ts calls runAbuse() after the main run, so
// `node src/e2e.ts` covers these too. Attacker is anvil #4, victim/owner is anvil #6; the relayer is anvil #5.

import { encodeErrorResult, encodeFunctionData, parseEther, type Abi, type Address, type Hex } from 'viem';
import { ContractFunctionRevertedError, IntrinsicGasTooHighError } from 'viem';
import exchangeAbiJson from '../../abi/LevExchange.json' with { type: 'json' };
import lensAbiJson from '../../abi/LevLens.json' with { type: 'json' };
import routerAbiJson from '../../abi/LevRouter.json' with { type: 'json' };
import { clients, type Deployment } from './config.ts';
import { classify, routerAbi, start, type Relayer } from './server.ts';
import {
  ACT_CLOSE_ANY,
  ACT_CLOSE_OWN,
  ACT_OPEN,
  ACT_WITHDRAW,
  bodyFor,
  createSessionKey,
  deadlineFrom,
  randomNonce,
  signIntent,
  type IntentOf,
  type Kind,
  type Limits,
  type SessionKey,
} from './session.ts';

const exchangeAbi = exchangeAbiJson as Abi;
const lensAbi = lensAbiJson as Abi;
const fullRouterAbi = routerAbiJson as Abi;
const ATTACKER_KEY = '0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a'; // anvil #4
const VICTIM_KEY = '0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e'; // anvil #6
const MIN_TICK = -8_388_608; // int24 min: an impossible limitTick for a long (entry > limitTick always)
// A contract wallet whose receive() burns ~20M gas on a 0-wei transfer; its call2() forwards to the router so it
// becomes the session owner. Compiled from scratch (no imports); used only to prove the relayer's gas ceiling.
const BURNER_BYTECODE =
  '0x6080604052348015600e575f5ffd5b506103bc8061001c5f395ff3fe608060405260043610610021575f3560e01c80638a45f337146100bd576100b9565b366100b9575f600190505f5f90505b615dc081101561007457818160405160200161004d929190610173565b604051602081830303815290604052805190602001205f1c91508080600101915050610030565b505f81036100b7576040517f08c379a00000000000000000000000000000000000000000000000000000000081526004016100ae906101f4565b60405180910390fd5b005b5f5ffd5b6100d760048036038101906100d291906102d5565b6100d9565b005b5f5f8473ffffffffffffffffffffffffffffffffffffffff1634858560405161010392919061036e565b5f6040518083038185875af1925050503d805f811461013d576040519150601f19603f3d011682016040523d82523d5f602084013e610142565b606091505b50915091508161015457805160208201fd5b5050505050565b5f819050919050565b61016d8161015b565b82525050565b5f6040820190506101865f830185610164565b6101936020830184610164565b9392505050565b5f82825260208201905092915050565b7f6275726e656400000000000000000000000000000000000000000000000000005f82015250565b5f6101de60068361019a565b91506101e9826101aa565b602082019050919050565b5f6020820190508181035f83015261020b816101d2565b9050919050565b5f5ffd5b5f5ffd5b5f73ffffffffffffffffffffffffffffffffffffffff82169050919050565b5f6102438261021a565b9050919050565b61025381610239565b811461025d575f5ffd5b50565b5f8135905061026e8161024a565b92915050565b5f5ffd5b5f5ffd5b5f5ffd5b5f5f83601f84011261029557610294610274565b5b8235905067ffffffffffffffff8111156102b2576102b1610278565b5b6020830191508360018202830111156102ce576102cd61027c565b5b9250929050565b5f5f5f604084860312156102ec576102eb610212565b5b5f6102f986828701610260565b935050602084013567ffffffffffffffff81111561031a57610319610216565b5b61032686828701610280565b92509250509250925092565b5f81905092915050565b828183375f83830152505050565b5f6103558385610332565b935061036283858461033c565b82840190509392505050565b5f61037a82848661034a565b9150819050939250505056fea2646970667358221220936617c1b43714235f54295f87cc5ee1ed4e6e8f6b29fa6d54db92114696965d64736f6c634300081c0033' as Hex;

type Reply = { id?: string; status?: string; error?: string; permanent?: boolean; retryAfter?: number };
type IntentStatus = { status: string; txHash?: Hex; positionId?: string; error?: string };
type Check = (name: string, ok: boolean, detail?: string) => void;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function runAbuse(check: Check, d: Deployment): Promise<void> {
  const router = d.tradeRouter;
  const attacker = clients(d, ATTACKER_KEY);
  const victim = clients(d, VICTIM_KEY);
  const pub = victim.pub;
  const read = <T>(address: Address, abi: Abi, fn: string, args: readonly unknown[] = []) =>
    pub.readContract({ address, abi, functionName: fn, args }) as Promise<T>;
  const chainNow = async () => (await pub.getBlock()).timestamp;

  const post = (url: string, body: unknown, headers: Record<string, string> = {}): Promise<{ code: number; body: Reply }> =>
    fetch(`${url}/intents`, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) }).then(
      async (res) => ({ code: res.status, body: (await res.json().catch(() => ({}))) as Reply }),
    );
  const statusOf = (url: string, id: string): Promise<IntentStatus> => {
    const [who, nonce] = id.split(':');
    return fetch(`${url}/intents/${who}/${nonce}`).then((r) => r.json() as Promise<IntentStatus>);
  };
  async function waitTerminal(url: string, id: string, timeoutMs = 60_000): Promise<IntentStatus> {
    const until = Date.now() + timeoutMs;
    for (;;) {
      const st = await statusOf(url, id);
      if (['confirmed', 'failed', 'expired'].includes(st.status) || Date.now() > until) return st;
      await sleep(400);
    }
  }

  // Authorize a session key for `who` (one wallet tx), optionally depositing ETH. Returns the key + generation.
  async function authorize(who: typeof victim, limits: Limits, valueWei = 0n): Promise<{ session: SessionKey; generation: number }> {
    const session = await createSessionKey();
    const { request } = await pub.simulateContract({
      address: router,
      abi: fullRouterAbi,
      functionName: 'authorize',
      args: [session.qx, session.qy, limits],
      value: valueWei,
      account: who.account,
    });
    await pub.waitForTransactionReceipt({ hash: await who.wallet.writeContract(request) });
    const generation = await read<number>(router, fullRouterAbi, 'generationOf', [who.account.address]);
    return { session, generation };
  }

  const openLimits = (expiry: bigint): Limits => ({
    expiry,
    actions: ACT_OPEN | ACT_CLOSE_OWN | ACT_CLOSE_ANY | ACT_WITHDRAW,
    maxLeverage: 10,
    openSlipTicks: 300,
    closeSlipTicks: 600,
    maxStakePerTrade: parseEther('0.1'),
    maxOpenStake: parseEther('0.5'),
    dailyBudget: parseEther('1'),
  });

  // Shared sessions set up once.
  const expiry = (await chainNow()) + 86_400n;
  const v = await authorize(victim, openLimits(expiry), parseEther('1'));
  const vBase = { owner: victim.account.address as Address, key: v.session.key, generation: v.generation };
  const signV = <K extends Kind>(kind: K, intent: IntentOf[K]) => signIntent(v.session.privateKey, kind, intent, d.chainId, router);

  async function openIntent(stake: bigint, limitTick?: number): Promise<IntentOf['open']> {
    const q = await read<{ entryTick: number }>(d.lens, lensAbi, 'quoteOpen', [0n, true, 2, stake]);
    const tick = limitTick ?? Math.min(8_388_607, q.entryTick + 100);
    return { ...vBase, marketId: 0, isLong: true, leverage: 2, stake, limitTick: tick, nonce: randomNonce(), deadline: deadlineFrom(await chainNow(), 90n) };
  }

  // ---------------------------------------------------------------- F17 first (victim still has a clean budget)
  // Group-1 relayer: high IP limit so the many localhost posts don't trip the per-IP brake while we probe the
  // per-owner behaviour; owner limit kept at the default 20/min, which is what F17 is about.
  const r1 = await start({ port: 0, ipPerMin: 1_000_000, ownerPerMin: 20, maxPendingPerOwner: 2 });
  try {
    // F17: 25 unauthenticated junk intents naming the victim (bad deadline -> pre-auth) must NOT use the
    // victim's per-owner budget. Before the fix the owner bucket was charged first, so the 21st returned 429 and
    // the victim's own next intent was locked out.
    const junk: number[] = [];
    for (let i = 0; i < 25; i++) {
      const bad = { ...vBase, amount: 0n, nonce: randomNonce(), deadline: 1n };
      const res = await post(r1.url, bodyFor('withdraw', bad, await signV('withdraw', bad)));
      junk.push(res.code);
    }
    const allJunk400 = junk.every((c) => c === 400);
    const victimOpen = await openIntent(parseEther('0.02'));
    const victimRes = await post(r1.url, bodyFor('open', victimOpen, await signV('open', victimOpen)));
    check(
      'F17: junk naming a victim is not charged to the victim; victim can still submit',
      allJunk400 && victimRes.code === 202,
      `junk codes ${junk[0]}..x25, victim ${victimRes.code} ${victimRes.body.status ?? victimRes.body.error}`,
    );
    const vOpenSt = await waitTerminal(r1.url, victimRes.body.id!);
    const vPositionId = BigInt(vOpenSt.positionId ?? 0);
    check('F17: victim open confirmed', vOpenSt.status === 'confirmed' && vPositionId > 0n, `position ${vOpenSt.positionId}`);

    // ------------------------------------------------------------------ F6: impossible-limitTick open flood
    // The attacker needs only a session (no deposit): an Open with limitTick = MIN_TICK reverts PriceMoved, which
    // is temporary, before the balance check. The per-owner pending cap (2) bounds how many can sit in the queue.
    const a = await authorize(attacker, { ...openLimits(expiry), actions: ACT_OPEN }, 0n);
    const aBase = { owner: attacker.account.address as Address, key: a.session.key, generation: a.generation };
    const codes: number[] = [];
    for (let i = 0; i < 4; i++) {
      const junkOpen: IntentOf['open'] = {
        ...aBase,
        marketId: 0,
        isLong: true,
        leverage: 2,
        stake: parseEther('0.02'),
        limitTick: MIN_TICK,
        nonce: randomNonce(),
        deadline: deadlineFrom(await chainNow(), 90n),
      };
      const res = await post(r1.url, bodyFor('open', junkOpen, await signIntent(a.session.privateKey, 'open', junkOpen, d.chainId, router)));
      codes.push(res.code);
    }
    const accepted = codes.filter((c) => c === 202).length;
    const refused = codes.filter((c) => c === 429).length;
    check(
      'F6: impossible-limitTick open flood is capped per owner (2 queued, rest 429)',
      accepted === 2 && refused === 2,
      `codes ${codes.join(',')}`,
    );
    // The queue is not stalled: an honest open from a different owner still goes through while the junk loops.
    const honest = await openIntent(parseEther('0.02'));
    const honestRes = await post(r1.url, bodyFor('open', honest, await signV('open', honest)));
    const honestSt = await waitTerminal(r1.url, honestRes.body.id!);
    check('F6: an honest intent still gets through the flood', honestRes.code === 202 && honestSt.status === 'confirmed', honestSt.status);

    // ------------------------------------------------------------------ F5: uncapped relayer gas
    // Deploy a burner contract as the owner, give it a withdraw-only session, then post Withdraw{amount:0}. The
    // 0-wei transfer runs the burner's gas-eating receive(); its estimate blows past the gas ceiling, so the
    // relayer refuses it permanently and sends nothing.
    const create = await attacker.wallet.deployContract({ abi: [] as Abi, bytecode: BURNER_BYTECODE });
    const burner = (await pub.waitForTransactionReceipt({ hash: create })).contractAddress as Address;
    const burnSession = await createSessionKey();
    const burnLimits: Limits = {
      expiry,
      actions: ACT_WITHDRAW,
      maxLeverage: 1,
      openSlipTicks: 0,
      closeSlipTicks: 0,
      maxStakePerTrade: 0n,
      maxOpenStake: 0n,
      dailyBudget: 0n,
    };
    const authData = encodeFunctionData({ abi: fullRouterAbi, functionName: 'authorize', args: [burnSession.qx, burnSession.qy, burnLimits] });
    const call2 = encodeFunctionData({
      abi: [{ type: 'function', name: 'call2', stateMutability: 'payable', inputs: [{ type: 'address' }, { type: 'bytes' }], outputs: [] }],
      functionName: 'call2',
      args: [router, authData],
    });
    await pub.waitForTransactionReceipt({ hash: await attacker.wallet.sendTransaction({ to: burner, data: call2 }) });
    const burnGen = await read<number>(router, fullRouterAbi, 'generationOf', [burner]);
    const grief: IntentOf['withdraw'] = { owner: burner, key: burnSession.key, generation: burnGen, amount: 0n, nonce: randomNonce(), deadline: deadlineFrom(await chainNow(), 90n) };
    const griefSig = await signIntent(burnSession.privateKey, 'withdraw', grief, d.chainId, router);
    const griefRes = await post(r1.url, bodyFor('withdraw', grief, griefSig));
    const nonceUsed = await read<boolean>(router, fullRouterAbi, 'nonceUsed', [burner, grief.nonce]);
    check(
      'F5: a gas-burning Withdraw(0) is refused by the gas ceiling, nothing sent',
      griefRes.code === 400 && griefRes.body.error === 'GasTooHigh' && griefRes.body.permanent === true && nonceUsed === false,
      `${griefRes.code} ${griefRes.body.error}, nonceUsed ${nonceUsed}`,
    );

    // ------------------------------------------------------------------ F41: concurrent identical POSTs
    // Two identical withdraw POSTs fired together must create exactly one job, which confirms. Before the fix
    // both were queued and the surviving status reported 'failed NonceUsed' for an intent that executed.
    const dup: IntentOf['withdraw'] = { ...vBase, amount: parseEther('0.001'), nonce: randomNonce(), deadline: deadlineFrom(await chainNow(), 90n) };
    const dupBody = bodyFor('withdraw', dup, await signV('withdraw', dup));
    const [p1, p2] = await Promise.all([post(r1.url, dupBody), post(r1.url, dupBody)]);
    const dupCodes = [p1.code, p2.code].sort();
    const oneQueued = dupCodes[0] === 202 && (dupCodes[1] === 202 || dupCodes[1] === 400);
    const dupSt = await waitTerminal(r1.url, `${dup.owner}:${dup.nonce}`);
    check(
      'F41: concurrent identical POSTs queue one job and report it confirmed',
      oneQueued && dupSt.status === 'confirmed',
      `codes ${p1.code}/${p2.code}, final ${dupSt.status}${dupSt.error ? ' ' + dupSt.error : ''}`,
    );

    // ------------------------------------------------------------------ F21: executed intent reported confirmed
    // Open a position, post a close that is TooSoon (so it sits pending, retrying), then land the same signed
    // close directly from the wallet once the hold passes. The relayer must report the close 'confirmed', never
    // 'failed NonceUsed'.
    const openForClose = await openIntent(parseEther('0.02'));
    const ofcRes = await post(r1.url, bodyFor('open', openForClose, await signV('open', openForClose)));
    const ofcSt = await waitTerminal(r1.url, ofcRes.body.id!);
    const pid = BigInt(ofcSt.positionId ?? 0);
    const closeIntent: IntentOf['close'] = { ...vBase, positionId: pid, limitTick: MIN_TICK, nonce: randomNonce(), deadline: deadlineFrom(await chainNow(), 90n) };
    const closeSig = await signV('close', closeIntent);
    const closeRes = await post(r1.url, bodyFor('close', closeIntent, closeSig)); // TooSoon -> pending
    await sleep(12_000); // wait past the 10 s minimum hold
    // Land the exact signed close directly from the owner's wallet (a "backup submitter").
    try {
      const { request } = await pub.simulateContract({
        address: router,
        abi: fullRouterAbi,
        functionName: 'close',
        args: [closeIntent, closeSig.r, closeSig.s],
        account: victim.account,
      });
      await pub.waitForTransactionReceipt({ hash: await victim.wallet.writeContract(request) });
    } catch {
      // The relayer may have already landed it; either way the status below is the real test.
    }
    const closeSt = await waitTerminal(r1.url, closeRes.body.id!);
    const chainNonceUsed = await read<boolean>(router, fullRouterAbi, 'nonceUsed', [victim.account.address, closeIntent.nonce]);
    check(
      'F21: an intent that executed on-chain is reported confirmed, not failed',
      closeRes.code === 202 && closeSt.status === 'confirmed' && chainNonceUsed === true,
      `final ${closeSt.status}${closeSt.error ? ' ' + closeSt.error : ''}, nonceUsed ${chainNonceUsed}`,
    );
  } finally {
    await r1.close();
  }

  // ------------------------------------------------------------------ F20: X-Forwarded-For spoofing
  // A proxy appends the real client IP on the right. With a low per-IP limit, rotating only the leftmost (client
  // controlled) entry must NOT dodge the limit: every request keys on the appended rightmost IP.
  const r2 = await start({ port: 0, trustProxy: true, trustProxyHops: 1, ipPerMin: 20, ownerPerMin: 1_000_000 });
  try {
    let rotating429 = 0;
    for (let i = 0; i < 30; i++) {
      const res = await post(r2.url, {}, { 'x-forwarded-for': `203.0.113.${i}, 127.0.0.1` });
      if (res.code === 429) rotating429++;
    }
    check(
      'F20: rotating the leftmost X-Forwarded-For no longer bypasses the per-IP limit',
      rotating429 > 0,
      `${rotating429}/30 rotating-XFF requests were rate limited`,
    );
  } finally {
    await r2.close();
  }

  // ------------------------------------------------------------------ F43: error classification (no chain)
  const errData = (abi: Abi, errorName: string, args?: readonly unknown[]) =>
    new ContractFunctionRevertedError({ abi, data: encodeErrorResult(args ? { abi, errorName, args } : { abi, errorName } as never), functionName: 'open' });
  const errorAbi = [
    { type: 'error', name: 'Error', inputs: [{ type: 'string' }] },
    { type: 'error', name: 'Panic', inputs: [{ type: 'uint256' }] },
  ] as Abi;

  const oldReason = classify(errData(errorAbi, 'Error', ['OLD']));
  check('F43: Error("OLD") from the oracle maps to temporary OracleDown', oldReason.error === 'OracleDown' && oldReason.temporary === true, JSON.stringify(oldReason));

  const stale = classify(errData(routerAbi, 'Stale'));
  check('F43: oracle Stale() decodes (ABI merged) and is temporary', stale.error === 'OracleDown' && stale.temporary === true, JSON.stringify(stale));

  const notEnough = classify(errData(routerAbi, 'NotEnoughHistory'));
  check('F43: oracle NotEnoughHistory() is not a raw selector', notEnough.error === 'OracleDown', JSON.stringify(notEnough));

  const intrinsic = classify(new IntrinsicGasTooHighError({ gas: 35_416_360n }));
  check('F43: gas-over-block-limit is permanent, not retried', intrinsic.error === 'GasTooHigh' && intrinsic.temporary === false, JSON.stringify(intrinsic));

  const rpc = classify(new Error('socket hang up'));
  check('F43: a plain RPC error stays temporary', rpc.temporary === true && rpc.reverted === false, JSON.stringify(rpc));

  const overLimit = classify(errData(routerAbi, 'OverLimit'));
  check('F43: a permanent custom revert (OverLimit) stays permanent', overLimit.error === 'OverLimit' && overLimit.temporary === false, JSON.stringify(overLimit));
}
