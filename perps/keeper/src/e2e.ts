// Local end-to-end check: a trader opens four positions, prices move, one keeper pass handles them.
//   node src/e2e.ts      (needs the local anvil stack)

import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseEther, type Abi, type Address } from 'viem';
import exchangeAbiJson from '../../abi/LevExchange.json' with { type: 'json' };
import poolAbiJson from '../../abi/LevPool.json' with { type: 'json' };
import lensAbiJson from '../../abi/LevLens.json' with { type: 'json' };
import mockPoolAbiJson from '../../abi/MockV3Pool.json' with { type: 'json' };
import { ANVIL_KEYS, clients, loadDeployment, log } from './config.ts';

const exchangeAbi = exchangeAbiJson as Abi;
const poolAbi = poolAbiJson as Abi;
const mockPoolAbi = mockPoolAbiJson as Abi;
const TRADER_KEY = '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6'; // anvil account 3

const d = loadDeployment();
if (d.chainId !== 31337) throw new Error('local only');
const trader = clients(d, TRADER_KEY);
const deployer = clients(d, ANVIL_KEYS.deployer);
const { pub } = trader;
const ex = d.exchange;
const bySymbol = (s: string) => d.markets.find((m) => m.symbol === s)!;

async function write(c: typeof trader, address: Address, abi: Abi, functionName: string, args: readonly unknown[], value = 0n, gas?: bigint) {
  const { request } = await pub.simulateContract({ address, abi, functionName, args, account: c.account, value });
  const hash = await c.wallet.writeContract({ ...request, gas });
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== 'success') throw new Error(`${functionName} reverted`);
  return r;
}
const read = <T>(functionName: string, args: readonly unknown[] = [], address: Address = ex, abi: Abi = exchangeAbi) =>
  pub.readContract({ address, abi, functionName, args }) as Promise<T>;

async function tickOf(pool: Address) {
  return Number(((await read<readonly unknown[]>('slot0', [], pool, mockPoolAbi)) as readonly unknown[])[1]);
}
async function movePct(symbol: string, pct: number) {
  const m = bySymbol(symbol);
  const t = (await tickOf(m.uniPool)) + Math.round(Math.log(1 + pct / 100) / Math.log(1.0001));
  // Fixed gas: right after demo-prices moved this pool, an estimate prices the cheap same-second overwrite.
  await write(deployer, m.uniPool, mockPoolAbi, 'setTick', [t], 0n, 200_000n);
}
async function openPos(symbol: string, isLong: boolean, lev: number, stake: string) {
  const id = BigInt(bySymbol(symbol).id);
  const r = await write(trader, ex, exchangeAbi, 'open', [id, isLong, lev, parseEther(stake), isLong ? 8_388_607 : -8_388_608]);
  const ids = await read<bigint[]>('positionIdsOf', [trader.account.address]);
  log(`opened ${isLong ? 'long' : 'short'} ${lev}x ${symbol} (tx ${r.transactionHash.slice(0, 10)})`);
  return ids[ids.length - 1];
}
const isOpen = async (id: bigint) =>
  (await read<{ position: { owner: Address } }>('getPosition', [id], d.lens, lensAbiJson as Abi)).position.owner !==
  '0x0000000000000000000000000000000000000000';

const cash0 = await read<bigint>('cash', [], d.pool, poolAbi);
await write(trader, ex, exchangeAbi, 'deposit', [], parseEther('1'));
const liq = await openPos('PLONK', true, 10, '0.05');
const maxWin = await openPos('WOB', false, 5, '0.05');
const keep = await openPos('SNRK', true, 2, '0.02');
const rugged = await openPos('GRMB', false, 2, '0.02');

await movePct('PLONK', -15); // 10x long wiped out
await movePct('WOB', -20); // 5x short reaches its +100% max win
await movePct('SNRK', 5); // stays open
await movePct('GRMB', -90); // rug
// Let the 60-second fast averages catch up.
await pub.request({ method: 'evm_increaseTime' as never, params: [120] as never });
await pub.request({ method: 'evm_mine' as never, params: [] as never });

const keeperScript = fileURLToPath(new URL('./keeper.ts', import.meta.url));
console.log(execFileSync('node', [keeperScript, '--once'], { encoding: 'utf8' }).trim());

const results = {
  liquidated: !(await isOpen(liq)),
  closedAtMaxWin: !(await isOpen(maxWin)),
  ruggedShortSettled: !(await isOpen(rugged)),
  untouchedStillOpen: await isOpen(keep),
};
await write(trader, ex, exchangeAbi, 'close', [keep, -8_388_608]); // a long: no price limit
const cash1 = await read<bigint>('cash', [], d.pool, poolAbi);
const poolBal = await pub.getBalance({ address: d.pool });
log('results', results);
log(`pool cash ${Number(cash0) / 1e18} -> ${Number(cash1) / 1e18} ETH, balance matches cash: ${poolBal === cash1}`);
const ok = Object.values(results).every(Boolean) && poolBal === cash1;
log(ok ? 'E2E PASSED' : 'E2E FAILED');
process.exit(ok ? 0 : 1);
