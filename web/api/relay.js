// Vercel serverless function: passes the site's "pay from any chain" requests to Relay (api.relay.link) with this
// site's Relay API key, which lives only in the Vercel environment variable RELAY_API_KEY and never reaches the
// browser. Without the key it answers 404 and the page calls Relay directly (fine while Relay serves keyless quotes).
//   POST /api/relay?p=quote/v2                       -> Relay's quote
//   GET  /api/relay?p=intents/status/v3?requestId=…  -> a payment's status
// Only those two Relay endpoints are passed on.

const ALLOWED = [/^quote\/v2$/, /^intents\/status\/v3\?requestId=0x[0-9a-fA-F]{64}$/];
const ORIGINS = ["https://pepesfamily.fun", "https://www.pepesfamily.fun", "https://pepesimd.fun", "https://www.pepesimd.fun"];

module.exports = async (req, res) => {
  res.setHeader("Cache-Control", "no-store");
  const key = process.env.RELAY_API_KEY;
  if (!key) return res.status(404).json({ error: "No Relay key here: call Relay directly" });
  const origin = req.headers.origin || "";
  if (req.method === "POST" && !ORIGINS.includes(origin)) return res.status(403).json({ error: "Forbidden" });
  const path = String(req.query.p || "");
  if (!ALLOWED.some((r) => r.test(path))) return res.status(400).json({ error: "Not a Relay endpoint this site uses" });
  if ((req.method === "POST") !== path.startsWith("quote")) return res.status(405).json({ error: "Method not allowed" });
  try {
    const r = await fetch("https://api.relay.link/" + path, {
      method: req.method,
      headers: { "content-type": "application/json", "x-api-key": key },
      body: req.method === "POST" ? JSON.stringify(req.body || {}) : undefined,
      signal: AbortSignal.timeout(20000),
    });
    const text = await r.text();
    res.status(r.status).setHeader("content-type", "application/json").send(text);
  } catch (e) {
    res.status(502).json({ error: "Relay didn't answer" });
  }
};
