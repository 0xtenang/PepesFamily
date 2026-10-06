#!/usr/bin/env bash
# Verifies the source code of every token launched on PepesFamily (all launchpad versions) that isn't verified yet,
# so explorers and scanners (Blockscout, DexScreener, GMGN, ...) show it as open source. Safe to run repeatedly.
# Needs Foundry and the git submodules. Usage: ./script/verify-tokens.sh   (from contracts/)
set -uo pipefail

RPC="${RPC_URL:-https://robinhood.drpc.org}"
CHAIN=4663
BLOCKSCOUT="https://robinhoodchain.blockscout.com/api/"
# launchpad address -> the token contract it deploys (each version's exact source is kept in the repo)
PADS=(
  "0x6C08cfB2aB8Dab6d4Bc22ab8F1C248a0268D28cc src/PadToken.sol:PadToken"        # v4
  "0xC5a1f48C03635b83D79667463785bC2c6BcE28cC src/v3/PadTokenV3.sol:PadTokenV3" # v3
  "0x072Fb5A1B65F30d59BcD11BEeD99803675bCE8CC src/v2/PadTokenV2.sol:PadTokenV2" # v2
  "0x2d7689E48Fd71D9A0f225C673D7b8F8A693368CC src/v1/PadTokenV1.sol:PadTokenV1" # v1
)

for entry in "${PADS[@]}"; do
  read -r PAD CONTRACT <<<"$entry"
  if [ "$(cast code "$PAD" --rpc-url "$RPC")" = "0x" ]; then
    echo "$PAD not deployed yet, skipping"
    continue
  fi
  count=$(cast call "$PAD" "tokenCount()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
  echo "Launchpad $PAD: $count tokens"

  for ((i = 0; i < count; i++)); do
    token=$(cast call "$PAD" "allTokens(uint256)(address)" "$i" --rpc-url "$RPC")
    if curl -sf "https://sourcify.dev/server/v2/contract/$CHAIN/$token" >/dev/null; then
      echo "  [$i] $token already verified"
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

    echo "  [$i] $token ($symbol): verifying"
    forge verify-contract "$token" "$CONTRACT" --chain-id "$CHAIN" \
      --verifier sourcify --constructor-args "$args" --watch || echo "    sourcify failed"
    # Blockscout imports Sourcify results, but also try it directly (may be rate limited / challenged).
    forge verify-contract "$token" "$CONTRACT" --chain-id "$CHAIN" \
      --verifier blockscout --verifier-url "$BLOCKSCOUT" --constructor-args "$args" >/dev/null 2>&1 \
      && echo "    blockscout ok" || echo "    blockscout skipped"
  done
done
