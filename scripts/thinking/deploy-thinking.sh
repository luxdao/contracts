#!/usr/bin/env bash
# deploy-thinking.sh — deploy the Thinking Chains AI-mining + governance stack to
# a Lux C-Chain (devnet -> testnet -> mainnet). Reads the deployer mnemonic from a
# 600-perm file (NEVER from argv/stdout); pays gas in the chain's native LUX.
#
#   Usage:  RPC=<c-chain-rpc> [MN_FILE=/tmp/.luxmn] [TREASURY=0x..] deploy-thinking.sh
#
# Deploys: ProofOfThoughtRegistry, ThinkingGovernor, ThinkingChainObservatory,
# GovernancePoTBridge — the same stack proven locally (105 tests) + verified on
# anvil + the native hanzo-engine governance round.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH" FOUNDRY_DISABLE_NIGHTLY_WARNING=1
HERE="$(cd "$(dirname "$0")" && pwd)"; CONTRACTS="$(cd "$HERE/../.." && pwd)"; cd "$CONTRACTS"
T="contracts/deployables/thinking"

: "${RPC:?set RPC to the target C-Chain rpc url}"
MN_FILE="${MN_FILE:-/tmp/.luxmn}"
[ -r "$MN_FILE" ] || { echo "mnemonic file $MN_FILE not readable — see handoff instructions"; exit 1; }
# foundry --mnemonic accepts a FILE PATH; the seed never enters argv/env/stdout.

# deployer address (no secret printed) + preflight: chain id + balance for gas
DEPLOYER="$(cast wallet address --mnemonic "$MN_FILE")"
CHAINID="$(cast chain-id --rpc-url "$RPC")"
BAL="$(cast balance "$DEPLOYER" --rpc-url "$RPC")"
echo "network chainId=$CHAINID  deployer=$DEPLOYER  balance=${BAL} wei"
[ "$BAL" = "0" ] && { echo "ABORT: deployer has 0 balance on $RPC (needs native LUX for gas)"; exit 1; }

TREASURY="${TREASURY:-$DEPLOYER}"
create(){ forge create "$1" --rpc-url "$RPC" --mnemonic "$MN_FILE" --broadcast --json ${2:+--constructor-args $2} 2>/dev/null \
          | python3 -c 'import sys,json;print(json.load(sys.stdin)["deployedTo"])'; }

echo "== deploying Thinking Chains AI-mining + governance stack =="
REG=$(create "$T/ProofOfThoughtRegistry.sol:ProofOfThoughtRegistry")
GOV=$(create "$T/ThinkingGovernor.sol:ThinkingGovernor" "1000000000000000000 0 500000000000000000 100000000000000000 $TREASURY 0x0000000000000000000000000000000000000000")
OBS=$(create "$T/ThinkingChainObservatory.sol:ThinkingChainObservatory" "$GOV $REG")
BRIDGE=$(create "$T/GovernancePoTBridge.sol:GovernancePoTBridge" "$GOV $REG")
REP=$(create "$T/ThinkingReputation.sol:ThinkingReputation" "$GOV 2000")
# Native coin: 1B cap, halving every 4y, burn tail (core paper Tokenomics).
# admin = TREASURY (the DAO seat); minter = 0 here — governance wires it to the
# settlement contract via setMinter() once the on-chain mint policy is ratified.
AICOIN=$(forge create "$T/AICoin.sol:AICoin" --rpc-url "$RPC" --mnemonic "$MN_FILE" --broadcast --json \
         --constructor-args "AI" "AI" "$TREASURY" "0x0000000000000000000000000000000000000000" 2>/dev/null \
         | python3 -c 'import sys,json;print(json.load(sys.stdin)["deployedTo"])')

echo "== deployed =="
echo "  registry    = $REG"
echo "  governor    = $GOV"
echo "  observatory = $OBS"
echo "  bridge      = $BRIDGE"
echo "  reputation  = $REP"
echo "  aicoin      = $AICOIN"

# verify the stack is live: read overview() back from the chain
echo "== verify (overview read back on-chain) =="
cast call "$OBS" "overview()((uint256,uint256,uint256,uint256,uint256,uint256,uint256,address))" --rpc-url "$RPC"

# record the deployment (gitignored dir is fine; this is a public address record)
OUT="$CONTRACTS/deployments/thinking-${CHAINID}.json"
mkdir -p "$CONTRACTS/deployments"
python3 -c "import json,sys;json.dump({'chainId':int('$CHAINID'),'deployer':'$DEPLOYER','contracts':{'ProofOfThoughtRegistry':'$REG','ThinkingGovernor':'$GOV','ThinkingChainObservatory':'$OBS','GovernancePoTBridge':'$BRIDGE','ThinkingReputation':'$REP','AICoin':'$AICOIN'}},open('$OUT','w'),indent=2)" && echo "recorded -> $OUT"

echo "== DONE on chainId $CHAINID =="
echo "DEPLOY_RESULT chainId=$CHAINID registry=$REG governor=$GOV observatory=$OBS bridge=$BRIDGE reputation=$REP aicoin=$AICOIN"
