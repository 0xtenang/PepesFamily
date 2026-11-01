// PepesAgent users: who the agent trades for.
//
// data/users.json (on the DATA_DIR volume) holds one record per user who started the agent on the site:
//   { id, address, walletId, owner, active, live, settings, startedAt }
//   id        Privy user id          address   the agent wallet (Solana)   walletId  its Privy wallet id
//   owner     their Phantom address (withdrawals and the profit fee never go anywhere else but owner / FEE_ADDRESS)
//   active    the agent runs for them  live      false holds just this user in shadow (AGENT_LIVE gates everyone)
//   settings  { risk, management, strategy } overrides of config.js (the presets on the site)
// The site's API (pepes/server.js) adds and updates records; the runtime reads them each cycle.

import fs from "node:fs";
import { dataPath } from "./context.js";
import { PrivySigner } from "./signer.js";
import { MonitorStore } from "../standalone/store.js";

const FILE = () => dataPath("users.json");
const stores = new Map();

export function loadUsers() {
  try { return JSON.parse(fs.readFileSync(FILE(), "utf8")); } catch { return []; }
}

export function saveUsers(list) {
  fs.mkdirSync(dataPath(), { recursive: true });
  fs.writeFileSync(`${FILE()}.tmp`, JSON.stringify(list, null, 2), { mode: 0o600 });
  fs.renameSync(`${FILE()}.tmp`, FILE());
}

/** A user's trades are sent only when the agent is live (AGENT_LIVE=true) and the user hasn't been held back. */
export const isLive = (u) => process.env.AGENT_LIVE === "true" && u.live !== false;

/** Multi-user mode: on when PRIVY_APP_ID is set (the hosted agent); off for a single local wallet. */
export const multiUser = () => !!process.env.PRIVY_APP_ID;

/** Users the agent runs for now, each with its signer and its own attempt store. */
export function activeUsers() {
  return loadUsers().filter(u => u.active && u.address && u.walletId).map(u => ({
    ...u,
    live: isLive(u),
    signer: new PrivySigner({ walletId: u.walletId, address: u.address }),
    store: storeFor(u.id),
  }));
}

/** Each user's entry attempts (duplicate guard and crash recovery) live apart from the shared signal store. */
function storeFor(id) {
  if (!stores.has(id)) {
    fs.mkdirSync(dataPath("users", id), { recursive: true });
    stores.set(id, new MonitorStore(dataPath("users", id, "attempts.json")));
  }
  return stores.get(id);
}
