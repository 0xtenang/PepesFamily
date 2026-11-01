#!/usr/bin/env node
import './envcrypt.js';
import { parseArgs } from 'node:util';

const HELP = `Meridian — standalone wallet-triggered DLMM bot

Commands:
  start                           Start wallet monitoring and deterministic exits
  status                          Show persisted monitor state (no network)
  balance                         Read native SOL and token balances
  positions [--wallet ADDRESS]    Read open positions
  pnl --pool ADDRESS --position ADDRESS
  screen --mint ADDRESS           Screen one mint, read-only; never deploys
  pool --pool ADDRESS             Read focused pool metrics
  active-bin --pool ADDRESS       Read the current on-chain bin
  manage                          Run one deterministic management pass
  close --position ADDRESS [--reason TEXT] [--skip-swap]
  claim --position ADDRESS
  swap --from MINT --to MINT --amount NUMBER
  wallets                         List the monitored LP wallets
  wallets add --wallet ADDRESS [--name NAME]
  wallets remove --wallet ADDRESS
  blacklist                       List blocked token mints
  blacklist add --mint ADDRESS [--reason TEXT]
  blacklist remove --mint ADDRESS
  performance [--hours NUMBER]     Read local closed-position history
  config                          Show non-secret strategy and threshold settings
  help

Flags: --dry-run forces all transaction operations to simulate only.
Configuration: user-config.json (restart the daemon after editing).
New entries are made only by wallet convergence; manual deploy and broad
candidate scanning belong to the legacy branch.
`;
const { values: flags, positionals } = parseArgs({
  allowPositionals: true,
  options: Object.fromEntries([
    ...['wallet','name','pool','position','mint','reason','from','to','amount','hours'].map(k => [k, { type: 'string' }]),
    ...['help','dry-run','skip-swap'].map(k => [k, { type: 'boolean' }]),
  ]),
});
if (flags['dry-run']) process.env.DRY_RUN = 'true';
const out = value => process.stdout.write(JSON.stringify(value, null, 2) + '\n');
function requireFlag(key) { if (!flags[key]) throw new Error(`--${key} is required`); return flags[key]; }
async function main() {
  const [cmd = 'help', action] = positionals;
  if (flags.help || cmd === 'help') { process.stdout.write(HELP); return; }
  // Load config before tools so shadow mode is applied to every write.
  const { config } = await import('./config.js');
  switch (cmd) {
    case 'start': return (await import('./standalone/runtime.js')).startStandalone();
    case 'status': {
      const fs = await import('node:fs');
      const { repoPath } = await import('./repo-root.js');
      const file = repoPath('wallet-monitor-state.json');
      if (!fs.existsSync(file)) return out({ started: false, shadow: config.standalone.shadow });
      const data = JSON.parse(fs.readFileSync(file, 'utf8'));
      return out({ shadow: config.standalone.shadow, wallets: data.wallets, pending_transactions: Object.keys(data.pending).length, signals: data.signals, attempts: data.attempts });
    }
    case 'balance': return out(await (await import('./tools/wallet.js')).getWalletBalances({ force: true }));
    case 'positions': return out(await (await import('./tools/dlmm.js')).getMyPositions({ force: true, wallet_address: flags.wallet }));
    case 'pnl': return out(await (await import('./tools/dlmm.js')).getPositionPnl({ pool_address: requireFlag('pool'), position_address: requireFlag('position') }));
    case 'screen': return out(await (await import('./standalone/screening.js')).screenMint(requireFlag('mint')));
    case 'pool': return out(await (await import('./standalone/screening.js')).poolDetail(requireFlag('pool')));
    case 'active-bin': return out(await (await import('./tools/dlmm.js')).getActiveBin({ pool_address: requireFlag('pool') }));
    case 'manage': return out(await (await import('./standalone/runtime.js')).manageOnce());
    case 'close': case 'claim': case 'swap': {
      const { executeTool } = await import('./tools/executor.js');
      if (cmd === 'close') return out(await executeTool('close_position', { position_address: requireFlag('position'), reason: flags.reason || 'manual close', skip_swap: !!flags['skip-swap'] }));
      if (cmd === 'claim') return out(await executeTool('claim_fees', { position_address: requireFlag('position') }));
      const amount = Number(requireFlag('amount'));
      if (!Number.isFinite(amount) || amount <= 0) throw new Error('--amount must be positive');
      return out(await executeTool('swap_token', { input_mint: requireFlag('from'), output_mint: requireFlag('to'), amount }));
    }
    case 'wallets': {
      const wallets = await import('./smart-wallets.js');
      if (!action) return out(wallets.listSmartWallets());
      if (action === 'add') return out(wallets.addSmartWallet({ address: requireFlag('wallet'), name: flags.name || flags.wallet.slice(0, 8), type: 'lp' }));
      if (action === 'remove') return out(wallets.removeSmartWallet({ address: requireFlag('wallet') }));
      throw new Error('Use wallets, wallets add, or wallets remove');
    }
    case 'blacklist': {
      const blocked = await import('./token-blacklist.js');
      if (!action) return out(blocked.listBlacklist());
      if (action === 'add') return out(blocked.addToBlacklist({ mint: requireFlag('mint'), reason: flags.reason || 'manual block' }));
      if (action === 'remove') return out(blocked.removeFromBlacklist({ mint: requireFlag('mint') }));
      throw new Error('Use blacklist, blacklist add, or blacklist remove');
    }
    case 'performance': {
      const { getPerformanceHistory, getPerformanceSummary } = await import('./performance.js');
      const hours = Number(flags.hours || 24);
      if (!Number.isFinite(hours) || hours <= 0) throw new Error('--hours must be positive');
      return out({ summary: getPerformanceSummary(), recent: getPerformanceHistory({ hours }) });
    }
    case 'config': return out({ shadowMode: config.standalone.shadow, risk: config.risk, screening: config.screening, management: config.management, strategy: config.strategy, schedule: config.schedule });
    default: throw new Error(`Unknown command "${cmd}". Run meridian help. Legacy commands are archived on the legacy branch.`);
  }
}
main().catch(error => { process.stderr.write(JSON.stringify({ error: error.message }) + '\n'); process.exitCode = 1; });
