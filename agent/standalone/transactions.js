// Serialize wallet mutations while allowing monitoring and screening to continue.
// Exit work jumps ahead of queued entries; an in-flight submission is never interrupted.
import { AsyncResource } from "node:async_hooks";

let active = false;
const queue = [];
export function withWalletLock(fn, priority = 0) {
  return new Promise((resolve, reject) => {
    // PepesAgent: run fn as the user who queued it (pepes/context.js), not as whoever drains the queue.
    queue.push({ fn: AsyncResource.bind(fn), priority, resolve, reject });
    queue.sort((a, b) => b.priority - a.priority);
    drain();
  });
}
async function drain() {
  if (active || !queue.length) return;
  active = true;
  const item = queue.shift();
  try { item.resolve(await item.fn()); } catch (e) { item.reject(e); }
  finally { active = false; void drain(); }
}
