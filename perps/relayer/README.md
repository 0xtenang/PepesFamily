# Relayer

Gasless one-click trading for MemeLev. A trader approves a P-256 session key once, with one wallet transaction (`LevRouter.authorize`, usually together with the deposit). After that the browser signs each open, close, withdraw or logout with that key. The relayer checks the signed intent, submits it to `LevRouter` and pays the gas.

`LevRouter.sol` is the source of truth. The relayer only ever calls `router.open`, `close`, `withdraw` and `revokeBySig`.

```bash
npm install
node src/server.ts        # local anvil stack, http://127.0.0.1:8790
node src/e2e.ts           # local end-to-end check: uses the relayer on 8790 if one is running, else starts its own on a free port
```

On Robinhood Chain:

```bash
DEPLOYMENT=../contracts/deployments/robinhood.json RELAYER_PRIVATE_KEY=0x… RELAYER_ORIGINS=https://app.example node src/server.ts
```

| Env | Default | |
|---|---|---|
| `RELAYER_PORT` | `8790` | |
| `RELAYER_HOST` | `127.0.0.1` | |
| `RELAYER_ORIGINS` | `http://localhost:5180,http://127.0.0.1:5180` | CORS allowlist. Requests from any other browser origin get 403 |
| `RELAYER_PRIVATE_KEY` | anvil key #5, local chain only | Required on every other chain |
| `DEPLOYMENT` | `../contracts/deployments/local.json` | |
| `RPC_URL` | the deployment's `rpcUrl` | |
| `TRUST_PROXY` | off | `1` takes the client IP from `X-Forwarded-For` (for per-IP limits behind a proxy). The IP is the **rightmost** entry (the one the trusted proxy appended), never the client-chosen leftmost one |
| `TRUST_PROXY_HOPS` | `1` | How many trusted proxies sit in front; the client IP is that many entries from the right of `X-Forwarded-For` |
| `RELAYER_URL` | `http://127.0.0.1:8790` | e2e only: the running relayer to test. Empty starts a fresh one on a free port (two relayers with one key race for tx nonces) |

Advanced tunables (env, with safe defaults): `RELAYER_OWNER_PER_MIN` (20), `RELAYER_IP_PER_MIN` (60), `RELAYER_MAX_PENDING_PER_OWNER` (2), `RELAYER_MAX_QUEUE` (500), `RELAYER_GAS_CAP` (per-kind default: 3M open/close, 2M withdraw, 1.5M revoke).

## API

`GET /health` returns `{ ok: true, chainId, router, relayer, balanceWei, queued, inFlight }`.

`POST /intents`

```json
{
  "kind": "open",
  "intent": { "owner": "0x…", "key": "0x…", "generation": "1", "marketId": "0", "isLong": true, "leverage": "2",
              "stake": "20000000000000000", "limitTick": "-185725", "nonce": "1234…", "deadline": "1793262041" },
  "signature": { "r": "0x…", "s": "0x…" }
}
```

- `kind` is `open`, `close`, `withdraw` or `revoke`. The intent fields are exactly those of the matching struct in `LevRouter`. Numbers go as decimal strings, bools as booleans, and addresses and bytes32 as 0x hex. Unknown or missing fields, wrong types, out-of-range numbers and bodies over 8 KB are refused.
- **202** `{ id: "<owner>:<nonce>", status: "pending" }`: the first simulation passed, or failed for a temporary reason.
- **400** `{ error, permanent: true }`: refused for good. `error` is the router or exchange error name (`BadSignature`, `NonceUsed`, `BadDeadline`, `OverLimit`, `SessionInvalid`, `InsufficientBalance`, …), `GasTooHigh` when the call's gas estimate is over the per-kind ceiling, or a message saying which field is wrong. Oversized bodies get **413** `BodyTooLarge`.
- **429** `{ error: "RateLimited", permanent: false, retryAfter }` with a `Retry-After` header. The limits are 20 intents a minute per owner and 60 per IP; the owner limit is charged only once an intent authenticates, so junk naming someone else can't use up their budget. There is also a cap of 2 intents pending per owner and a global queue cap, so a flood of intents that fail temporarily can't stall everyone.
- Sending the same intent again while it is pending or sent returns its current status. A different intent that reuses an in-flight nonce gets 400 `NonceInFlight`.

`GET /intents/:owner/:nonce` returns `{ status, txHash?, positionId?, error?, receivedAt, sentAt?, includedAt?, blockNumber?, submitter? }`. Times are Unix ms on the relayer's clock. `positionId` is read from `IntentExecuted` for opens and copied from the intent for closes. While an intent is pending, `error` holds the last temporary error, for example `PriceMoved`. Statuses stay in memory for an hour.

