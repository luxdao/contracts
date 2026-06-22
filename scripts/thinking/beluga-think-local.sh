#!/usr/bin/env bash
# beluga-think-local.sh — make Beluga L3 think locally, on a real chain.
#
# Stands up a local EVM (anvil), deploys the Thinking Chains governance stack,
# then runs ONE full round of governance-by-thinking-validators:
#
#   open a governance Thought  →  each of 5 node operators decides it with its
#   LLM (decide.sh)  →  signs a structured verdict  →  submits on-chain  →
#   quorum settles the canonical decision  →  a knob is set  →  the decision is
#   recorded as a Proof-of-Thought receipt  →  the whole thing is read back from
#   the chain via the ThinkingChainObservatory (the lux/dao visibility surface).
#
# Everything is on-chain and persists on the running anvil so the DAO dashboard
# can query it after the run. Operator cognition is pluggable: set ZEN_LLM_URL to
# a local model endpoint for real verdicts (see decide.sh); otherwise a labelled
# deterministic conservation policy is used so the mechanism still runs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONTRACTS="$(cd "$HERE/../.." && pwd)"
export PATH="$HOME/.foundry/bin:$PATH" FOUNDRY_DISABLE_NIGHTLY_WARNING=1
RPC="http://127.0.0.1:8545"
T="contracts/deployables/thinking"

# ---- anvil deterministic accounts (mnemonic "test test ... junk") -------------
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80          # opener
A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
OPS=(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d         # operator 1
     0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a         # operator 2
     0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6         # operator 3
     0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a         # operator 4
     0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba)        # operator 5
TREASURY=0xa0Ee7A142d267C1f36714E4a8F75612F20a79720                            # acct 9

# A real Beluga L3 governance question put to the thinking-validators. With a
# skeptical small model the canonical answer is often NO/abstain — that is REAL
# cognition, not rigged; the contract records whatever quorum (if any) forms, and
# only a YES quorum mutates the knob (proven in the ThinkingGovernor headline
# test). Set ZEN_LLM_URL to use real model verdicts; otherwise decide.sh uses a
# labelled deterministic policy.
QUESTION="Beluga L3: require a 4-of-5 validator quorum (instead of 3-of-5) for high-value AI-task settlement, to better protect conservation funds?"
KNOB="aivm.quorum.threshold"

