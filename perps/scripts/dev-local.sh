#!/usr/bin/env bash
# One command for the whole local stack: anvil, contracts, keeper, moving demo prices, the one-click relayer and the
# web app.
#   scripts/dev-local.sh            then open http://localhost:5180
# Ctrl+C stops everything.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.foundry/bin:$PATH"
PORT=8547
RPC="http://127.0.0.1:$PORT"
RELAYER_URL="http://127.0.0.1:${RELAYER_PORT:-8790}"
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # public anvil test key

for dir in keeper relayer web; do
  if [ ! -d "$ROOT/$dir/node_modules" ]; then
    echo "missing $dir dependencies: run (cd $dir && npm install) first" >&2
    exit 1
  fi
done

pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

if ! cast client --rpc-url "$RPC" >/dev/null 2>&1; then
  anvil --block-time 2 --port "$PORT" --silent &
  pids+=($!)
  until cast client --rpc-url "$RPC" >/dev/null 2>&1; do sleep 0.5; done
  (cd "$ROOT/contracts" && forge script script/DeployLocal.s.sol --rpc-url local --broadcast --private-key "$DEPLOYER_KEY" >/dev/null)
  echo "deployed: $ROOT/contracts/deployments/local.json"
fi

"$ROOT/scripts/export-abis.sh" >/dev/null
(cd "$ROOT/keeper" && exec node src/keeper.ts) &
pids+=($!)
(cd "$ROOT/keeper" && exec node src/demo-prices.ts) &
pids+=($!)
# One-click trading: the app sends session-key trades to this relayer (anvil key 5 pays their gas).
if curl -fsS --max-time 2 "$RELAYER_URL/health" >/dev/null 2>&1; then
  echo "relayer already running at $RELAYER_URL"
else
  (cd "$ROOT/relayer" && exec node src/server.ts) &
  pids+=($!)
fi
(cd "$ROOT/web" && exec npm run dev) &
pids+=($!)
wait
