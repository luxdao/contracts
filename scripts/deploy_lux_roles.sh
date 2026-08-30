#!/usr/bin/env bash
# ============================================================================
# Lux DAO — luxfi-native IHats roles protocol + ERC-6551 sub-wallet bring-up.
#
# Deploys the drop-in `rolesProtocol` (LuxRolesV1) + `rolesAccount1ofNMasterCopy`
# (LuxRolesAccount1ofNV1) that light up DAO roles + token-bound sub-wallets for the
# lux.vote / zoo.vote / pars.vote apps WITHOUT the external Hats Protocol. The app +
# `UtilityRolesManagementV1` speak IHats end-to-end, so no app-logic change is needed —
# only the addresses below wired into the frontend build.
#
#   1. LuxRolesV1               -> rolesProtocol            (IHats-compatible hats tree)
#   2. LuxRolesAccount1ofNV1    -> rolesAccount1ofNMasterCopy (ERC-6551 account: wearer = signer)
#   3. ERC-6551 registry        -> only if the canonical singleton 0x0000…5758 is ABSENT on this
#                                  chain (it is absent on Lux mainnet 96369 as of this writing),
#                                  in which case a compatible registry is deployed and MUST be
#                                  wired via VITE_APP_LUX_ERC6551_REGISTRY.
#
# STAGE ONLY. Plans by default; set EXECUTE=yes to broadcast. Refuses mainnet 96369 unless
# ALLOW_MAINNET=1 (mainnet is owner-gated — do not use without explicit owner approval).
#
# Usage:
#   bash deploy_lux_roles.sh <rpc> [k8s_namespace=lux-mainnet]
#   EXECUTE=yes bash deploy_lux_roles.sh <staging_rpc> lux-testnet
# ============================================================================
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

RPC="${1:?usage: deploy_lux_roles.sh <rpc> [namespace]}"
NS="${2:-lux-mainnet}"
EXECUTE="${EXECUTE:-no}"
ALLOW_MAINNET="${ALLOW_MAINNET:-0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT_DIR="$ROOT/out"
OUT_JSON="$ROOT/deployments/lux-dao/96369-roles.json"
CANONICAL_REGISTRY="0x000000006551c19487814612e58FE06813775758"

CID=$(cast chain-id --rpc-url "$RPC")
if [ "$CID" = "96369" ] && [ "$ALLOW_MAINNET" != "1" ]; then
  echo "REFUSE: chainId 96369 is Lux mainnet (owner-gated). Set ALLOW_MAINNET=1 to override."; exit 1
fi

echo ">>> Building roles contracts ..."
( cd "$ROOT" && forge build \
    contracts/dao/roles/LuxRolesV1.sol \
    contracts/dao/roles/LuxRolesAccount1ofNV1.sol \
    contracts/dao/roles/ERC6551Registry.sol >/dev/null )

# Check whether the canonical ERC-6551 registry exists on this chain.
REG_CODE=$(cast codesize "$CANONICAL_REGISTRY" --rpc-url "$RPC" 2>/dev/null || echo 0)

cat <<PLAN
================ LUX DAO ROLES PROTOCOL BRING-UP ================
rpc            : $RPC   (chainId=$CID)
namespace      : $NS
canonical 6551 : $CANONICAL_REGISTRY  (codesize=$REG_CODE $( [ "$REG_CODE" = "0" ] && echo '-> ABSENT, will deploy a compatible registry' || echo '-> present, will reuse'))

STEP 1  Deploy LuxRolesV1            -> rolesProtocol
STEP 2  Deploy LuxRolesAccount1ofNV1 -> rolesAccount1ofNMasterCopy
STEP 3  $( [ "$REG_CODE" = "0" ] && echo 'Deploy ERC6551Registry -> erc6551Registry (WIRE VITE_APP_LUX_ERC6551_REGISTRY)' || echo 'Reuse canonical ERC-6551 registry' )

Records addresses -> $OUT_JSON
================================================================
PLAN

if [ "$EXECUTE" != "yes" ]; then echo "[plan only — set EXECUTE=yes to broadcast]"; exit 0; fi

KEY=$(kubectl get secret lux-deployer -n "$NS" -o jsonpath='{.data.LUX_PRIVATE_KEY}' | base64 -d)
case "$KEY" in 0x*) ;; *) KEY="0x$KEY";; esac

deploy() { # $1 = ContractName (matches out/<Name>.sol/<Name>.json)
  local name="$1"
  local bc; bc=$(jq -r '.bytecode.object // .bytecode' "$OUT_DIR/$name.sol/$name.json")
  local addr; addr=$(cast send --rpc-url "$RPC" --private-key "$KEY" --json --create "$bc" | jq -r '.contractAddress')
  [ -n "$addr" ] && [ "$addr" != "null" ] || { echo "FAIL: $name deploy" >&2; exit 1; }
  echo "$addr"
}

echo ">>> STEP 1: LuxRolesV1 ..."
ROLES_PROTOCOL=$(deploy LuxRolesV1)
echo "rolesProtocol -> $ROLES_PROTOCOL"

echo ">>> STEP 2: LuxRolesAccount1ofNV1 ..."
ROLES_ACCOUNT=$(deploy LuxRolesAccount1ofNV1)
echo "rolesAccount1ofNMasterCopy -> $ROLES_ACCOUNT"

if [ "$REG_CODE" = "0" ]; then
  echo ">>> STEP 3: ERC6551Registry (canonical singleton absent) ..."
  ERC6551_REGISTRY=$(deploy ERC6551Registry)
  REGISTRY_OVERRIDE=1
  echo "erc6551Registry -> $ERC6551_REGISTRY  (WIRE VITE_APP_LUX_ERC6551_REGISTRY)"
else
  ERC6551_REGISTRY="$CANONICAL_REGISTRY"
  REGISTRY_OVERRIDE=0
fi

mkdir -p "$(dirname "$OUT_JSON")"
cat > "$OUT_JSON" <<JSON
{"chainId":$CID,"rolesProtocol":"$ROLES_PROTOCOL","rolesAccount1ofNMasterCopy":"$ROLES_ACCOUNT","erc6551Registry":"$ERC6551_REGISTRY","erc6551RegistryOverride":$([ "$REGISTRY_OVERRIDE" = "1" ] && echo true || echo false)}
JSON
echo "=== DONE. Addresses -> $OUT_JSON ==="
cat "$OUT_JSON"; echo
echo "NEXT (frontend): rebuild the lux.vote/zoo.vote/pars.vote bundle with:"
echo "  VITE_APP_LUX_ROLES_PROTOCOL=$ROLES_PROTOCOL"
echo "  VITE_APP_LUX_ROLES_ACCOUNT_1OFN=$ROLES_ACCOUNT"
[ "$REGISTRY_OVERRIDE" = "1" ] && echo "  VITE_APP_LUX_ERC6551_REGISTRY=$ERC6551_REGISTRY   # canonical 0x…5758 absent on this chain"
echo "  NOTE: termed (elected) roles additionally need rolesElectionsEligibilityMasterCopy +"
echo "        hatsModuleFactory; untermed roles + sub-wallets work with the above alone."
KEY=""