| Status | Meaning |
|---|---|
| `pending` | Queued. Temporary failures (`PriceMoved`, `TooSoon`, `OracleDown`, `BreakerTripped`, RPC trouble) are simulated again every 2 s until the deadline |
| `sent` | The tx is out (`txHash`) |
| `confirmed` | `router.nonceUsed` is true after inclusion. That also covers someone else landing the intent first, even if our own tx reverted |
| `failed` | A permanent error after acceptance, or `cancelNonce` used the nonce without the intent running. A `NonceUsed` seen while pending is checked against `IntentExecuted` first, so an intent that actually ran lands on `confirmed`, not `failed` |
| `expired` | The deadline passed before the intent could run. Nothing happened |

## How it works

1. Validate the body against the EIP-712 types. Check the deadline against the latest block: not in the past and at most 120 s ahead.
2. Simulate (and price) the router call from the relayer's account. A permanent revert gets a 400 right away; so does an estimate over the per-kind gas ceiling (`GasTooHigh`), which stops a contract owner whose `receive()` burns gas from draining the relayer. If the RPC is unreachable at this point, the answer is 503, not a queued intent.
3. One queue sends everything, so the relayer's tx nonces never collide. Each intent is simulated again just before sending, and the gas it sends (estimate × 1.2) is capped by the same ceiling. While one of an owner's txs is in flight, that owner's later intents wait for it, so each one is simulated against the state it will actually meet. Intents that keep failing temporarily are re-simulated with a growing backoff.
4. After inclusion the relayer reads `nonceUsed` and the `IntentExecuted` event. If our tx reverted but the intent has not run yet (the price moved after the simulation), the intent goes back to the queue, up to 3 sends; after that it waits out its deadline rather than being called failed, since the signed intent is still valid and could be landed by anyone.
5. Each intent's `receivedAt`, `sentAt` and `includedAt` are logged as one JSON line when it finishes (or `receivedAt` and the error when it is refused), so relay delay can be audited.

## Signing (`src/session.ts`)

It uses only WebCrypto and viem, so the web app can import it or copy it.

```ts
const session = await createSessionKey(); // non-extractable P-256; keep the CryptoKey in IndexedDB
// wallet tx: router.authorize(session.qx, session.qy, limits) with value = deposit
// limitTick: the worst exit you accept (a long's close reverts below it, a short's above it)
const intent = { owner, key: session.key, generation, positionId, limitTick, nonce: randomNonce(), deadline: deadlineFrom(block.timestamp) };
const sig = await signIntent(session.privateKey, 'close', intent, chainId, router);
await fetch(`${RELAYER}/intents`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(bodyFor('close', intent, sig)) });
```

WebCrypto signs SHA-256 of the 32-byte EIP-712 digest, which is what the router verifies. `signDigest` flips `s` to the low half, because the router refuses high-s signatures. The digest matches the router's `hashOpen`, `hashClose`, `hashWithdraw` and `hashRevoke` views, and the e2e checks all four.

## Security notes

- **The relayer pays gas and holds no user funds.** Its key only needs ETH for gas. Use a different key from the keeper's (`RELAYER_PRIVATE_KEY` vs `KEEPER_PRIVATE_KEY`; anvil #5 vs #2 locally), so a leak of one does not touch the other and their tx nonces never clash.
- **What the relayer controls is timing, nothing else.** Every field is signed, nonces stop replays, and withdrawals always pay the owner's own address. Within the deadline (the app signs 30 s; the router accepts at most 120 s) the relayer can choose when an intent lands. That lets it pick the fill, but only within the session's slippage bound (`openSlipTicks` and `closeSlipTicks` around the fast price) and the intent's own `limitTick`. The logged times make holding intents back visible.
- **It can refuse to relay, but it can't block.** The router functions are permissionless, so a backup relayer or the trader's own wallet can submit the same signed intent. The owner can always `revoke`, `revokeAll` or `cancelNonce` directly.
- **A stolen session key is bounded by the limits the owner set**: actions, max leverage, stake per trade, open stake, daily budget and expiry (at most 7 days). It can never move funds anywhere but the owner's address.
- **Gas griefing.** Every send is simulated first, each owner has one tx in flight at a time, an intent gets at most 3 sends, and there are per-owner and per-IP limits. A valid intent still needs a session that the owner approved on-chain. Each intent kind also has a hard gas ceiling (`RELAYER_GAS_CAP`): an estimate above it is refused with `GasTooHigh` and never sent, so a `Withdraw` to a contract owner whose `receive()` burns gas can't drain the relayer. Still worth considering before mainnet: a per-owner rolling gas budget and a `maxFeePerGas` cap for a backlog that pushes the base fee up.
- **CORS is not authentication.** The allowlist only keeps other sites' pages from using this relayer through users' browsers. What actually protects users is the signatures and on-chain limits.

## Not done

- Statuses, the queue and rate limits live in memory, in a single process. A restart forgets them. Intents already sent can still land, and their result is on-chain (`nonceUsed`, `openedBy`, `IntentExecuted`).
- There is no fee bumping or replacement for a stuck tx. If one never gets mined, its intent expires, but later relayer txs queue behind that nonce. That doesn't happen on anvil; on a real chain, watch for it.
- On chains whose RPC treats `pending` like `latest` for nonces, two relayer processes sharing one key can collide. A failed send resyncs the nonce and retries, but give each instance its own key.