say(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
SPEC=$(cast keccak "zen/thinking-governor/model-spec/v1")

# ---- bring up anvil ----------------------------------------------------------
say "starting anvil"
anvil --silent >/tmp/anvil-beluga.log 2>&1 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
for i in $(seq 1 30); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.3; done
echo "anvil up (pid $ANVIL_PID), chainId $(cast chain-id --rpc-url $RPC)"

cd "$CONTRACTS"
forge build >/dev/null 2>&1 || { echo "forge build failed"; exit 1; }
dep(){ forge create "$1" --rpc-url "$RPC" --private-key "$K0" --broadcast --json ${2:+--constructor-args $2} 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["deployedTo"])'; }

# ---- deploy the stack --------------------------------------------------------
say "deploying Thinking Chains governance stack"
REG=$(dep "$T/ProofOfThoughtRegistry.sol:ProofOfThoughtRegistry")
GOV=$(dep "$T/ThinkingGovernor.sol:ThinkingGovernor" "1000000000000000000 0 500000000000000000 100000000000000000 $TREASURY 0x0000000000000000000000000000000000000000")
OBS=$(dep "$T/ThinkingChainObservatory.sol:ThinkingChainObservatory" "$GOV $REG")
BRIDGE=$(dep "$T/GovernancePoTBridge.sol:GovernancePoTBridge" "$GOV $REG")
echo "  registry=$REG"; echo "  governor=$GOV"; echo "  observatory=$OBS"; echo "  bridge=$BRIDGE"

# ---- register 5 thinking-validators (operators) ------------------------------
say "registering 5 thinking-validators (1 LUX bond each)"
for i in 0 1 2 3 4; do
  cast send "$GOV" "registerOperator()" --value 1ether --private-key "${OPS[$i]}" --rpc-url "$RPC" >/dev/null
  echo "  operator $((i+1)) bonded: $(cast wallet address --private-key ${OPS[$i]})"
done

# ---- open the governance Thought ---------------------------------------------
say "opening governance Thought"
echo "  Q: $QUESTION"
QH=$(cast keccak "$QUESTION"); EH=$(cast keccak "beluga-l3-conservation-evidence")
cast send "$GOV" "openThought(bytes32,bytes32,bytes32,uint8,uint8,uint64,string)" \
  "$SPEC" "$QH" "$EH" 5 3 3600 "$KNOB" \
  --value 0.6ether --private-key "$K0" --rpc-url "$RPC" >/dev/null
TID=0
echo "  taskId=$TID  knob='$KNOB'  n=5 threshold=3 window=3600s"

# ---- each operator THINKS, signs, and submits its verdict --------------------
say "thinking validators decide + submit signed verdicts"
for i in 0 1 2 3 4; do
  vid=$((i+1)); OPADDR=$(cast wallet address --private-key "${OPS[$i]}")
  read -r VOTE BUCKET < <(bash "$HERE/decide.sh" "$vid" "$QUESTION" 2>/tmp/decide-$vid.log; )
  cat /tmp/decide-$vid.log >&2 || true
  EV=$(cast keccak "validator-$vid-rationale")
  DIG=$(cast call "$GOV" "verdictDigest(uint256,address,bytes32,uint8,uint16,bytes32)(bytes32)" \
        "$TID" "$OPADDR" "$SPEC" "$VOTE" "$BUCKET" "$EV" --rpc-url "$RPC")
  SIG=$(cast wallet sign --no-hash "$DIG" --private-key "${OPS[$i]}")
  cast send "$GOV" "submitVerdict(uint256,uint8,uint16,bytes32,bytes)" \
    "$TID" "$VOTE" "$BUCKET" "$EV" "$SIG" --private-key "${OPS[$i]}" --rpc-url "$RPC" >/dev/null
  vn=YES; [ "$VOTE" = 2 ] && vn=NO; [ "$VOTE" = 3 ] && vn=ABSTAIN
  echo "  validator $vid -> $vn @ $((BUCKET/100))% confidence  (submitted)"
done

# ---- advance past the voting deadline, then settle ---------------------------
say "advancing chain past voting deadline + settling quorum"
cast rpc evm_increaseTime 4000 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
cast send "$GOV" "settle(uint256)" "$TID" --private-key "$K0" --rpc-url "$RPC" >/dev/null
echo "  settled."

# ---- record the decision as a Proof-of-Thought receipt -----------------------
say "recording governance decision as on-chain Proof-of-Thought"
if cast send "$BRIDGE" "recordThought(uint256)" "$TID" --private-key "$K0" --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "  recorded — the settled decision is now a queryable PoT receipt."
else
  echo "  skipped — thinking-validators did NOT reach a 3-of-5 quorum on any single"
  echo "  (vote, confidence) key, so the Thought settled FAILED: no canonical"
  echo "  decision, no knob change. The chain correctly refused to force action."
  echo "  (Safety property: no quorum -> no action.)"
fi

# ---- READ IT ALL BACK FROM THE CHAIN (the lux/dao visibility surface) --------
say "ON-CHAIN RESULT (read via ThinkingChainObservatory)"
TH=$(cast call "$GOV" "getThought(uint256)((bytes32,bytes32,bytes32,uint8,uint8,uint64,uint64,address,uint8,uint8,string,uint8,uint16,uint8,bytes32))" "$TID" --rpc-url "$RPC")
python3 - "$TH" <<'PY'
import sys,re
t=sys.argv[1].strip()
# forge prints a tuple like (0x..,0x..,...,"key",...). split top-level commas.
inner=t[1:-1] if t.startswith("(") else t
parts=[]; depth=0; cur=""
for ch in inner:
    if ch in "([": depth+=1
    if ch in ")]": depth-=1
    if ch=="," and depth==0: parts.append(cur.strip()); cur=""
    else: cur+=ch
parts.append(cur.strip())
n=lambda s:int(s.split()[0])           # cast annotates uints e.g. "10000 [1e4]"
bps=n(parts[12])
status={0:"None",1:"Open",2:"Settled",3:"Failed"}.get(n(parts[8]),parts[8])
vote={0:"Invalid",1:"YES",2:"NO",3:"Abstain"}.get(n(parts[11]),parts[11])
print(f"  status         : {status}")
print(f"  canonical vote : {vote}")
print(f"  confidence     : {bps//100}% ({bps} bps)")
print(f"  agree count    : {n(parts[13])} of {n(parts[3])} (threshold {n(parts[4])})")
print(f"  knob decided   : {parts[10].strip(chr(34))}")
PY
echo "  getKnob($KNOB) = $(cast call "$GOV" "getKnob(bytes32,string)(bytes32)" "$SPEC" "$KNOB" --rpc-url "$RPC")"

say "Observatory.overview()  (the DAO dashboard header)"
OV=$(cast call "$OBS" "overview()((uint256,uint256,uint256,uint256,uint256,uint256,uint256,address))" --rpc-url "$RPC")
python3 - "$OV" <<'PY'
import sys
p=[x.strip().split()[0] for x in sys.argv[1].strip()[1:-1].split(",")]
print(f"  thoughts opened : {p[0]}   open {p[1]} / settled {p[2]} / failed {p[3]}")
print(f"  PoT receipts    : {p[4]}   (paid/settled cognitions on the ledger)")
PY

say "DONE — Beluga L3 thought locally; the decision is on-chain and visible."
echo "governor=$GOV  observatory=$OBS"
DASH_PORT="${BELUGA_DASH_PORT:-8750}"
echo "visibility dashboard: scripts/thinking/observatory.html  (?rpc=$RPC&observatory=$OBS)"
if [ "${BELUGA_KEEP:-0}" = "1" ]; then
  ( cd "$HERE" && python3 -m http.server "$DASH_PORT" >/tmp/beluga-dash.log 2>&1 & )
  DASH_URL="http://127.0.0.1:${DASH_PORT}/observatory.html?rpc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$RPC")&observatory=$OBS"
  echo "anvil kept alive at $RPC (pid $ANVIL_PID); Thinking Chain Observatory dashboard:"
  echo "  $DASH_URL"
  echo "(ctrl-C to stop both)"
  trap 'kill $ANVIL_PID 2>/dev/null; pkill -f "http.server $DASH_PORT" 2>/dev/null' EXIT
  wait $ANVIL_PID
fi
