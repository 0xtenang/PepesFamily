// Fee jobs for CreatorFeeRouterV2, the platform token's creator-fee recipient on Pons V2. keeper.ts runs them only
// when FEE_ROUTER is set. Every FEE_TICK_MS (default 15 s):
//   1. pokes the platform token's UniV4SampledOracle when a sample is due (FEE_ORACLE, else the router's oracle),
//   2. harvest() every HARVEST_EVERY_S (600) when the escrow, the router or the curve/hook holds more than
//      HARVEST_MIN_WEI for us,
//   3. topUpGas() every GAS_CHECK_S (600) when a registered gas wallet (relayer, keeper) is under GAS_LOW_BPS of its
//      target,
//   4. one buyback slice every BUYBACK_SLOT_S (600): buybackBalance spread over the rest of the BUYBACK_SPREAD_S
//      (24 h) period, quoted with eth_call, minOut = quote x (1 - BUYBACK_SLIP_BPS), skipped when a router guard
//      would refuse it,
//   5. alerts (logged as "ALERT"): a Pons owner proposal to move our fee recipient, the recipient actually moving,
//      and no fee sweep for SWEEP_ALERT_S (24 h) while fees are pending.
// Everything is simulated before it is sent, so a job that would revert costs no gas, and sent with a gas margin.
//
//   FEE_ROUTER=0x… DEPLOYMENT=… KEEPER_PRIVATE_KEY=0x… node src/keeper.ts

import { parseAbi, type Abi, type Address, type Hex } from 'viem';
import routerAbiJson from '../../abi/CreatorFeeRouterV2.json' with { type: 'json' };
import v4OracleAbiJson from '../../abi/UniV4SampledOracle.json' with { type: 'json' };
import { log, why, type Clients, type Sender } from './config.ts';

const routerAbi = routerAbiJson as Abi;
const v4OracleAbi = v4OracleAbiJson as Abi;

// Pons V2 views and events, from the published source (selectors and topics checked against the deployed bytecode).
const escrowAbi = parseAbi(['function balanceOf(address recipient) view returns (uint256)']);
const factoryAbi = parseAbi([
  'function pendingCreatorFeeRecipient(address token) view returns (address newRecipient, uint256 effectiveAt, uint256 expiresAt)',
  'event CreatorFeeRecipientChangeProposed(address indexed token, address indexed currentRecipient, address indexed proposedRecipient, uint256 effectiveAt, uint256 expiresAt)',
  'event CreatorFeeRecipientUpdated(address indexed token, address indexed previousRecipient, address indexed newRecipient)',
]);
const curveAbi = parseAbi([
  'function graduated() view returns (bool)',
  'function quoteFeeBalance() view returns (uint256)',
  'function creatorTaxBalance() view returns (uint256)',
  'function buybackQuoteBalance() view returns (uint256)',
  'function protocolFeeShareBps() view returns (uint16)',
  'event FeesSwept(uint256 protocolAmount, uint256 buybackAmount, uint256 creatorAmount)',
]);
const hookAbi = parseAbi([
  'function pendingFees(bytes32 poolId, address currency) view returns (uint256)',
  'function pendingCreatorTax(bytes32 poolId, address currency) view returns (uint256)',
  'event PoolFeesSwept(bytes32 indexed poolId, uint256 protocolAmount, uint256 buybackAmount, uint256 creatorAmount, uint256 tokensLocked)',
]);
const watchedEvents = [factoryAbi[1], factoryAbi[2], curveAbi[5], hookAbi[2]] as const;

const ZERO = '0x0000000000000000000000000000000000000000' as Address;
const ZERO32 = `0x${'0'.repeat(64)}` as Hex;
const BPS = 10_000n;

const num = (name: string, fallback: number) => Number(process.env[name] ?? fallback);
const big = (name: string, fallback: bigint) => BigInt(process.env[name] ?? fallback);

