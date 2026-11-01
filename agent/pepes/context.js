// PepesAgent: who the current work is for.
//
// One process serves every user. Signals and screening are shared; each entry, exit and claim runs inside
// runAs(user, fn), and the Meridian modules read the user from here: their signer (tools/dlmm.js,
// tools/wallet.js), their state files (state.js, performance.js, decision-log.js) and their risk settings
// (config.js overlays). Outside runAs everything behaves as single-wallet Meridian.

import { AsyncLocalStorage } from "node:async_hooks";
import fs from "node:fs";
import path from "node:path";
import { repoPath } from "../repo-root.js";

const als = new AsyncLocalStorage();

/** Runs `fn` as `user` ({ id, address, signer, settings }). */
export const runAs = (user, fn) => als.run(user, fn);

export const currentUser = () => als.getStore() || null;

/** Where state lives: DATA_DIR (a Railway volume) or the repo. */
export function dataPath(...segments) {
  return process.env.DATA_DIR ? path.join(process.env.DATA_DIR, ...segments) : repoPath(...segments);
}

/** A per-user state file (data/users/<id>/<file>), or the shared one outside runAs. */
export function userPath(file) {
  const u = currentUser();
  if (!u) return dataPath(file);
  const dir = dataPath("users", u.id);
  fs.mkdirSync(dir, { recursive: true });
  return path.join(dir, file);
}

/** A config section whose keys the current user's settings[section] can override. */
export function overlay(section, target) {
  return new Proxy(target, {
    get(t, key) {
      const own = currentUser()?.settings?.[section];
      return own && own[key] !== undefined ? own[key] : t[key];
    },
  });
}

/** Nothing is sent: global shadow mode (DRY_RUN) or, in runAs, a user who isn't live yet. */
export function isDryRun() {
  const u = currentUser();
  return process.env.DRY_RUN === "true" || (!!u && !u.live);
}
