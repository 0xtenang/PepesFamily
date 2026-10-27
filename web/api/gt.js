// Vercel serverless function: GeckoTerminal's public API (token lists, pools, candles) through Vercel's CDN cache,
// so every visitor shares the same answers instead of each spending GeckoTerminal's ~30 requests a minute.
//   GET /api/gt?p=/networks/robinhood/pools/0x…/ohlcv/minute?aggregate=15&limit=1000&currency=usd&token=base
// Only GeckoTerminal's /networks/... read endpoints are passed on.

const ALLOWED = /^\/networks\/[a-z0-9-]+\/(trending_pools|tokens|pools)(\/[0-9a-zA-Zx]+)?(\/ohlcv\/(minute|hour|day))?(\?[\w=&.,-]*)?$/;

module.exports = async (req, res) => {
  const path = String(req.query.p || "");
  if (req.method !== "GET" || !ALLOWED.test(path)) return res.status(400).json({ error: "Not a GeckoTerminal endpoint this site uses" });
  try {
    const r = await fetch("https://api.geckoterminal.com/api/v2" + path, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(10000) });
    const text = await r.text();
    // candles by the minute change fast; token lists (40 pages for Discover) are shared for 2 minutes so the
    // function's own GeckoTerminal allowance (~30 a minute) is never used up; token details change slowly
    const ttl = /ohlcv\/minute/.test(path) ? 30 : /ohlcv|trending_pools|\/pools\?/.test(path) ? 120 : 300;
    res.setHeader("Cache-Control", r.ok ? `public, s-maxage=${ttl}, stale-while-revalidate=600` : "no-store");
    res.status(r.status).setHeader("content-type", "application/json").send(text);
  } catch {
    res.setHeader("Cache-Control", "no-store");
    res.status(502).json({ error: "GeckoTerminal didn't answer" });
  }
};
