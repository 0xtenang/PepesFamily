// Vercel serverless function: everything Discover needs to draw, read once and shared through Vercel's CDN, so a visit
// starts from one cached request instead of ~120 chain and explorer reads:
//   GET /api/feed -> { at, live, remotes, tokens, market, prices }
//     live     "<chain>:<pad>" -> [launchpad deployed, its ETH router deployed]
//     remotes  chain keys whose PepesFamilyRemote (pay from any chain) is deployed
//     tokens   "<chain>:<pad>" -> every token info the launchpad (or its lens) lists, as getTokens returns them
//     market   "<chain>:<pad>" -> { "<token>": [volume 24h, trades, first trade's quote amount, its token amount] }
//              (only where the explorer answers a server: Robinhood's and Base's Blockscout refuse servers, and free
//              RPCs serve no 24 h of logs, so the page reads those launchpads' history itself, in the background)
//     prices   the same USD prices the page computes (ETH, IMD/ETH, PEPE/ETH, CASHCAT/ETH, HYPE, BNB)
//     unclaimed "<chain>:<token>" -> holder rewards paid out but not claimed yet (the token's accountedBalance), for
//              the Holder rewards page (earned since launch = claimed + this + still pending)
// Big numbers travel as {"$n": "<decimal>"}. The launchpad list is the page's own CONFIG.pads, read from the deployed
// index.html, so it never needs a second copy here. Cached 30 s at the edge, served stale while it refreshes.

const { ethers } = require("../js/ethers-6.13.4.umd.min.js");

// Per chain: where to read, and where trade history lives (the same endpoints as the page's CHAINS).
const CHAINS = {
  robinhood: { id: 4663, rpc: ["https://robinhood-rpc.publicnode.com", "https://robinhood.drpc.org"], blockscout: "https://robinhoodchain.blockscout.com/api/v2", remote: "0xC6A3C9C80242745B795aE94afe8667a0eF3ec827" },
  ethereum: { id: 1, rpc: ["https://ethereum-rpc.publicnode.com", "https://eth.drpc.org"], blockscout: "https://eth.blockscout.com/api/v2", remote: "0x8ec13A6E998000175fCf20A77B90562fe8127252" },
  base: { id: 8453, rpc: ["https://base-rpc.publicnode.com", "https://mainnet.base.org"], blockscout: "https://base.blockscout.com/api/v2", remote: "0xAf760F137D9785A14a2f7b0f0cf4b6fD943589a4" },
  hyperevm: { id: 999, rpc: ["https://rpc.hyperliquid.xyz/evm", "https://hyperliquid.drpc.org"], blockscout: "", remote: "0x3e7dcCdE57953495396A0714b85B419D59F57A29" },
  bsc: { id: 56, rpc: ["https://bsc-rpc.publicnode.com", "https://bsc-dataseed.bnbchain.org"], blockscout: "", remote: "0xB8Cf1810eB5f71AB2A50a1FE3C0DF0559FB7bb2B" },
  elysium: { id: 99901, rpc: ["https://rpc.elysium.kinetiq.xyz", "https://rpc.volta.family"], blockscout: "" },
};
// Pepes Earn IMD's hook joins the launchpads (the page adds it from CONFIG.earn).
const EARN_HOOK = "0x41Edd4c96a25e9aC6e4CF80C40EB6B85c77aA8CC";
const INFO_T = "tuple(address token, string name, string symbol, string metadata, address quote, address creator, uint64 createdAt, uint64 createdBlock, bool quoteIsCurrency0, bytes32 poolId, uint160 sqrtPriceX96, uint256 marketCap, uint256 pendingHolderFees, uint256 totalDividendsDistributed)";
const PAD = new ethers.Interface([
  "function tokenCount() view returns (uint256)",
  `function getTokens(uint256 offset, uint256 limit) view returns (${INFO_T}[])`,
  "event Trade(address indexed token, address indexed trader, bool isBuy, uint256 quoteAmount, uint256 tokenAmount, uint256 fee, uint160 sqrtPriceX96)",
]);
const TOKEN = new ethers.Interface(["function accountedBalance() view returns (uint256)"]);
const SV = new ethers.Interface(["function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)"]);
const STATE_VIEW = { robinhood: "0xf3334192d15450cdd385c8b70e03f9a6bd9e673b", ethereum: "0x7ffe42c4a5deea5b0fec41c94c136cf115597227" };
const POOLS = {
  ethUsd: ["robinhood", "0xbac3aa3b91584a53a579b3c999a56756e954e59247e497bad1d25a4334bde551"],
  imdEth: ["robinhood", "0xd2fc01ee6f8400b6b4ea3b341a188568f2bd6c72b07b96741a82396fa6eb8f02"],
  pepeEth: ["ethereum", "0xe42df52d7938631f6c6cb56aac2fafc1e00ea77b7517a02ee244bd7d86c061cd"],
  cashcatEth: ["robinhood", "0xf7dc0af99fce7169eb76854c0b39beb9915526894d42229946e5cb469cab50b1"],
};

