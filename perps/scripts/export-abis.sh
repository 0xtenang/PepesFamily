#!/usr/bin/env bash
# Rebuild the contracts and copy their ABIs to abi/ for the keeper and web app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.foundry/bin:$PATH"
(cd "$ROOT/contracts" && forge build >/dev/null)
mkdir -p "$ROOT/abi"
for c in LevLens LevRouter LevPool CreatorFeeRouterV2 PonsV4BuybackExecutor UniV3Oracle UniV4SampledOracle MockV3Pool; do
  python3 -c "import json,sys; json.dump(json.load(open(sys.argv[1]))['abi'], open(sys.argv[2],'w'), indent=1)" \
    "$ROOT/contracts/out/$c.sol/$c.json" "$ROOT/abi/$c.json"
done
# LevExchange answers LevExchangeAdmin's functions too (its fallback delegatecalls them), so one ABI holds both.
python3 - "$ROOT/contracts/out" "$ROOT/abi/LevExchange.json" <<'PY'
import json, sys
out, dest = sys.argv[1], sys.argv[2]
core = json.load(open(f"{out}/LevExchange.sol/LevExchange.json"))["abi"]
admin = json.load(open(f"{out}/LevExchangeAdmin.sol/LevExchangeAdmin.json"))["abi"]
key = lambda e: (e["type"], e.get("name"), tuple(i["type"] for i in e.get("inputs", [])))
seen = {key(e) for e in core}
merged = core + [e for e in admin if e["type"] != "constructor" and key(e) not in seen]
json.dump(merged, open(dest, "w"), indent=1)
PY
rm -f "$ROOT/abi/CreatorFeeRouter.json" # v1, removed
echo "ABIs written to $ROOT/abi"
