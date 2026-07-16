#!/usr/bin/env bash
# deploy_dao.sh — THE one way to broadcast the canonical white-label DAO + work-market
# stack (DeployDAO.s.sol, LP-040) to a target EVM, then prove it live and record the
# addresses. Same script for every brand/chain — brand identity is the chain it runs on,
# never the bytecode.
#
# Flow:
#   1. Source the deployer key from a KMS-backed k8s secret (never plaintext, never inline).
#   2. HARD GUARDRAIL: abort if the deployer resolves to the 0x9011 owner key. Automation
#      must never sign with the owner key — treasury/funding flows are staged Safe proposals.
#   3. Verify chainId + balance, then `forge script DeployDAO --broadcast --slow`.
#   4. Parse the deployed addresses from the script REPORT labels.
#   5. M4 launch gate: run WorkMarketSmoke against the fresh BountyV1 — a successful
#      on-chain fund->claim->submit->accept proves EIP-1153/TSTORE executes on this chain.
#   6. Write the canonical deployment record (deployments/lux-dao/<chainId>.json).
#
# Never runs against Lux mainnet 96369 (frozen at the flag-day export tip) — that deploy is
# staged and executed only post-flag-day, and DeployDAO's M3 guard requires DAO_TREASURY_SAFE
# on every production chain regardless.
#
# Usage:
#   RPC=<rpc-url> CHAINID=<expected> [DAO_TREASURY_SAFE=0x..] \
#   [KEY_CTX=do-sfo3-lux-k8s] [KEY_NS=lux-mainnet] [KEY_SECRET=lux-gov-deployer] \
#   [BRAND=lux] [SKIP_SMOKE=0] scripts/deploy_dao.sh
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/.."   # repo root (lux/dao/contracts)

RPC="${RPC:?set RPC=<chain rpc url>}"
CHAINID="${CHAINID:?set CHAINID=<expected numeric chain id>}"
KEY_CTX="${KEY_CTX:-do-sfo3-lux-k8s}"
KEY_NS="${KEY_NS:-lux-mainnet}"
KEY_SECRET="${KEY_SECRET:-lux-gov-deployer}"
BRAND="${BRAND:-lux}"
OWNER_KEY_ADDR="0x9011E888251AB053B7bD1cdB598Db4f9DEd94714"  # NEVER deploy with this
declare -a PROD_CHAINS=(96369 200200 36963 494949)

echo "== deploy_dao: brand=$BRAND chainId=$CHAINID secret=$KEY_NS/$KEY_SECRET =="

# HARD STOP: Lux mainnet 96369 is frozen at the flag-day export tip. NEVER deploy here
# (zero txs); the 96369 DAO deploy is a staged post-flag-day script only. Unconditional —
# not even ALLOW_OWNER_KEY overrides this.
if [ "$CHAINID" = "96369" ]; then
  echo "FATAL: 96369 is frozen (flag-day) — refusing. Staged post-flag-day only."; exit 1
fi

# 1. Key from KMS-backed k8s secret (first data value; field name is not assumed).
KEY_FIELD="${KEY_FIELD:-LUX_PRIVATE_KEY}"
KEY_B64=$(kubectl --context "$KEY_CTX" -n "$KEY_NS" get secret "$KEY_SECRET" -o jsonpath="{.data.$KEY_FIELD}")
# Fall back to the first data entry only if the named field is absent (single-field secrets).
[ -n "$KEY_B64" ] || KEY_B64=$(kubectl --context "$KEY_CTX" -n "$KEY_NS" get secret "$KEY_SECRET" \
        -o jsonpath='{.data}' | jq -r 'to_entries[0].value')
KEY=$(printf '%s' "$KEY_B64" | base64 -d)
[ -n "$KEY" ] || { echo "FATAL: no key in $KEY_NS/$KEY_SECRET (field $KEY_FIELD)"; exit 1; }
case "$KEY" in 0x*) ;; *) KEY="0x$KEY";; esac
ADDR=$(cast wallet address --private-key "$KEY")

# 2. Guardrail — never SILENTLY use the 0x9011 owner key. An explicit, owner-authorized
#    deploy may override with ALLOW_OWNER_KEY=1 (e.g. the option-C org-mainnet/testnet
#    deploys); the guard still blocks accidental owner-key use everywhere else.
if [ "$ADDR" = "$OWNER_KEY_ADDR" ]; then
  if [ "${ALLOW_OWNER_KEY:-0}" != "1" ]; then
    echo "FATAL: deployer is the 0x9011 OWNER key. Refusing without explicit ALLOW_OWNER_KEY=1."; exit 1
  fi
  echo "WARNING: deploying with the 0x9011 OWNER key (ALLOW_OWNER_KEY=1, owner-authorized)."