const timeout = (ms) => AbortSignal.timeout(ms);
/// One JSON-RPC call on `chain`, falling back to its second endpoint.
async function rpc(chain, method, params) {
  let last;
  for (const url of CHAINS[chain].rpc) {
    try {
      const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), signal: timeout(6000) });
      const j = await r.json();
      if (j.result !== undefined) return j.result;
      last = new Error(j.error?.message || "rpc error");
      if (j.error && /revert/i.test(j.error.message || "")) throw last; // a real answer: don't ask again
    } catch (e) { last = e; }
  }
  throw last;
}
const call = (chain, to, iface, fn, args = []) =>
  rpc(chain, "eth_call", [{ to, data: iface.encodeFunctionData(fn, args) }, "latest"]).then((d) => iface.decodeFunctionResult(fn, d)[0]);
const hasCode = (chain, a) => rpc(chain, "eth_getCode", [a, "latest"]).then((c) => c.length > 2);

/// The page's CONFIG.pads, read from the deployed index.html (trusted: it is this site's own page).
async function padList(origin) {
  const html = await (await fetch(origin + "/", { signal: timeout(5000) })).text();
  const start = html.indexOf("\n  pads: [");
  const end = html.indexOf("\n  ],", start);
  if (start < 0 || end < 0) throw new Error("CONFIG.pads not found");
  const pads = new Function(`return ${html.slice(start + "\n  pads: ".length, end + 4)};`)();
  return [...pads, { version: "earn", pad: EARN_HOOK }].map((p) => ({ ...p, chain: p.chain || "robinhood" }));
}

async function tokensOf(p) {
  const via = p.lens || p.pad;
  const n = Number(await call(p.chain, p.pad, PAD, "tokenCount"));
  const out = [];
  for (let off = 0; off < n; off += 100) out.push(...(await call(p.chain, via, PAD, "getTokens", [off, 100])).map((t) => t.toObject()));
  return out;
}

/// The last 24 h of trades on one launchpad, from Blockscout (newest first, up to 10 pages), per token.
async function marketOf(p) {
  const api = CHAINS[p.chain].blockscout;
  const topic = PAD.getEvent("Trade").topicHash, since = Date.now() / 1000 - 86400, per = {};
  let next = null;
  for (let page = 0; page < 10; page++) {
    const r = await fetch(`${api}/addresses/${p.pad}/logs?topic=${topic}` + (next ? "&" + new URLSearchParams(next) : ""), { signal: timeout(7000) });
    if (!r.ok) throw new Error("blockscout " + r.status);
    const j = await r.json();
    let older = false;
    for (const i of j.items) {
      if (i.topics[0] !== topic) continue;
      if (Date.parse(i.block_timestamp) / 1000 < since) { older = true; continue; }
      const a = PAD.parseLog({ topics: i.topics.filter(Boolean), data: i.data }).args;
      const k = a.token.toLowerCase();
      const m = (per[k] ||= [0n, 0, 0n, 0n]);
      m[0] += a.quoteAmount; m[1]++; m[2] = a.quoteAmount; m[3] = a.tokenAmount; // newest first: the last seen is the earliest
    }
    if (older || !j.next_page_params) break;
    next = j.next_page_params;
  }
  return per;
}

