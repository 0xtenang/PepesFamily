// Builds island.jsx into web/js/privy/ (an entry file plus chunks Privy loads only when needed) and points
// web/index.html (CONFIG.privyScript) at the new entry. Names change with the content, so browsers cache them for good.
import { build } from "esbuild";
import { readFileSync, writeFileSync, rmSync } from "node:fs";
import { gzipSync } from "node:zlib";

const dir = "../web/js/privy";
rmSync(dir, { recursive: true, force: true });
const r = await build({
  entryPoints: ["island.jsx"], bundle: true, minify: true, format: "esm", splitting: true, target: "es2020",
  outdir: dir, entryNames: "privy-[hash]", chunkNames: "c-[hash]", metafile: true, legalComments: "none",
  jsx: "automatic", define: { "process.env.NODE_ENV": '"production"', global: "globalThis" }, logLevel: "warning",
});
const o = r.metafile.outputs;
const entry = Object.keys(o).find((k) => o[k].entryPoint === "island.jsx");
const start = new Set();
const walk = (f) => { if (start.has(f)) return; start.add(f); for (const i of o[f].imports) if (i.kind === "import-statement") walk(i.path); };
walk(entry);
const gz = [...start].reduce((t, f) => t + gzipSync(readFileSync(f)).length, 0);
const src = "/js/privy/" + entry.split("/").pop();
const html = readFileSync("../web/index.html", "utf8");
if (!/privyScript: "[^"]*"/.test(html)) throw new Error("CONFIG.privyScript not found in web/index.html");
writeFileSync("../web/index.html", html.replace(/privyScript: "[^"]*"/, `privyScript: "${src}"`));
console.log(`${src}: ${start.size} files at sign-in, ${(gz / 1024).toFixed(0)} KB gzipped; ${Object.keys(o).length} files in all`);
