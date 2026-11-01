import "./envcrypt.js";
import { pathToFileURL } from "node:url";
import path from "node:path";

// The standalone wallet-triggered bot is the app — there is no mode toggle.
// Entries come only from smart-wallet convergence; the LLM/server-driven
// flow lives on the `legacy` branch.

const entry = process.env.pm_exec_path || process.argv[1];
if (entry && pathToFileURL(path.resolve(entry)).href === import.meta.url) {
  // PepesAgent: the Agent page's API first when hosted (Render/Railway set PORT), so health checks pass while the
  // bot is still connecting to the wallets it follows
  if (process.env.PORT) (await import("./pepes/server.js")).startServer();
  const { startStandalone } = await import("./standalone/runtime.js");
  await startStandalone();
}
