// Local demo only: moves the mock Uniswap pools so the app has live prices.
//
//   node src/demo-prices.ts                 random walk, with an occasional pump
//   node src/demo-prices.ts --rugs          ...and the rare rug
//   node src/demo-prices.ts pump PLONK 40   one-off: +40% on PLONK
//   node src/demo-prices.ts rug WOB         one-off: WOB crashes 90%
//   node src/demo-prices.ts set SNRK -191000
//
// The random walk sends from its own anvil account (8), so one-off commands and e2e.ts, which send from the deployer,
// never race it for nonces. Steps run one after another, never overlapping. Every move reads the current tick from
// the pending block just before it is sent, so a move from another terminal is built on, not undone.

import type { Abi, Address, Hex } from 'viem';
import mockPoolAbiJson from '../../abi/MockV3Pool.json' with { type: 'json' };
import { ANVIL_KEYS, clients, loadDeployment, log, why } from './config.ts';

const mockPoolAbi = mockPoolAbiJson as Abi;
const d = loadDeployment();
if (d.chainId !== 31337) throw new Error('demo-prices only runs against the local anvil chain');

const STEP_MS = Number(process.env.STEP_MS ?? 4000);
const SIGMA_TICKS = Number(process.env.SIGMA_TICKS ?? 60); // ~0.6% per step
const PUMP_CHANCE = 0.004;
const RUG_CHANCE = 0.0008;
const TICKS_PER_PCT = Math.log(1.01) / Math.log(1.0001); // ~99.5 ticks per +1%

type Clients = ReturnType<typeof clients>;

async function tickOf({ pub }: Clients, pool: Address): Promise<number> {
  const slot0 = (await pub.readContract({ address: pool, abi: mockPoolAbi, functionName: 'slot0', blockTag: 'pending' })) as readonly unknown[];
  return Number(slot0[1]);
}

// setTick costs ~78k gas when it adds an observation but far less when it overwrites one from the same second, so an
// estimate taken just after the last move is too low for the next block. A fixed limit always covers it.
const SET_TICK_GAS = 200_000n;

function sendTick({ wallet, account }: Clients, pool: Address, tick: number, nonce?: number): Promise<Hex> {
  return wallet.writeContract({ address: pool, abi: mockPoolAbi, functionName: 'setTick', args: [Math.round(tick)], chain: wallet.chain, account, nonce, gas: SET_TICK_GAS });
}

function gauss() {
  return Math.sqrt(-2 * Math.log(1 - Math.random())) * Math.cos(2 * Math.PI * Math.random());
}

function bySymbol(symbol: string) {
  const m = d.markets.find((x) => x.symbol.toLowerCase() === symbol.toLowerCase());
  if (!m) throw new Error(`no market ${symbol}; have ${d.markets.map((x) => x.symbol).join(', ')}`);
  return m;
}

const [cmd, symbol, amount] = process.argv.slice(2).filter((a) => !a.startsWith('--'));
if (cmd === 'pump' || cmd === 'rug' || cmd === 'set') {
  const c = clients(d, ANVIL_KEYS.deployer);
  const m = bySymbol(symbol);
  const now = await tickOf(c, m.uniPool);
  const next =
    cmd === 'set' ? Number(amount) : cmd === 'pump' ? now + Math.log(1 + Number(amount ?? 50) / 100) / Math.log(1.0001) : now + Math.log(0.1) / Math.log(1.0001);
  await c.pub.waitForTransactionReceipt({ hash: await sendTick(c, m.uniPool, next) });
  log(`${m.symbol}: tick ${now} -> ${Math.round(next)}`);
  process.exit(0);
}

const walker = clients(d, ANVIL_KEYS.prices);
const rugs = process.argv.includes('--rugs');

/** One move per pool: sent back to back with consecutive nonces, then confirmed together. */
async function step() {
  const { pub, account } = walker;
  let nonce: number | undefined;
  const sent: [string, Hex][] = [];
  for (const m of d.markets) {
    try {
      let t = (await tickOf(walker, m.uniPool)) + gauss() * SIGMA_TICKS;
      const r = Math.random();
      if (r < PUMP_CHANCE) {
        t += (30 + Math.random() * 70) * TICKS_PER_PCT;
        log(`${m.symbol} pumps`);
      } else if (rugs && r > 1 - RUG_CHANCE) {
        t += Math.log(0.1) / Math.log(1.0001);
        log(`${m.symbol} rugs`);
      }
      nonce ??= await pub.getTransactionCount({ address: account.address, blockTag: 'pending' });
      sent.push([m.symbol, await sendTick(walker, m.uniPool, t, nonce)]);
      nonce++;
    } catch (e) {
      nonce = undefined; // re-read it before the next send
      log(`${m.symbol}: ${why(e)}`);
    }
  }
  await Promise.all(
    sent.map(([sym, hash]) =>
      pub.waitForTransactionReceipt({ hash, timeout: 30_000 }).then(
        (r) => r.status === 'success' || log(`${sym}: move reverted`),
        (e) => log(`${sym}: ${why(e)}`),
      ),
    ),
  );
}

log(`moving ${d.markets.length} mock pools every ${STEP_MS} ms from ${walker.account.address}${rugs ? ', rugs on' : ''}`);
for (;;) {
  const started = Date.now();
  try {
    await step();
  } catch (e) {
    log(`step failed: ${why(e)}`);
  }
  await new Promise((resolve) => setTimeout(resolve, Math.max(0, STEP_MS - (Date.now() - started))));
}
