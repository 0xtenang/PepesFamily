import fs from "fs";
import { log } from "./logger.js";
import { repoPath } from "./repo-root.js";
import { dataPath } from "./pepes/context.js";

// On the DATA_DIR volume when hosted, so wallets added later survive redeploys.
const WALLETS_PATH = dataPath("smart-wallets.json");

// PepesAgent: a fresh install (or a new Railway volume) watches the committed starter list (pepes/scan-lpers.js)
// until wallets are added; adding one copies the starter list into smart-wallets.json first.
const STARTER_PATH = repoPath("pepes", "smart-wallets.starter.json");

function loadWallets() {
  if (!fs.existsSync(WALLETS_PATH)) {
    try { return { wallets: JSON.parse(fs.readFileSync(STARTER_PATH, "utf8")).wallets ?? [] }; } catch { return { wallets: [] }; }
  }
  try {
    return JSON.parse(fs.readFileSync(WALLETS_PATH, "utf8"));
  } catch {
    return { wallets: [] };
  }
}

function saveWallets(data) {
  fs.writeFileSync(WALLETS_PATH, JSON.stringify(data, null, 2));
}

const SOLANA_PUBKEY_RE = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;

export function addSmartWallet({ name, address, category = "alpha", type = "lp" }) {
  if (!SOLANA_PUBKEY_RE.test(address)) {
    return { success: false, error: "Invalid Solana address format" };
  }
  const data = loadWallets();
  const existing = data.wallets.find((w) => w.address === address);
  if (existing) {
    return { success: false, error: `Already tracked as "${existing.name}"` };
  }
  data.wallets.push({ name, address, category, type, addedAt: new Date().toISOString() });
  saveWallets(data);
  log("smart_wallets", `Added wallet: ${name} (${category}, type=${type})`);
  return { success: true, wallet: { name, address, category, type } };
}

export function removeSmartWallet({ address }) {
  const data = loadWallets();
  const wallet = data.wallets.find((w) => w.address === address);
  if (!wallet) return { success: false, error: "Wallet not found" };
  data.wallets = data.wallets.filter((w) => w.address !== address);
  saveWallets(data);
  log("smart_wallets", `Removed wallet: ${wallet.name}`);
  return { success: true, removed: wallet.name };
}

export function listSmartWallets() {
  const { wallets } = loadWallets();
  return { total: wallets.length, wallets };
}
