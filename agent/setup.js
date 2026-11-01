/** Standalone setup: write public settings; secrets stay in the user's environment. */
import readline from 'node:readline/promises';
import fs from 'node:fs';
import { PublicKey } from '@solana/web3.js';
import { repoPath } from './repo-root.js';

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
try {
  const file = repoPath('user-config.json');
  const defaults = JSON.parse(fs.readFileSync(repoPath('user-config.example.json'), 'utf8'));
  const prior = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
  delete defaults._readme;
  const next = { ...defaults, ...prior };
  console.log('Meridian standalone setup. Existing settings are retained when you press Enter.');
  const wallet = (await rl.question('Public wallet address (blank to use WALLET_PRIVATE_KEY): ')).trim();
  if (wallet) next.walletAddress = new PublicKey(wallet).toBase58();
  const rpc = (await rl.question('RPC URL (blank to retain settings / use RPC_URL from the environment): ')).trim();
  if (rpc) {
    const parsed = new URL(rpc);
    if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error('RPC URL must use HTTP or HTTPS');
    next.rpcUrl = rpc;
  }
  next.shadowMode = true;
  fs.writeFileSync(file, JSON.stringify(next, null, 2) + '\n', { mode: 0o600 });
  console.log('Saved user-config.json in shadow mode.');
  console.log('Add LP wallets with: node cli.js wallets add --wallet ADDRESS --name NAME');
  console.log('Set WALLET_PRIVATE_KEY in your environment for live signing; no LLM or Helius Wallet API key is needed.');
  console.log('Review user-config.json, then run npm start.');
} finally { rl.close(); }
