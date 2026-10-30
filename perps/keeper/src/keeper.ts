// MemeLev keeper. Every few seconds, most urgent first:
//   1. records prices for Uniswap V4 coins (UniV4SampledOracle), and waits for them, so step 3 sees live feeds,
//   2. fires the rug guard on any coin whose fast price crashed under its slow price,
//   3. refreshes each coin's last good price: every REFRESH_OPEN_SECONDS (15 s) on coins with open positions and every
//      REFRESH_SECONDS (120 s) on the rest; at once when a feed starts failing (starts the stale clock) or comes back
//      (clears it), and every REFRESH_OPEN_SECONDS while it stays down with positions open,
//   4. liquidates, then closes at max win, then settles rugged shorts, then fires take-profits and stop-losses and
//      fills orders whose trigger price has been reached (refunding expired ones), at most MAX_ACTIONS a pass (the
//      next pass starts at once if more are waiting). A short at max win on a coin whose spot price has fallen to
//      the rug level is not closed: it waits for the rug guard, which settles it at the rug cap instead,
//   5. withdraws its liquidation rewards to its wallet and logs an ALERT when its gas money runs low.
// Each step's transactions are simulated together, sent back to back and confirmed together (see Sender in
// config.ts), and every coin, oracle and step is isolated, so one failing read can't stop the others.
// With FEE_ROUTER set it also runs the platform token's fee jobs on their own timer (src/fees.ts): harvest, gas
// top-ups, buyback slices, price samples for the token's own pool, and alerts.
// Anyone can run one; every action is permissionless except V4 price samples, which need an approved keeper.
//
//   node src/keeper.ts                 local anvil stack (contracts/deployments/local.json)
//   node src/keeper.ts --once          one pass, then exit
//   DEPLOYMENT=… KEEPER_PRIVATE_KEY=0x… V4_ORACLES=0x…,0x… node src/keeper.ts
//   FEE_ROUTER=0x… …                   plus the fee jobs

import {
  BaseError,
  ContractFunctionRevertedError,
  ContractFunctionZeroDataError,
  formatEther,
  getAddress,
  isAddress,
  parseAbi,
  type Abi,
  type Address,
} from 'viem';
import exchangeAbiJson from '../../abi/LevExchange.json' with { type: 'json' };
import lensAbiJson from '../../abi/LevLens.json' with { type: 'json' };
import v3OracleAbiJson from '../../abi/UniV3Oracle.json' with { type: 'json' };
import v4OracleAbiJson from '../../abi/UniV4SampledOracle.json' with { type: 'json' };
import { ANVIL_KEYS, alert, clients, createSender, keyFor, loadDeployment, log, why, type Call } from './config.ts';
import { createFeeJobs } from './fees.ts';

const exchangeAbi = exchangeAbiJson as Abi;
const lensAbi = lensAbiJson as Abi;
const v4OracleAbi = v4OracleAbiJson as Abi;
// Every listed coin's feed (UniV3Oracle, UniV4SampledOracle) implements IPriceOracle.read(); their errors are added so
// a failing read logs as, say, Stale.
const priceFeedAbi = [
  ...parseAbi(['function read() view returns (int24 spotTick, int24 fastTick, int24 slowTick, uint256 liquidityEth)']),
  ...[...(v3OracleAbiJson as Abi), ...v4OracleAbi].filter((x) => x.type === 'error'),
] as const;

const INTERVAL_MS = Number(process.env.INTERVAL_MS ?? 4000);
const REFRESH_SECONDS = BigInt(process.env.REFRESH_SECONDS ?? 120); // coins without open positions
const REFRESH_OPEN_SECONDS = BigInt(process.env.REFRESH_OPEN_SECONDS ?? 15); // coins with open positions
const MAX_ACTIONS = Number(process.env.MAX_ACTIONS ?? 50); // liquidations, max-win closes and rug settlements a pass
const GAS_ALERT_WEI = BigInt(process.env.GAS_ALERT_WEI ?? 10n ** 16n); // 0.01 ETH
const GAS_EXIT_WEI = BigInt(process.env.GAS_EXIT_WEI ?? 0n); // exit with code 2 below this, for a supervisor; 0: never
const REWARD_WITHDRAW_MIN_WEI = BigInt(process.env.REWARD_WITHDRAW_MIN_WEI ?? 10n ** 15n); // 0.001 ETH
const PAGE = 200n;
const READ_CONCURRENCY = 25;
const BPS = 10_000;
const DEFAULT_RUG_DROP_BPS = 8000; // the exchange's default; the live value is read every pass

