#!/usr/bin/env bash
# Verifies the source code of every token launched on PepesFamily that isn't verified yet, so explorers and
# scanners (Blockscout, DexScreener, GMGN, ...) show it as open source. Safe to run repeatedly.
# Needs Foundry and the git submodules. Usage: ./script/verify-tokens.sh   (from contracts/)
set -uo pipefail

RPC="${RPC_URL:-https://robinhood.drpc.org}"
PAD=0x2d7689E48Fd71D9A0f225C673D7b8F8A693368CC
CHAIN=4663
BLOCKSCOUT="https://robinhoodchain.blockscout.com/api/"

count=$(cast call "$PAD" "tokenCount()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
echo "PepesFamily tokens: $count"

for ((i = 0; i < count; i++)); do
  token=$(cast call "$PAD" "allTokens(uint256)(address)" "$i" --rpc-url "$RPC")
  if curl -sf "https://sourcify.dev/server/v2/contract/$CHAIN/$token" >/dev/null; then
    echo "[$i] $token already verified"
    continue
  fi

  name=$(cast call "$token" "name()(string)" --rpc-url "$RPC" | jq -r .)
  symbol=$(cast call "$token" "symbol()(string)" --rpc-url "$RPC" | jq -r .)
  metadata=$(cast call "$token" "metadata()(string)" --rpc-url "$RPC" | jq -r .)
  quote=$(cast call "$token" "quote()(address)" --rpc-url "$RPC")
  creator=$(cast call "$token" "creator()(address)" --rpc-url "$RPC")
  router=$(cast call "$token" "router()(address)" --rpc-url "$RPC")
  pm=$(cast call "$token" "poolManager()(address)" --rpc-url "$RPC")
  args=$(cast abi-encode "f(string,string,string,address,address,address,address)" \
    "$name" "$symbol" "$metadata" "$quote" "$creator" "$router" "$pm")

  echo "[$i] $token ($symbol): verifying"
  forge verify-contract "$token" src/PadToken.sol:PadToken --chain-id "$CHAIN" \
    --verifier sourcify --constructor-args "$args" --watch || echo "  sourcify failed"
  # Blockscout imports Sourcify results, but also try it directly (may be rate limited / challenged).
  forge verify-contract "$token" src/PadToken.sol:PadToken --chain-id "$CHAIN" \
    --verifier blockscout --verifier-url "$BLOCKSCOUT" --constructor-args "$args" >/dev/null 2>&1 \
    && echo "  blockscout ok" || echo "  blockscout skipped"
done
