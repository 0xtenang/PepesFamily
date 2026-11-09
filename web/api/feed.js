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
//     ext      tokens launched elsewhere that trade in Elysium's Uniswap v4 pools against HYPE (GeckoTerminal's busiest),
//              each with its pool key, so the page lists them and trades them through PepesFamilySwapRouter
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
  elysium: { id: 99901, rpc: ["https://rpc-live.boxa.club", "https://rpc.volta.family"], blockscout: "" },
};
// Pepes Earn IMD's hook joins the launchpads (the page adds it from CONFIG.earn).
const EARN_HOOK = "0x41Edd4c96a25e9aC6e4CF80C40EB6B85c77aA8CC";
const INFO_T = "tuple(address token, string name, string symbol, string metadata, address quote, address creator, uint64 createdAt, uint64 createdBlock, bool quoteIsCurrency0, bytes32 poolId, uint160 sqrtPriceX96, uint256 marketCap, uint256 pendingHolderFees, uint256 totalDividendsDistributed)";
const PAD = new ethers.Interface([
  "function tokenCount() view returns (uint256)",
  `function getTokens(uint256 offset, uint256 limit) view returns (${INFO_T}[])`,
  "event Trade(address indexed token, address indexed trader, bool isBuy, uint256 quoteAmount, uint256 tokenAmount, uint256 fee, uint160 sqrtPriceX96)",
]);
const SV = new ethers.Interface(["function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)"]);
const STATE_VIEW = { robinhood: "0xf3334192d15450cdd385c8b70e03f9a6bd9e673b", ethereum: "0x7ffe42c4a5deea5b0fec41c94c136cf115597227" };
const POOLS = {
  ethUsd: ["robinhood", "0xbac3aa3b91584a53a579b3c999a56756e954e59247e497bad1d25a4334bde551"],
  imdEth: ["robinhood", "0xd2fc01ee6f8400b6b4ea3b341a188568f2bd6c72b07b96741a82396fa6eb8f02"],
  pepeEth: ["ethereum", "0xe42df52d7938631f6c6cb56aac2fafc1e00ea77b7517a02ee244bd7d86c061cd"],
  cashcatEth: ["robinhood", "0xf7dc0af99fce7169eb76854c0b39beb9915526894d42229946e5cb469cab50b1"],
};