const ACTION_LIQUIDATE = 1;
const ACTION_MAX_WIN = 2;
const ACTION_RUG_SETTLE = 3;
const ACTION_TAKE_PROFIT = 4;
const ACTION_STOP_LOSS = 5;
const ORDER_FILL = 1;
const ORDER_EXPIRED = 2;

type MarketView = { oracle: Address; lastGoodAt: bigint; downSince: bigint; longStake: bigint; shortStake: bigint };
type PositionView = { position: { isLong: boolean; marketId: number }; action: number };
/** A coin's feed as read with an eth_call. `reverted` false means the read itself failed (RPC trouble). */
type Feed = { ok: true; spot: number; fast: number; slow: number } | { ok: false; reverted: boolean; reason: string };
type MarketState = { id: number; view: MarketView; feed: Feed; hasOpen: boolean };

const d = loadDeployment();
const { account, pub, wallet } = clients(d, keyFor(d, 'KEEPER_PRIVATE_KEY', ANVIL_KEYS.keeper));
const exchange = d.exchange;
const tx = createSender({ pub, wallet, account });

function readAt<T>(address: Address, abi: Abi, functionName: string, args: readonly unknown[] = [], blockNumber?: bigint): Promise<T> {
  return pub.readContract({ address, abi, functionName, args, blockNumber }) as Promise<T>;
}

/** The contract (or the address) said no, as opposed to the RPC failing. A wrong guess only changes which refresh
 *  is sent; the contract's own read decides what it records. */
function isRevert(e: unknown): boolean {
  if (!(e instanceof BaseError)) return false;
  return !!e.walk(
    (x) =>
      x instanceof ContractFunctionRevertedError ||
      x instanceof ContractFunctionZeroDataError ||
      (x instanceof BaseError && /execution reverted/i.test(`${x.details} ${x.shortMessage}`)),
  );
}

