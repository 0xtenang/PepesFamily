# PepesAgent: going live

The worker (this folder, on Render) runs the bot and the Agent page's API. Everything stays in shadow mode (nothing is sent)
until `AGENT_LIVE=true` is set.

## 1. Privy (dashboard.privy.io, app `cmvqjognl02en0hle77o94cri`)

1. **Solana:** turn on Solana embedded wallets and Phantom as a login wallet (Login methods > Wallets).
2. **Agent key:** on your own computer, make the key pair the worker signs with:
   ```bash
   openssl ecparam -name prime256v1 -genkey -noout -out agent-key.pem
   openssl ec -in agent-key.pem -pubout -out agent-key.pub.pem
   openssl pkcs8 -topk8 -nocrypt -in agent-key.pem -outform DER | base64
   ```
   The last line is `PRIVY_AUTHORIZATION_KEY` (goes only into Render). Register the public key
   (`agent-key.pub.pem`) in the dashboard as a **key quorum** (Wallet infrastructure > Authorization keys, 1 of 1).
   Its id is `PRIVY_SIGNER_ID`. Delete the files afterwards.
3. **Policy:** create a Solana policy (Policies > New) from `policy.json` below. Its id is `PRIVY_POLICY_IDS`.

### policy.json

```json
{
  "version": "1.0",
  "name": "PepesAgent",
  "chain_type": "solana",
  "rules": [
    {
      "name": "Meteora DLMM, Jupiter, token accounts",
      "method": "*",
      "conditions": [{ "field_source": "solana_program_instruction", "field": "programId", "operator": "in", "value": [
        "LBUZKhRxPF3XUpBCjp4YzTKgLccjZhTSDM9YuVaPwxo",
        "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QAvbyto4",
        "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
        "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb",
        "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL",
        "ComputeBudget111111111111111111111111111111",
        "MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr"
      ] }],
      "action": "ALLOW"
    },
    {
      "name": "Profit fee: SOL to the fee wallet",
      "method": "*",
      "conditions": [
        { "field_source": "solana_system_program_instruction", "field": "instructionName", "operator": "eq", "value": "Transfer" },
        { "field_source": "solana_system_program_instruction", "field": "Transfer.to", "operator": "eq", "value": "Gy1Ub83ERYtC4y7PNyTKEbuokZUWnt2TQ4DPaX77anQ" },
        { "field_source": "solana_system_program_instruction", "field": "Transfer.lamports", "operator": "lte", "value": "500000000" }
      ],
      "action": "ALLOW"
    },
    {
      "name": "Wrapping SOL for a position (to the wallet's own wSOL account), capped at one position",
      "method": "*",
      "conditions": [
        { "field_source": "solana_system_program_instruction", "field": "instructionName", "operator": "eq", "value": "Transfer" },
        { "field_source": "solana_system_program_instruction", "field": "Transfer.lamports", "operator": "lte", "value": "1100000000" }
      ],
      "action": "ALLOW"
    },
    {
      "name": "Accounts the SDKs create",
      "method": "*",
      "conditions": [
        { "field_source": "solana_system_program_instruction", "field": "instructionName", "operator": "in", "value": ["CreateAccount", "CreateAccountWithSeed", "Allocate", "Assign"] }
      ],
      "action": "ALLOW"
    }
  ]
}
```

**Known limit (check in the beta):** opening a position first moves SOL into the wallet's own wrapped-SOL account
with a plain transfer, and Privy's policy can't tell "to my own wSOL account" from "to anyone". The third rule
therefore allows transfers up to one position's size (1.1 SOL) to any address. If the worker's key leaked, a wallet
could be drained in position-sized steps. Before raising the beta caps, test whether these opens can wrap through the
token program instead, and tighten or drop that rule. Also check in the beta: that Privy keeps the new position
key's signature (`partialSign`), and that only top-level instructions are checked (Jupiter routes call many DEXes).

**Done 2026-11-01:** Phantom/Solana sign-in on; agent key `gtfdxu6nd0kfmr8wjchzisnd` (`PRIVY_SIGNER_ID`);
policy `aq37pdzg0k081xuwuwh0icqm` (`PRIVY_POLICY_IDS`), made in the dashboard form with the four rules above, all on
`signAndSendTransaction` only (the agent never uses `*`, which would also allow exporting keys). Jupiter swaps for
agent wallets are therefore signed and sent directly, not through Jupiter's `/execute`; check in the beta that the
routes `/order` returns land this way (RFQ routes may need `/execute`).

## 2. Hosting: Render (running)

Service `pepes-agent` (https://pepes-agent.onrender.com): Web Service from `0xtenang/PepesFamily`, root directory
`agent`, build `npm install`, start `node index.js`, Starter plan ($7/month), 1 GB disk at `/data`, health check
`/health`, auto-deploy on commit. Railway had sign-ups closed. A deploy makes the API unreachable for a minute or so.

Variables, entered in Render only: `DATA_DIR=/data`, `RPC_URL` and `MONITOR_WS_URL` (Helius), `PRIVY_APP_ID`,
`PRIVY_APP_SECRET`, `PRIVY_AUTHORIZATION_KEY`, `PRIVY_SIGNER_ID`, `PRIVY_POLICY_IDS`, `AGENT_LIVE=false`.

## 3. Going live

1. Watch shadow results for a week or two (the Agent page's signal list, Render logs, `/agent/stats`).
2. Beta: set `AGENT_LIVE=true`, keep the caps
   (`MAX_POSITION_SOL=1`, `MAX_POSITIONS=3`), and trade small amounts from the team's own wallets first.
3. Raise the caps when the policy limit above is resolved.
