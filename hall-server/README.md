# Hall server

The multiplayer Hall on pepesfamily.fun: who is in the Hall, where they stand and what they look like (their Pepes
Family NFT). A Cloudflare Worker (`index.js`) with one Durable Object per room of 60 players; WebSocket hibernation,
so idle players cost nothing. Nothing is stored. Nicknames and chat were removed on 2026-10-18: players join under a
throwaway name nobody sees, and the server ignores chat.

The server checks positions (kept inside the room), looks and message rates, and only lets the site's own addresses
connect.

## Deploy

No Node needed, only curl:

```bash
./hall-server/deploy.sh
```

It asks for your Cloudflare account ID and an API token (My Profile > API Tokens > Create Token > "Edit Cloudflare
Workers"); the token is read hidden and never saved. It prints the server's address: put it in `CONFIG.hallServer` in
`web/index.html` (`wss://pepesfamily.arief-kurniawan-id.workers.dev/hall`). Running it again updates the code.

The free plan covers a busy Hall (100,000 requests a day; 20 WebSocket messages count as one request). Players send
their position at most 5 times a second, and only while moving.
