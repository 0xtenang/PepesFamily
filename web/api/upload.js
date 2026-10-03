// Vercel serverless function: uploads a token image to IPFS through Pinata and returns its ipfs:// link.
// The Pinata key lives only in the Vercel environment variable PINATA_JWT and never reaches the browser.
//   GET  /api/upload  -> { enabled }            (the launch form shows the Upload button only when enabled)
//   POST /api/upload  { type, data (base64) } -> { cid, url }
// Only small PNG / JPEG / GIF / WEBP files are accepted (the page resizes images to 512 px before sending).

const MAX_BYTES = 1024 * 1024;
const MAGIC = {
  "image/png": [0x89, 0x50, 0x4e, 0x47],
  "image/jpeg": [0xff, 0xd8, 0xff],
  "image/gif": [0x47, 0x49, 0x46, 0x38],
  "image/webp": [0x52, 0x49, 0x46, 0x46], // "RIFF" ... "WEBP"
};
// Browsers always send Origin on a POST; requests from other sites are refused. (A script outside a browser can
// fake it, so this only keeps other websites from using the endpoint; the size and type limits still apply.)
const ORIGINS = ["https://pepesfamily.fun", "https://www.pepesfamily.fun"];

module.exports = async (req, res) => {
  res.setHeader("Cache-Control", "no-store");
  const jwt = process.env.PINATA_JWT;
  if (req.method === "GET") return res.status(200).json({ enabled: Boolean(jwt) });
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });
  if (!jwt) return res.status(503).json({ error: "Image upload isn't set up yet" });
  if (!ORIGINS.includes(req.headers.origin || "")) return res.status(403).json({ error: "Forbidden" });

  const { type, data } = req.body || {};
  const magic = MAGIC[type];
  if (!magic || typeof data !== "string") return res.status(400).json({ error: "Send a PNG, JPG, GIF or WEBP image" });
  const buf = Buffer.from(data, "base64");
  if (!buf.length || buf.length > MAX_BYTES) return res.status(413).json({ error: "Image must be under 1 MB" });
  const valid = magic.every((b, i) => buf[i] === b) && (type !== "image/webp" || buf.toString("ascii", 8, 12) === "WEBP");
  if (!valid) return res.status(400).json({ error: "That file isn't a valid image" });

  const form = new FormData();
  form.append("file", new Blob([buf], { type }), "token." + type.slice(6).replace("jpeg", "jpg"));
  form.append("network", "public"); // public IPFS, so any gateway (and the site) can show it
  try {
    const r = await fetch("https://uploads.pinata.cloud/v3/files", {
      method: "POST",
      headers: { Authorization: "Bearer " + jwt },
      body: form,
      signal: AbortSignal.timeout(20000),
    });
    const j = await r.json().catch(() => ({}));
    const cid = j && j.data && j.data.cid;
    if (!r.ok || typeof cid !== "string" || !/^[A-Za-z0-9]{46,}$/.test(cid)) {
      console.error("pinata upload failed", r.status, JSON.stringify(j).slice(0, 300));
      return res.status(502).json({ error: "Upload failed, please try again" });
    }
    return res.status(200).json({ cid, url: "ipfs://" + cid });
  } catch (e) {
    console.error("pinata upload error", e && e.message);
    return res.status(502).json({ error: "Upload failed, please try again" });
  }
};
