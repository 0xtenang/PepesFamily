# Hall server

The multiplayer Hall on pepesfamily.fun: who is in the Hall, where they stand, what they look like (their Pepes
Family NFT), their nicknames and the chat. A Cloudflare Worker (`index.js`) with one Durable Object per room of 60
players; WebSocket hibernation, so idle players cost nothing. It keeps only the last 40 chat lines of each room.

The server checks everything: nicknames (2-16 letters, numbers, spaces, `.` `_` `-`; nothing that passes for staff,
like admin, mod, official, IMD or PepesFamily), chat (200 characters, one line every 1.5 s and 6 in 20 s, no
repeats; links and wallet addresses are replaced with `[link]` and `[address]`, the usual way scams travel), positions
(kept inside the room) and message rates. Only the site's own addresses may connect.

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