const cfg = {
  tickMs: num('FEE_TICK_MS', 15_000),
  harvestEvery: big('HARVEST_EVERY_S', 600n),
  harvestMin: big('HARVEST_MIN_WEI', 500_000_000_000_000n), // 0.0005 ETH
  gasEvery: big('GAS_CHECK_S', 600n),
  gasLowBps: big('GAS_LOW_BPS', 5000n), // top up below 50% of target
  slot: big('BUYBACK_SLOT_S', 600n),
  spread: big('BUYBACK_SPREAD_S', 86_400n),
  buybackMin: big('BUYBACK_MIN_WEI', 10_000_000_000_000n), // 0.00001 ETH: smaller slices wait
  slipBps: big('BUYBACK_SLIP_BPS', 50n), // minOut = quote x 0.995
  sweepAlert: big('SWEEP_ALERT_S', 86_400n),
  alertRepeat: big('ALERT_REPEAT_S', 3_600n),
  logRange: big('LOG_RANGE', 199n), // the public drpc endpoint refuses getLogs ranges of 200 blocks or more
  logMaxRanges: num('LOG_MAX_RANGES', 50),
};

type GasWallet = { wallet: Address; target: bigint };

/** Pons wiring read from the router once; `token`, `curve` and `poolId` are re-read until the token is set. */
type Wiring = { escrow: Address; factory: Address; hook: Address; token: Address; curve: Address; poolId: Hex; shareBps: bigint };