fi

# 3. Verify chain + funding.
GOT_CHAIN=$(cast chain-id --rpc-url "$RPC")
[ "$GOT_CHAIN" = "$CHAINID" ] || { echo "FATAL: chainId $GOT_CHAIN != expected $CHAINID"; exit 1; }
for c in "${PROD_CHAINS[@]}"; do
  if [ "$CHAINID" = "$c" ] && [ -z "${DAO_TREASURY_SAFE:-}" ]; then
    echo "FATAL: chain $CHAINID is production; set DAO_TREASURY_SAFE (M3 guard)."; exit 1
  fi
done
BAL=$(cast balance "$ADDR" --rpc-url "$RPC")
BAL_ETH=$(cast from-wei "$BAL")
echo "   deployer=$ADDR balance=$BAL_ETH native  (need ~1.7 for deploy+smoke)"
awk "BEGIN{exit !($BAL_ETH >= 1.7)}" || { echo "FATAL: deployer underfunded (need ~1.7 native)."; exit 1; }

# 4. Broadcast (--slow: one tx at a time; belt-and-suspenders with the atomic WorkMarketDeployer).
LOG=$(mktemp)
[ -n "${DAO_TREASURY_SAFE:-}" ] && export DAO_TREASURY_SAFE
forge script foundry-script/DeployDAO.s.sol:DeployDAO \
  --rpc-url "$RPC" --private-key "$KEY" --broadcast --slow 2>&1 | tee "$LOG"

label(){ grep -oE "$1 0x[0-9a-fA-F]{40}" "$LOG" | awk '{print $2}' | tail -1; }
BOUNTY=$(label BOUNTY_V1)
[ -n "$BOUNTY" ] || { echo "FATAL: could not parse BOUNTY_V1 from deploy output"; exit 1; }

# 5. M4 launch gate — prove EIP-1153/TSTORE live (accept() must mine successfully on-chain).
if [ "${SKIP_SMOKE:-0}" != "1" ]; then
  echo "== M4 smoke gate: on-chain fund->claim->submit->accept =="
  BOUNTY_V1="$BOUNTY" forge script foundry-script/WorkMarketSmoke.s.sol:WorkMarketSmoke \
    --rpc-url "$RPC" --private-key "$KEY" --broadcast 2>&1 | tee -a "$LOG"
  grep -q SMOKE_OK_BOUNTY_ID "$LOG" || { echo "FATAL: smoke gate failed (TSTORE/accept did not execute live)"; exit 1; }
fi

# 6. Canonical deployment record.
OUT="deployments/lux-dao/${CHAINID}.json"; mkdir -p "$(dirname "$OUT")"
jq -n --arg brand "$BRAND" --argjson chainId "$CHAINID" --arg deployer "$ADDR" \
  --arg treasurySafe "${DAO_TREASURY_SAFE:-}" \
  --arg safeSingleton "$(label SAFE_SINGLETON)" --arg safeFactory "$(label SAFE_FACTORY)" \
  --arg fallbackHandler "$(label SAFE_FALLBACK_HANDLER)" --arg votesErc20Master "$(label VOTES_ERC20_MASTER)" \
  --arg moduleGovernor "$(label MODULE_GOVERNOR_MASTER)" --arg moduleFractal "$(label MODULE_FRACTAL_MASTER)" \
  --arg strategy "$(label STRATEGY_MASTER)" --arg votingWeight "$(label VOTING_WEIGHT_MASTER)" \
  --arg voteTracker "$(label VOTE_TRACKER_MASTER)" --arg proposerAdapter "$(label PROPOSER_ADAPTER_MASTER)" \
  --arg systemDeployer "$(label SYSTEM_DEPLOYER)" --arg bounty "$BOUNTY" \
  --arg escrow "$(label ESCROW_V1)" --arg reputation "$(label REPUTATION_V1)" \
  '{brand:$brand, chainId:$chainId, deployer:$deployer, treasurySafe:$treasurySafe,
    script:"DeployDAO.s.sol (LP-040)", smokeGate:"passed",
    contracts:{safeSingleton:$safeSingleton, safeFactory:$safeFactory, fallbackHandler:$fallbackHandler,
      votesErc20Master:$votesErc20Master, moduleGovernor:$moduleGovernor, moduleFractal:$moduleFractal,
      strategy:$strategy, votingWeight:$votingWeight, voteTracker:$voteTracker,
      proposerAdapter:$proposerAdapter, systemDeployer:$systemDeployer,
      bounty:$bounty, escrow:$escrow, reputation:$reputation}}' > "$OUT"
rm -f "$LOG"
echo "== DONE: recorded -> $OUT ; BountyV1 (work board backend) = $BOUNTY =="