async function mapLimit<T, R>(items: readonly T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const out = new Array<R>(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// ------------------------------------------------------------------ V4 oracles

/** V4_ORACLES, trimmed and checksummed. A malformed entry is a config error: stop before doing anything. */
function parseOracles(raw: string): Address[] {
  const out: Address[] = [];
  for (const part of raw.split(',')) {
    const s = part.trim();
    if (!s) continue;
    if (!isAddress(s, { strict: false })) throw new Error(`V4_ORACLES: "${s}" is not an address`);
    const a = getAddress(s);
    if (!out.includes(a)) out.push(a);
  }
  return out;
}

/** Drops entries that can never work (no contract, not a UniV4SampledOracle); keeps those the RPC could not check. */
async function checkOracles(list: Address[]): Promise<Address[]> {
  const ok: Address[] = [];
  for (const oracle of list) {
    try {
      const code = await pub.getCode({ address: oracle });
      if (!code || code === '0x') {
        alert(`v4-bad:${oracle}`, `V4_ORACLES: no contract at ${oracle} on chain ${d.chainId}; ignoring it`);
        continue;
      }
      await Promise.all([readAt(oracle, v4OracleAbi, 'latestSample'), readAt(oracle, v4OracleAbi, 'minInterval')]);
      ok.push(oracle);
    } catch (e) {
      if (isRevert(e)) {
        alert(`v4-bad:${oracle}`, `V4_ORACLES: ${oracle} is not a UniV4SampledOracle (${why(e)}); ignoring it`);
        continue;
      }
      log(`V4_ORACLES: could not check ${oracle} (${why(e)}); keeping it`);
      ok.push(oracle);
    }
  }
  return ok;
}

const V4_ORACLES = await checkOracles(parseOracles(process.env.V4_ORACLES ?? ''));

/** A poke for each V4 oracle whose next sample is due. Each oracle on its own: one bad oracle skips only itself. */
async function dueSamples(): Promise<Call[]> {
  if (V4_ORACLES.length === 0) return [];
  const now = (await pub.getBlock()).timestamp;
  const calls = await Promise.all(
    V4_ORACLES.map(async (oracle): Promise<Call | undefined> => {
      try {
        const [[time], minInterval, approved] = await Promise.all([
          readAt<readonly [bigint, number]>(oracle, v4OracleAbi, 'latestSample'),
          readAt<number>(oracle, v4OracleAbi, 'minInterval'),
          readAt<boolean>(oracle, v4OracleAbi, 'isKeeper', [account.address]),
        ]);
        if (!approved) {
          alert(`v4-keeper:${oracle}`, `V4 oracle ${oracle} has not approved this keeper (setKeeper(${account.address}, true)): nobody records its prices`);
          return undefined;
        }
        if (now < time + BigInt(minInterval)) return undefined;
        return { address: oracle, abi: v4OracleAbi, functionName: 'poke', args: [], label: `v4 sample ${oracle.slice(0, 8)}`, quiet: ['TooSoon'] };
      } catch (e) {
        log(`v4 oracle ${oracle}: read failed (${why(e)})`);
        return undefined;
      }
    }),
  );
  return calls.filter((c): c is Call => c !== undefined);
}

// ------------------------------------------------------------------ markets

async function readFeed(oracle: Address, blockNumber?: bigint): Promise<Feed> {
  try {
    const [spot, fast, slow] = await pub.readContract({ address: oracle, abi: priceFeedAbi, functionName: 'read', blockNumber });
    return { ok: true, spot, fast, slow };
  } catch (e) {
    return { ok: false, reverted: isRevert(e), reason: why(e) };
  }
}

/** Every market and its feed, read at one block. A market that can't be read is logged and left out of this pass. */
async function loadMarkets(at: bigint): Promise<(MarketState | undefined)[]> {
  const count = Number(await readAt<bigint>(exchange, exchangeAbi, 'marketCount', [], at));
  const ids = Array.from({ length: count }, (_, id) => id);
  return mapLimit(ids, READ_CONCURRENCY, async (id) => {
    try {
      const view = await readAt<MarketView>(d.lens, lensAbi, 'getMarket', [BigInt(id)], at);
      const feed = await readFeed(view.oracle, at);
      return { id, view, feed, hasOpen: view.longStake + view.shortStake > 0n };
    } catch (e) {
      log(`market ${id}: read failed (${why(e)})`);
      return undefined;
    }
  });
}

async function rugDropBps(at: bigint): Promise<number> {
  try {
    return Number((await readAt<{ rugDropBps: number }>(exchange, exchangeAbi, 'getConfig', [], at)).rugDropBps);
  } catch (e) {
    log(`config: read failed (${why(e)}), assuming a rug drop of ${DEFAULT_RUG_DROP_BPS / 100}%`);
    return DEFAULT_RUG_DROP_BPS;
  }
}

/** The feed's spot (or fast) price is at or under the rug guard's level: (1 - rugDropBps) of the slow price. */
function crashing(feed: Feed, dropBps: number): feed is Extract<Feed, { ok: true }> {
  return feed.ok && 1.0001 ** (Math.min(feed.spot, feed.fast) - feed.slow) * BPS <= BPS - dropBps;
}

const downPings = new Map<number, bigint>(); // market id -> when we last refreshed it while its feed was down

/** Why this market needs a refresh now ('' for a routine one), or undefined. */
function refreshReason(m: MarketState, now: bigint): string | undefined {
  const { downSince, lastGoodAt } = m.view;
  const down = downSince !== 0n;
  const due = now - lastGoodAt >= (m.hasOpen ? REFRESH_OPEN_SECONDS : REFRESH_SECONDS);
  if (m.feed.ok) {
    downPings.delete(m.id);
    // A recovered feed must clear the stale clock at once, or a later one-block failure would let positions settle
    // straight away at a last good price that may be hours old.
    if (down) return 'feed is back: clears the stale clock';
    return due ? '' : undefined;
  }
  // A read that reverted means the feed is down; one that failed for another reason (RPC trouble) tells us nothing,
  // so the refresh then just keeps its schedule and the contract's own read decides.
  if (!down) return !m.feed.reverted ? (due ? '' : undefined) : `feed is down (${m.feed.reason}): starts the stale clock`;
  // Still down: keep recording the failure while positions depend on the stale clock.
  if (!m.hasOpen || now - (downPings.get(m.id) ?? downSince) < REFRESH_OPEN_SECONDS) return undefined;
  return m.feed.reverted ? `feed still down (${m.feed.reason})` : '';
}

function marketCalls(markets: (MarketState | undefined)[], now: bigint): Call[] {
  const guards: Call[] = [];
  const refreshes: Call[] = [];
  for (const m of markets) {
    if (!m) continue;
    const id = BigInt(m.id);
    // The contract decides whether this is a real crash; the simulation simply fails if not. A feed that reverts
    // can't fire it, so skip those.
    if (m.feed.ok || !m.feed.reverted) {
      guards.push({ address: exchange, abi: exchangeAbi, functionName: 'triggerRugGuard', args: [id], label: `market ${m.id} rug guard`, quiet: ['NoRug', 'MarketLocked'] });
    }
    const reason = refreshReason(m, now);
    if (reason === undefined) continue;
    if (!m.feed.ok) downPings.set(m.id, now);
    refreshes.push({
      address: exchange,
      abi: exchangeAbi,
      functionName: 'refresh',
      args: [id],
      label: `market ${m.id} refresh${reason ? ` (${reason})` : ''}`,
      quietSuccess: reason === '',
    });
  }
  return [...guards, ...refreshes];
}

// ------------------------------------------------------------------ positions

const held = new Set<bigint>(); // shorts whose max-win close waits for the rug guard (logged once)

/** Max-win closes to send: shorts on a coin that is crashing to the rug level wait for the rug guard instead. */
async function closableAtMaxWin(ids: bigint[], at: bigint, dropBps: number, markets: (MarketState | undefined)[]): Promise<bigint[]> {
  if (ids.length === 0) return ids;
  const views = await mapLimit(ids, READ_CONCURRENCY, (id) =>
    readAt<PositionView>(d.lens, lensAbi, 'getPosition', [id], at).catch((e) => {
      log(`position ${id}: read failed (${why(e)}), not closing it this pass`);
      return undefined;
    }),
  );
  const feeds = new Map<number, Promise<Feed>>();
  const feedOf = (marketId: number) => {
    let f = feeds.get(marketId);
    if (!f) {
      const known = markets[marketId]?.view.oracle;
      const oracle = known ? Promise.resolve(known) : readAt<MarketView>(d.lens, lensAbi, 'getMarket', [BigInt(marketId)], at).then((v) => v.oracle);
      f = oracle.then((o) => readFeed(o, at)).catch((e): Feed => ({ ok: false, reverted: false, reason: why(e) }));
      feeds.set(marketId, f);
    }
    return f;
  };
  const keep: bigint[] = [];
  for (let i = 0; i < ids.length; i++) {
    const id = ids[i];
    const v = views[i];
    if (!v) continue;
    if (!v.position.isLong) {
      const marketId = Number(v.position.marketId);
      const feed = await feedOf(marketId);
      if (crashing(feed, dropBps)) {
        if (!held.has(id)) {
          const pct = (1.0001 ** (Math.min(feed.spot, feed.fast) - feed.slow) * 100).toFixed(1);
          log(`position ${id} closeAtMaxWin: held, market ${marketId} is at ${pct}% of its slow price; waiting for the rug guard`);
        }
        held.add(id);
        continue;
      }
    }
    held.delete(id);
    keep.push(id);
  }
  return keep;
}

/** Liquidations, then max-win closes, then rug settlements, all from one read of the open positions at one block. */
async function positionCalls(dropBps: number, markets: (MarketState | undefined)[]): Promise<Call[]> {
  // One block for the count and every page: a close between page reads would otherwise move a position into a page
  // already read, and it would be missed this pass.
  const at = await pub.getBlockNumber();
  const open = await readAt<bigint>(exchange, exchangeAbi, 'openPositionCount', [], at);
  const offsets: bigint[] = [];
  for (let o = 0n; o < open; o += PAGE) offsets.push(o);
  const pages = await mapLimit(offsets, READ_CONCURRENCY, (offset) =>
    readAt<readonly [readonly bigint[], readonly number[]]>(d.lens, lensAbi, 'actionable', [offset, PAGE], at).catch((e) => {
      log(`positions from ${offset}: read failed (${why(e)})`);
      return [[], []] as const;
    }),
  );
  const liquidate: bigint[] = [];
  const maxWin: bigint[] = [];
  const settle: bigint[] = [];
  const triggered: bigint[] = [];
  for (const [ids, actions] of pages) {
    ids.forEach((id, i) => {
      if (actions[i] === ACTION_LIQUIDATE) liquidate.push(id);
      else if (actions[i] === ACTION_MAX_WIN) maxWin.push(id);
      else if (actions[i] === ACTION_RUG_SETTLE) settle.push(id);
      else if (actions[i] === ACTION_TAKE_PROFIT || actions[i] === ACTION_STOP_LOSS) triggered.push(id);
    });
  }
  const closable = await closableAtMaxWin(maxWin, at, dropBps, markets);
  const call = (id: bigint, functionName: 'liquidate' | 'closeAtMaxWin' | 'settleRugged' | 'closeByTrigger', quiet?: string[]): Call => ({
    address: exchange,
    abi: exchangeAbi,
    functionName,
    args: [id],
    label: `position ${id} ${functionName}`,
    quiet,
  });
  const [fills, expired] = await orderActions(at);
  // An order can wait on a limit that clears later (a full coin or pool, the price bands, the breaker): it stays.
  const waits = ['NotTriggered', 'PriceMoved', 'PriceBand', 'CoinFull', 'PoolFull', 'GrowingTooFast', 'BreakerTripped', 'MarketLocked', 'LeverageNotAllowed', 'InsufficientBalance', 'WouldLiquidate', 'LiquidityTooLow', 'OracleDown'];
  return [
    ...liquidate.map((id) => call(id, 'liquidate')),
    ...closable.map((id) => call(id, 'closeAtMaxWin')),
    ...settle.map((id) => call(id, 'settleRugged')),
    // a short's stop is held while a rug the guard hasn't caught is under way, like its max win
    ...triggered.map((id) => call(id, 'closeByTrigger', ['NotTriggered', 'RugInProgress', 'OracleDown'])),
    ...fills.map((id): Call => ({ address: exchange, abi: exchangeAbi, functionName: 'fillOrder', args: [id], label: `order ${id} fill`, quiet: waits })),
    ...expired.map((id): Call => ({ address: exchange, abi: exchangeAbi, functionName: 'cancelOrder', args: [id], label: `order ${id} expired: refund`, quiet: ['NoOrder'] })),
  ];
}

/** Orders whose trigger the fast price has reached, and expired orders to refund, at block `at`. */
async function orderActions(at: bigint): Promise<[bigint[], bigint[]]> {
  const fills: bigint[] = [];
  const expired: bigint[] = [];
  const count = await readAt<bigint>(exchange, exchangeAbi, 'openOrderCount', [], at).catch((e) => {
    log(`orders: count read failed (${why(e)})`);
    return 0n;
  });
  const offsets: bigint[] = [];
  for (let o = 0n; o < count; o += PAGE) offsets.push(o);
  const pages = await mapLimit(offsets, READ_CONCURRENCY, (offset) =>
    readAt<readonly [readonly bigint[], readonly number[]]>(d.lens, lensAbi, 'actionableOrders', [offset, PAGE], at).catch((e) => {
      log(`orders from ${offset}: read failed (${why(e)})`);
      return [[], []] as const;
    }),
  );
  for (const [ids, kinds] of pages) {
    ids.forEach((id, i) => (kinds[i] === ORDER_FILL ? fills : kinds[i] === ORDER_EXPIRED ? expired : []).push(id));
  }
  return [fills, expired];
}

// ------------------------------------------------------------------ gas money

/** Moves liquidation rewards from the exchange to the wallet that pays for gas, and alerts when that runs low. */
async function gasMoney() {
  const [balance, rewards] = await Promise.all([
    pub.getBalance({ address: account.address }),
    readAt<bigint>(exchange, exchangeAbi, 'balanceOf', [account.address]),
  ]);
  let wallet = balance;
  if (rewards > 0n && (rewards >= REWARD_WITHDRAW_MIN_WEI || balance < GAS_ALERT_WEI)) {
    const label = `withdraw ${formatEther(rewards)} ETH of rewards`;
    if (await tx.one({ address: exchange, abi: exchangeAbi, functionName: 'withdraw', args: [rewards], label })) {
      wallet = await pub.getBalance({ address: account.address });
    }
  }
  if (wallet < GAS_ALERT_WEI) {
    alert('keeper-gas-low', `keeper ${account.address} has ${formatEther(wallet)} ETH left for gas (alert below ${formatEther(GAS_ALERT_WEI)}): top it up`);
  }
  if (GAS_EXIT_WEI > 0n && wallet < GAS_EXIT_WEI) {
    log(`ALERT keeper ${account.address} has ${formatEther(wallet)} ETH, under GAS_EXIT_WEI (${formatEther(GAS_EXIT_WEI)}): exiting`);
    process.exit(2);
  }
}

// ------------------------------------------------------------------ one pass

/** One pass; each step runs even if an earlier one failed. True if position work was left over for the next one. */
async function cycle(): Promise<boolean> {
  // 1. V4 samples, confirmed before anything else: a refresh must see the feed a sample may have revived.
  try {
    const samples = await dueSamples();
    if (samples.length) await tx.run(samples);
  } catch (e) {
    log('v4 samples failed:', why(e));
  }

  // 2-3. Rug guards, then refreshes, from one read of every market at one block. Wait for them: the position scan
  //      below must see shorts the rug guard just caught as rug settlements, not max-win closes.
  let dropBps = DEFAULT_RUG_DROP_BPS;
  let markets: (MarketState | undefined)[] = [];
  try {
    const head = await pub.getBlock();
    [dropBps, markets] = await Promise.all([rugDropBps(head.number), loadMarkets(head.number)]);
    const urgent = marketCalls(markets, head.timestamp);
    if (urgent.length) await tx.run(urgent);
  } catch (e) {
    log('markets failed:', why(e));
  }

  // 4. Positions.
  let left = 0;
  try {
    const calls = await positionCalls(dropBps, markets);
    if (calls.length) left = (await tx.run(calls, MAX_ACTIONS)).left;
    if (left) log(`${left} more position actions wait for the next pass`);
  } catch (e) {
    log('positions failed:', why(e));
  }

  // 5. Gas money.
  try {
    await gasMoney();
  } catch (e) {
    log('gas check failed:', why(e));
  }
  return left > 0;
}

log(`keeper ${account.address} on chain ${d.chainId}, exchange ${exchange}, every ${INTERVAL_MS} ms`);
if (V4_ORACLES.length) log(`v4 oracles: ${V4_ORACLES.join(', ')}`);

async function loop(): Promise<boolean> {
  try {
    return await cycle();
  } catch (e) {
    log('cycle failed:', why(e));
    return false;
  }
}
// Fee jobs only when FEE_ROUTER is set.
const FEE_ROUTER = process.env.FEE_ROUTER as Address | undefined;
const fees = FEE_ROUTER ? await createFeeJobs({ pub, wallet, account, tx }, FEE_ROUTER, V4_ORACLES) : undefined;
async function feeLoop(force = false) {
  if (!fees) return;
  try {
    await fees.tick(force);
  } catch (e) {
    log('fee cycle failed:', why(e));
  }
}

let more = await loop();
await feeLoop(true);
if (process.argv.includes('--once')) process.exit(0);

// Each loop starts its next pass only when the last one has ended, so a pass never overlaps itself. The two loops
// run side by side: they share one Sender, which numbers their transactions, so the fee jobs never hold up the
// rug guard.
void (async () => {
  for (;;) {
    await sleep(more ? 0 : INTERVAL_MS);
    more = await loop();
  }
})();
if (fees) {
  const intervalMs = fees.intervalMs;
  void (async () => {
    for (;;) {
      await sleep(intervalMs);
      await feeLoop();
    }
  })();
}