async function prices() {
  const slot = async ([chain, id]) => {
    const sq = await call(chain, STATE_VIEW[chain], SV, "getSlot0", [id]); // sqrtPriceX96, the first value
    const r = Number(sq) / 2 ** 96;
    return r * r;
  };
  const coin = async (chainId) => {
    const r = await fetch(`https://api.relay.link/currencies/token/price?address=${ethers.ZeroAddress}&chainId=${chainId}`, { signal: timeout(6000) });
    return Number((await r.json())?.price) || 0;
  };
  const [ethUsd, imdEth, pepeEth, cashcatEth, hypeUsd, bnbUsd] = await Promise.all([
    slot(POOLS.ethUsd).then((v) => v * 1e12).catch(() => 0), // USDG (6 decimals) per ETH
    slot(POOLS.imdEth).then((v) => (v ? 1 / v : 0)).catch(() => 0),
    slot(POOLS.pepeEth).then((v) => (v ? 1 / v : 0)).catch(() => 0),
    slot(POOLS.cashcatEth).then((v) => (v ? 1 / v : 0)).catch(() => 0),
    coin(999).catch(() => 0),
    coin(56).catch(() => 0),
  ]);
  return { ethUsd, imdEth, pepeEth, cashcatEth, hypeUsd, bnbUsd };
}

async function build(origin) {
  const pads = await padList(origin);
  const key = (p) => `${p.chain}:${p.pad.toLowerCase()}`;
  const live = {}, tokens = {}, market = {}, remotes = [], unclaimed = {};
  await Promise.all([
    ...pads.map(async (p) => {
      try {
        const [a, b] = await Promise.all([hasCode(p.chain, p.pad), p.ethRouter ? hasCode(p.chain, p.ethRouter) : false]);
        live[key(p)] = [a, b];
        if (!a) return;
        await Promise.all([
          tokensOf(p).then(async (t) => {
            tokens[key(p)] = t;
            await Promise.all(t.map((x) => call(p.chain, x.token, TOKEN, "accountedBalance")
              .then((v) => (unclaimed[`${p.chain}:${x.token.toLowerCase()}`] = v)).catch(() => {})));
          }).catch(() => {}),
          CHAINS[p.chain].blockscout ? marketOf(p).then((m) => (market[key(p)] = m)).catch(() => {}) : null,
        ]);
      } catch {} // unknown: the page checks this launchpad itself
    }),
    ...Object.entries(CHAINS).filter(([, c]) => c.remote).map(([k, c]) => hasCode(k, c.remote).then((y) => y && remotes.push(k)).catch(() => {})),
  ]);
  return { at: Date.now(), live, remotes, tokens, market, unclaimed, prices: await prices() };
}

const ORIGINS = ["https://pepesdotfamily.fun", "https://www.pepesdotfamily.fun", "https://pepesfamily.vercel.app"];
module.exports = async (req, res) => {
  try {
    const host = String(req.headers["x-forwarded-host"] || req.headers.host || "");
    const origin = ORIGINS.find((o) => o.endsWith("//" + host)) || ORIGINS[1];
    const feed = await build(origin);
    res.setHeader("Cache-Control", "public, s-maxage=30, stale-while-revalidate=300");
    res.setHeader("content-type", "application/json");
    res.status(200).send(JSON.stringify(feed, (k, v) => (typeof v === "bigint" ? { $n: v.toString() } : v)));
  } catch (e) {
    res.setHeader("Cache-Control", "no-store");
    res.status(502).json({ error: "feed unavailable: " + (e?.message || e) });
  }
};
module.exports.build = build;
