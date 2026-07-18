#!/usr/bin/env bash
# deploy-mining.sh — deploy the AI-mining stack to an EVM and PROVE it live with a real
# on-chain mint. Uses forge create + cast (NO forge-script forking) so it works on chains
# that reject fork queries ("cannot query unfinalized data") or run a heavy gas schedule.
# Network-agnostic: same bytecode + same pure-Solidity attestation verification on any EVM.
#
#   ./deploy-mining.sh <label> <rpc> [gas_limit]
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH" FOUNDRY_DISABLE_NIGHTLY_WARNING=1
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
LABEL="${1:?label}"; RPC="${2:?rpc}"; GL="${3:-9000000}"
# Some EVMs (e.g. zoo) predate Shanghai and reject PUSH0 (0x5F) that solc 0.8.30 emits by
# default -> invalid-opcode revert consuming all gas. Pass EVM_VERSION=paris for those.
EVMV="${EVM_VERSION:-}"; EVMFLAG=""; [ -n "$EVMV" ] && EVMFLAG="--evm-version $EVMV"
OUT="${MINING_OUT:-$HERE/deployments-mining.json}"
MN="${THINK_MNEMONIC:-$(cat /tmp/.luxmn 2>/dev/null)}"; [ -n "$MN" ] || { echo "no mnemonic"; exit 1; }
K0="$(cast wallet private-key --mnemonic "$MN" --mnemonic-index 0 2>/dev/null)"
DEP="$(cast wallet address --mnemonic "$MN" --mnemonic-index 0 2>/dev/null)"
GENESIS="${AICOIN_GENESIS:-1781000000}"      # unified fair-launch epoch, before all target clocks
REWARD="${AICOIN_REWARD:-1000000000000000000000}" # 1000 AI / receipt
T="contracts/deployables/thinking"
say(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
CID=$(cast chain-id --rpc-url "$RPC" 2>/dev/null || echo '?')
say "[$LABEL] chainId=$CID gasLimit=$GL deployer=$DEP"

cd "$ROOT"
forge build "$T/AICoin.sol" "$T/AIReceiptRoots.sol" "$T/AICoinMiner.sol" >/dev/null 2>&1 || { echo "build failed"; exit 1; }
# forge create with explicit --gas-limit (no fork sim); returns deployedTo
dep(){ forge create "$1" --rpc-url "$RPC" --private-key "$K0" --broadcast --gas-limit "$GL" $EVMFLAG ${2:+--constructor-args $2} 2>/dev/null \
        | grep -oE 'Deployed to: 0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}'; }
snd(){ cast send "$@" --gas-limit "$GL" --private-key "$K0" --rpc-url "$RPC" >/dev/null; }

say "[$LABEL] deploy AICoin / AIReceiptRoots / AICoinMiner"
AICOIN=$(dep "$T/AICoin.sol:AICoin" "AICoin AI $DEP 0x0000000000000000000000000000000000000000 $GENESIS")
ROOTS=$(dep "$T/AIReceiptRoots.sol:AIReceiptRoots" "$DEP")
MINER=$(dep "$T/AICoinMiner.sol:AICoinMiner" "$AICOIN $ROOTS $DEP $REWARD")
echo "  AICoin=$AICOIN  Roots=$ROOTS  Miner=$MINER"
[ -n "$AICOIN" ] && [ -n "$ROOTS" ] && [ -n "$MINER" ] || { echo "  deploy returned empty — aborting"; exit 1; }

say "[$LABEL] wire setMinter + setRelayer"
snd "$AICOIN" "setMinter(address,bool)" "$MINER" true
snd "$ROOTS" "setRelayer(address,bool)" "$DEP" true

say "[$LABEL] build wire-correct receipt + leaf (cast keccak) + mine"
DOMHEX=$(python3 -c 'print(b"lux/aivmbridge/receipt/v1".hex())')
# 355-byte canonical receipt (pure byte concat; requester = deployer, unique per label)
RHEX=$(python3 - "$DEP" "$LABEL" <<'PY'
import sys,hashlib
dep=bytes.fromhex(sys.argv[1][2:]); lab=sys.argv[2].encode()
# unique but deterministic intentID/output via sha256 (only needs to be nonzero+unique)
intent=hashlib.sha256(b"intent/"+lab).digest(); out=hashlib.sha256(b"output/"+lab).digest()
r =(1).to_bytes(2,'big')+intent+b"\x00"*32+b"\x00"*32+b"\x00"*32+dep
r+=b"\x00"*32+b"\x00"*32+out+(2).to_bytes(1,'big')+(5).to_bytes(2,'big')+(3).to_bytes(2,'big')
r+=b"\x00"*32+b"\x00"*32+b"\x00"*32+(12345).to_bytes(8,'big')
assert len(r)==355,len(r); print(r.hex())
PY
)
RECEIPT="0x$RHEX"
INNER=$(cast keccak "0x${DOMHEX}${RHEX}")
LEAF=$(cast keccak "$INNER")
PROOF="0x${LEAF#0x}$(printf '%016x' 0)$(printf '%04x' 0)"   # root=leaf | u64 index 0 | u16 pathLen 0
echo "  leaf/root=$LEAF"
snd "$ROOTS" "anchorRoot(bytes32,uint64)" "$LEAF" 12345
snd "$MINER" "mine(bytes,bytes)" "$RECEIPT" "$PROOF"

say "[$LABEL] VERIFY on-chain"
SUP=$(cast call "$AICOIN" "totalSupply()(uint256)" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
BAL=$(cast call "$AICOIN" "balanceOf(address)(uint256)" "$DEP" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
ST="FAIL"; [ "${SUP:-0}" != "0" ] && ST="LIVE"
printf '  totalSupply=%s AI  balance=%s AI  => %s\n' "$(python3 -c "print(${SUP:-0}/10**18)" 2>/dev/null)" "$(python3 -c "print(${BAL:-0}/10**18)" 2>/dev/null)" "$ST"
python3 - "$OUT" "$LABEL" "$CID" "$RPC" "$AICOIN" "$ROOTS" "$MINER" "$SUP" "$ST" <<'PY'
import json,sys,os
out=sys.argv[1]
d=json.load(open(out)) if os.path.exists(out) else {}
d[sys.argv[2]]={"chainId":sys.argv[3],"rpc":sys.argv[4],"aicoin":sys.argv[5],"receiptRoots":sys.argv[6],"miner":sys.argv[7],"totalSupplyWei":sys.argv[8],"status":sys.argv[9]}
json.dump(d,open(out,'w'),indent=2); print("  recorded",sys.argv[2],sys.argv[9])
PY