/** `tx` is the keeper's Sender: both send from the keeper's account, and it numbers their transactions. */
export async function createFeeJobs({ pub, account, tx }: Clients & { tx: Sender }, router: Address, skipOracles: Address[] = []) {
  const read = <T>(address: Address, abi: Abi, functionName: string, args: readonly unknown[] = []) =>
    pub.readContract({ address, abi, functionName, args }) as Promise<T>;
  const r = <T>(functionName: string, args: readonly unknown[] = []) => read<T>(router, routerAbi, functionName, args);
  /** A read that may fail (a Pons contract not deployed yet, a feed down): undefined instead of throwing. */
  const tryRead = async <T>(p: Promise<T>): Promise<T | undefined> => {
    try {
      return await p;
    } catch {
      return undefined;
    }
  };

  /** Simulate first so nothing that would revert costs gas; then send with a gas margin and wait. */
  function act(address: Address, abi: Abi, functionName: string, args: readonly unknown[], label: string) {
    return tx.one({ address, abi, functionName, args, label });
  }

  const w: Wiring = {
    escrow: await r<Address>('escrow'),
    factory: await r<Address>('factory'),
    hook: await r<Address>('ponsHook'),
    token: ZERO,
    curve: ZERO,
    poolId: ZERO32,
    shareBps: 3000n, // Pons's share of the base fee, replaced by the launch's own snapshot below
  };
  const pons = w.factory !== ZERO;

  const due = { harvest: 0n, gas: 0n, buyback: 0n };
  const alerted = new Map<string, bigint>(); // alert key -> last logged at
  const started = (await pub.getBlock()).timestamp;
  let lastSweepAt = started; // the keeper only knows about sweeps it has seen since it started
  let lastCredited = -1n; // totals.claimed + escrow balance: rises whenever a sweep pays us
  let logCursor = process.env.FEE_LOG_FROM_BLOCK ? BigInt(process.env.FEE_LOG_FROM_BLOCK) : await pub.getBlockNumber();
  let oracleNoted = '';

  function alert(key: string, now: bigint, ...parts: unknown[]) {
    const last = alerted.get(key);
    if (last !== undefined && now - last < cfg.alertRepeat) return;
    alerted.set(key, now);
    log('ALERT', ...parts);
  }

  async function refreshWiring() {
    if (w.token !== ZERO) return;
    w.token = await r<Address>('token');
    if (w.token === ZERO) return;
    w.curve = await r<Address>('curve');
    w.poolId = await r<Hex>('poolId');
    if (w.curve !== ZERO) w.shareBps = BigInt(await read<number>(w.curve, curveAbi, 'protocolFeeShareBps'));
    log(`fee router ${router}: token ${w.token}, curve ${w.curve}, pool ${w.poolId}`);
  }

  /** Creator fees we could sweep ourselves now: the curve before graduation, ETH-side hook fees after it. */
  async function sweepable(): Promise<{ ours: bigint; pendingAny: boolean }> {
    if (!pons || w.token === ZERO) return { ours: 0n, pendingAny: false };
    const graduated = w.curve === ZERO ? true : ((await tryRead(read<boolean>(w.curve, curveAbi, 'graduated'))) ?? true);
    if (!graduated) {
      const [fee, tax, buyback] = await Promise.all([
        read<bigint>(w.curve, curveAbi, 'quoteFeeBalance'),
        read<bigint>(w.curve, curveAbi, 'creatorTaxBalance'),
        read<bigint>(w.curve, curveAbi, 'buybackQuoteBalance'),
      ]);
      const ours = fee - (fee * w.shareBps) / BPS + tax;
      // A pending Pons buyback slice needs the operator (never the case while Pons buybacks stay off).
      return { ours: buyback === 0n ? ours : 0n, pendingAny: fee + tax > 0n };
    }
    if (w.poolId === ZERO32) return { ours: 0n, pendingAny: false };
    const [ethFee, ethTax, tokFee, tokTax] = await Promise.all([
      read<bigint>(w.hook, hookAbi, 'pendingFees', [w.poolId, ZERO]),
      read<bigint>(w.hook, hookAbi, 'pendingCreatorTax', [w.poolId, ZERO]),
      read<bigint>(w.hook, hookAbi, 'pendingFees', [w.poolId, w.token]),
      read<bigint>(w.hook, hookAbi, 'pendingCreatorTax', [w.poolId, w.token]),
    ]).catch(() => [0n, 0n, 0n, 0n]);
    // Token-denominated fees (from exact-input buys) need an internal swap: only the Pons operator can sweep then.
    const ours = tokFee + tokTax === 0n ? ethFee - (ethFee * w.shareBps) / BPS + ethTax : 0n;
    return { ours, pendingAny: ethFee + ethTax + tokFee + tokTax > 0n };
  }

  // ------------------------------------------------------------------ 1. oracle samples

  async function pokeOracle(now: bigint) {
    const oracle = (process.env.FEE_ORACLE as Address | undefined) ?? (await r<Address>('oracle'));
    if (oracle === ZERO || skipOracles.some((o) => o.toLowerCase() === oracle.toLowerCase())) return;
    const allowed = await tryRead(read<boolean>(oracle, v4OracleAbi, 'isKeeper', [account.address]));
    if (!allowed) {
      if (oracleNoted !== oracle) log(`fee oracle ${oracle}: this keeper is not approved (setKeeper), not poking`);
      oracleNoted = oracle;
      return;
    }
    const [[time], minInterval] = await Promise.all([
      read<[bigint, number]>(oracle, v4OracleAbi, 'latestSample'),
      read<number>(oracle, v4OracleAbi, 'minInterval'),
    ]);
    if (now >= time + BigInt(minInterval)) await act(oracle, v4OracleAbi, 'poke', [], `fee oracle sample ${oracle.slice(0, 8)}`);
  }

  // ------------------------------------------------------------------ 2. harvest

  async function harvest() {
    const [escrowBal, unallocated, pending] = await Promise.all([
      w.escrow === ZERO ? 0n : read<bigint>(w.escrow, escrowAbi as Abi, 'balanceOf', [router]),
      r<bigint>('unallocated'),
      sweepable(),
    ]);
    const min = cfg.harvestMin;
    if (escrowBal <= min && unallocated <= min && pending.ours <= min) return;
    await act(router, routerAbi, 'harvest', [], `fee harvest (escrow ${escrowBal}, router ${unallocated}, pending ${pending.ours})`);
  }

  // ------------------------------------------------------------------ 3. gas top-ups

  async function topUpGas(now: bigint) {
    const wallets = await r<GasWallet[]>('gasWallets');
    if (wallets.length === 0) return;
    const balances = await Promise.all(wallets.map((g) => pub.getBalance({ address: g.wallet })));
    const low = wallets.filter((g, i) => balances[i] * BPS < g.target * cfg.gasLowBps);
    if (low.length === 0) return;
    const [room, ops] = await Promise.all([r<bigint>('gasRoom'), r<bigint>('opsBalance')]);
    if (room === 0n || ops === 0n) {
      // Nobody else refills these wallets: a person has to.
      alert('gas-topup', now, `gas top-up needed for ${low.map((g) => g.wallet).join(', ')} but ${room === 0n ? 'the daily cap is used' : 'the ops bucket is empty'}`);
      return;
    }
    await act(router, routerAbi, 'topUpGas', [], `gas top-up (${low.length} low)`);
  }

  // ------------------------------------------------------------------ 4. buyback slices

  async function buybackSlice(now: bigint) {
    if (w.token === ZERO) return;
    const [paused, executor, oracle, nextAt, balance] = await Promise.all([
      r<boolean>('buybackPaused'),
      r<Address>('executor'),
      r<Address>('oracle'),
      r<bigint>('nextBuybackAt'),
      r<bigint>('buybackBalance'),
    ]);
    if (paused || executor === ZERO || oracle === ZERO || balance < cfg.buybackMin) return;
    if (now < nextAt) {
      // The last buy landed a little after its slot began: retry as soon as the router allows, not a slot later.
      if (nextAt < due.buyback) due.buyback = nextAt;
      return;
    }

    // Spend the bucket evenly over what is left of the current period: 144 ten-minute slots a day.
    const slotsLeft = (cfg.spread - (now % cfg.spread) + cfg.slot - 1n) / cfg.slot;
    let ethIn = balance / (slotsLeft > 0n ? slotsLeft : 1n);
    if (ethIn < cfg.buybackMin) ethIn = cfg.buybackMin;
    const cap = await tryRead(r<bigint>('buybackCap'));
    if (cap === undefined) return log('buyback: skipped (price feed down)');
    if (ethIn > cap) ethIn = cap;
    if (ethIn === 0n) return;

    // The router's own price guards, checked here so a refused slice is not even simulated.
    const [feed, maxDev, maxAbove] = await Promise.all([
      tryRead(read<[number, number, number, bigint]>(oracle, v4OracleAbi, 'read')),
      r<number>('maxSpotDevTicks'),
      r<number>('maxFastAboveSlowTicks'),
    ]);
    if (!feed) return log('buyback: skipped (price feed down)');
    const [spot, fast, slow] = feed;
    if (Math.abs(spot - fast) > maxDev) return log(`buyback: skipped (spot ${spot} vs fast ${fast})`);
    if (fast - slow > maxAbove) return log(`buyback: skipped (fast ${fast} above slow ${slow})`);

    let quote: bigint;
    try {
      const sim = await pub.simulateContract({ address: router, abi: routerAbi, functionName: 'buyback', args: [ethIn, 0n], account });
      quote = sim.result as bigint;
    } catch (e) {
      return log(`buyback: skipped (${why(e)})`);
    }
    const minOut = (quote * (BPS - cfg.slipBps)) / BPS;
    await act(router, routerAbi, 'buyback', [ethIn, minOut], `buyback ${ethIn} wei, min ${minOut} (quote ${quote}, ${slotsLeft} slots left)`);
  }

  // ------------------------------------------------------------------ 5. alerts

  async function alerts(now: bigint) {
    if (!pons || w.token === ZERO) return;
    const [current, proposal] = await Promise.all([
      r<Address>('currentFeeRecipient'),
      read<[Address, bigint, bigint]>(w.factory, factoryAbi as Abi, 'pendingCreatorFeeRecipient', [w.token]),
    ]);
    if (current.toLowerCase() !== router.toLowerCase()) {
      alert('moved', now, `Pons pays our creator fees to ${current}, not the router ${router}`);
    }
    if (proposal[0] !== ZERO) {
      alert(`proposal:${proposal[0]}`, now, `Pons owner proposed moving our fee recipient to ${proposal[0]}: executable from ${proposal[1]} until ${proposal[2]}`);
    }

    // A sweep that pays us raises claimed + escrow balance.
    const [totals, escrowBal, pending] = await Promise.all([
      r<readonly bigint[]>('totals'),
      read<bigint>(w.escrow, escrowAbi as Abi, 'balanceOf', [router]),
      sweepable(),
    ]);
    const credited = totals[0] + escrowBal;
    if (lastCredited >= 0n && credited > lastCredited) lastSweepAt = now;
    lastCredited = credited;
    if (pending.pendingAny && now - lastSweepAt >= cfg.sweepAlert) {
      alert('nosweep', now, `no fee sweep for ${(now - lastSweepAt) / 3600n} h while fees are pending on Pons`);
    }
  }

  /** Recipient-change and sweep events since the last pass, in ranges the RPC accepts. */
  async function scanLogs(now: bigint) {
    if (!pons || w.token === ZERO) return;
    const latest = await pub.getBlockNumber();
    const addresses = [w.factory, w.hook, ...(w.curve === ZERO ? [] : [w.curve])];
    for (let i = 0; i < cfg.logMaxRanges && logCursor <= latest; i++) {
      const to = logCursor + cfg.logRange - 1n < latest ? logCursor + cfg.logRange - 1n : latest;
      const logs = await pub.getLogs({ address: addresses, events: watchedEvents, fromBlock: logCursor, toBlock: to });
      for (const l of logs) {
        const args = l.args as Record<string, unknown>;
        const from = l.address.toLowerCase();
        if (l.eventName === 'CreatorFeeRecipientChangeProposed' && eq(args.token, w.token)) {
          alert(`proposed:${l.transactionHash}`, now, `Pons proposed moving our fee recipient to ${args.proposedRecipient} (tx ${l.transactionHash}, effective ${args.effectiveAt})`);
        } else if (l.eventName === 'CreatorFeeRecipientUpdated' && from === w.factory.toLowerCase() && eq(args.token, w.token)) {
          alert(`updated:${l.transactionHash}`, now, `our fee recipient changed ${args.previousRecipient} -> ${args.newRecipient} (tx ${l.transactionHash})`);
        } else if (l.eventName === 'FeesSwept' && from === w.curve.toLowerCase()) {
          lastSweepAt = now;
        } else if (l.eventName === 'PoolFeesSwept' && from === w.hook.toLowerCase() && eq(args.poolId, w.poolId)) {
          lastSweepAt = now;
        }
      }
      logCursor = to + 1n;
    }
  }

  // ------------------------------------------------------------------ loop

  async function tick(force = false) {
    const now = (await pub.getBlock()).timestamp;
    await refreshWiring();
    const jobs: [string, () => Promise<unknown>][] = [['oracle', () => pokeOracle(now)]];
    if (force || now >= due.harvest) {
      due.harvest = now + cfg.harvestEvery;
      jobs.push(['harvest', harvest]);
    }
    if (force || now >= due.gas) {
      due.gas = now + cfg.gasEvery;
      jobs.push(['gas', () => topUpGas(now)]);
    }
    if (force || now >= due.buyback) {
      due.buyback = now - (now % cfg.slot) + cfg.slot; // on the slot boundary
      jobs.push(['buyback', () => buybackSlice(now)]);
    }
    jobs.push(['alerts', () => alerts(now)], ['logs', () => scanLogs(now)]);
    // One at a time, each waiting for its own transaction (the keeper's Sender keeps the nonces in order).
    for (const [name, job] of jobs) {
      try {
        await job();
      } catch (e) {
        log(`fee job ${name} failed:`, why(e));
      }
    }
  }

  log(`fee jobs for router ${router}${pons ? ` (Pons factory ${w.factory})` : ' (no Pons: splitter only)'}, every ${cfg.tickMs} ms`);
  return { tick, intervalMs: cfg.tickMs };
}

function eq(a: unknown, b: string) {
  return typeof a === 'string' && a.toLowerCase() === b.toLowerCase();
}