// Elysium's Uniswap v4 PoolManager, its WHYPE, and the event that records each pool's key.
const ELYSIUM_PM = "0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1";
const ELYSIUM_WHYPE = "0xbA876237B0F021A6c6D852d6c26E107997cC5E81".toLowerCase();
const PM = new ethers.Interface(["event Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)"]);
const POOL_KEYS = new Map(); // pool id -> key (a pool's key never changes: kept while the function stays warm)
const IMAGES = new Map(); // token -> image URL ("" when none was found), kept while warm
const META = new ethers.Interface(["function logo() view returns (string)", "function tokenURI() view returns (string)"]);
const gateway = (u) => (u.startsWith("ipfs://") ? "https://ipfs.filebase.io/ipfs/" + u.slice(7).replace(/^ipfs\//, "") : u);

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

/// A pool's key, from the PoolManager's Initialize event for its id.
async function poolKey(id) {
  if (POOL_KEYS.has(id)) return POOL_KEYS.get(id);
  const topic = PM.getEvent("Initialize").topicHash;
  const logs = await rpc("elysium", "eth_getLogs", [{ address: ELYSIUM_PM, topics: [topic, id], fromBlock: "0x0", toBlock: "latest" }]);
  if (!logs.length) return null;
  const a = PM.parseLog(logs[0]).args;
  const key = [a.currency0, a.currency1, Number(a.fee), Number(a.tickSpacing), a.hooks];
  POOL_KEYS.set(id, key);
  return key;
}

/// Token images GeckoTerminal lacks: DexScreener's (30 tokens a request), else the token's own `logo()` or
/// `tokenURI()` (an image, or JSON with an "image"), as some Elysium launchpads store them on chain.
async function addImages(list) {
  const need = list.filter((x) => !x.image && !IMAGES.has(x.address.toLowerCase()));
  for (let i = 0; i < need.length; i += 30) {
    const part = need.slice(i, i + 30).map((x) => x.address);
    try {
      const pairs = await (await fetch(`https://api.dexscreener.com/tokens/v1/elysium/${part.join(",")}`, { signal: timeout(8000) })).json();
      // DexScreener's CDN resizes: avatars need 128 px, not its 800
      for (const p of pairs || []) if (p.info?.imageUrl) IMAGES.set(p.baseToken.address.toLowerCase(), p.info.imageUrl.replace(/width=\d+&height=\d+/, "width=128&height=128"));
    } catch {}
  }
  await Promise.all(need.filter((x) => !IMAGES.has(x.address.toLowerCase())).map(async (x) => {
    let url = "";
    for (const fn of ["logo", "tokenURI"]) {
      try {
        const v = String(await call("elysium", x.address, META, fn));
        if (!v) continue;
        const u = gateway(v.trim());
        if (fn === "logo") { url = u; break; }
        const r = await fetch(u, { signal: timeout(5000) });
        if (/^image\//.test(r.headers.get("content-type") || "")) { url = u; break; }
        const img = (await r.json()).image;
        if (img) { url = gateway(String(img)); break; }
      } catch {}
    }
    IMAGES.set(x.address.toLowerCase(), url);
  }));
  for (const x of list) if (!x.image) x.image = IMAGES.get(x.address.toLowerCase()) || "";
  return list;
}

/// GeckoTerminal's busiest Elysium Uniswap v4 pools against HYPE or WHYPE (two pages), one per token, minus the pools
/// of our own launchpads (`ours`: hook addresses, lower case).
async function elysiumTokens(ours) {
  const pages = await Promise.all([1, 2].map((page) =>
    fetch(`https://api.geckoterminal.com/api/v2/networks/elysium/pools?page=${page}&sort=h24_volume_usd_desc&include=base_token,quote_token`, { headers: { accept: "application/json" }, signal: timeout(8000) })
      .then((r) => (r.ok ? r.json() : { data: [], included: [] })).catch(() => ({ data: [], included: [] }))));
  const toks = new Map(pages.flatMap((j) => (j.included || []).filter((x) => x.type === "token").map((x) => [x.id, x.attributes])));
  const seen = new Set(), out = [];
  const pools = pages.flatMap((j) => j.data || []).filter((p) => p.relationships?.dex?.data?.id === "uniswap-v4-elysium");
  await Promise.all(pools.map((p) => poolKey(p.attributes.address).catch(() => null))); // all keys at once (cached after)
  for (const p of pools) {
    const base = toks.get(p.relationships.base_token.data.id), quote = toks.get(p.relationships.quote_token.data.id);
    if (!base || !quote) continue;
    const coin = (t) => t.address === "0x0000000000000000000000000000000000000000" || t.address.toLowerCase() === ELYSIUM_WHYPE;
    const tok = coin(quote) && !coin(base) ? base : coin(base) && !coin(quote) ? quote : null;
    if (!tok || seen.has(tok.address.toLowerCase())) continue;
    const a = p.attributes, onBase = tok === base;
    let key;
    try { key = await poolKey(a.address); } catch { continue; }
    if (!key || ours.has(String(key[4]).toLowerCase())) continue;
    seen.add(tok.address.toLowerCase());
    out.push({
      address: tok.address, name: tok.name, symbol: tok.symbol, image: tok.image_url && tok.image_url !== "missing.png" ? tok.image_url : "",
      price: Number(onBase ? a.base_token_price_usd : a.quote_token_price_usd) || 0,
      // GeckoTerminal's change and price follow the pool's base token: only kept when that is this token; a market cap
      // past $10B is a fully diluted value of an unpriced supply, so unknown
      mc: ((m) => (m < 1e10 ? m : 0))(Number(a.market_cap_usd || a.fdv_usd) || 0), liq: Number(a.reserve_in_usd) || 0, vol: Number(a.volume_usd?.h24) || 0,
      chg: onBase && a.price_change_percentage?.h24 != null ? Number(a.price_change_percentage.h24) / 100 : null,
      created: Date.parse(a.pool_created_at) / 1000 || 0, pool: a.address, key,
    });
  }
  return addImages(out);
}

async function build(origin) {
  const pads = await padList(origin);
  const key = (p) => `${p.chain}:${p.pad.toLowerCase()}`;
  const live = {}, tokens = {}, market = {}, remotes = [];
  await Promise.all([
    ...pads.map(async (p) => {
      try {
        const [a, b] = await Promise.all([hasCode(p.chain, p.pad), p.ethRouter ? hasCode(p.chain, p.ethRouter) : false]);
        live[key(p)] = [a, b];
        if (!a) return;
        await Promise.all([
          tokensOf(p).then((t) => (tokens[key(p)] = t)).catch(() => {}),
          CHAINS[p.chain].blockscout ? marketOf(p).then((m) => (market[key(p)] = m)).catch(() => {}) : null,
        ]);
      } catch {} // unknown: the page checks this launchpad itself
    }),
    ...Object.entries(CHAINS).filter(([, c]) => c.remote).map(([k, c]) => hasCode(k, c.remote).then((y) => y && remotes.push(k)).catch(() => {})),
  ]);
  const ours = new Set(pads.map((p) => p.pad.toLowerCase()));
  const [px, ext] = await Promise.all([prices(), elysiumTokens(ours).catch(() => [])]);
  return { at: Date.now(), live, remotes, tokens, market, prices: px, ext };
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
