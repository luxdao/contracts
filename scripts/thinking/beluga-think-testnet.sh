#!/usr/bin/env bash
# beluga-think-testnet.sh — make the ALREADY-DEPLOYED Beluga thinking stack think
# on a REAL remote chain (default: the live Lux testnet, chainId 96368).
#
# Unlike beluga-think-local.sh (anvil + deploy + cheatcode time travel), this
# attaches to an existing on-chain deployment and runs a governance round in REAL
# time. ThinkingGovernor enforces MIN_VOTING_WINDOW = 1h (anti-flash-governance),
# so the round is split into two phases that fit the hourly cadence:
#
#   open   : fund + register thinking-validators -> open a Thought -> each operator
#            decides with its LLM (decide.sh, the same cognition seam) -> signs +
#            submits a verdict on-chain. Records taskId + deadline to a state file.
#   settle : once the 1h window has elapsed -> settle -> record PoT + reputation ->
#            read it all back on-chain.
#
#   ./beluga-think-testnet.sh open      # phase 1 (default)
#   ./beluga-think-testnet.sh settle    # phase 2 (after the deadline)
#   ./beluga-think-testnet.sh auto      # open, wait out the window, settle (blocks ~1h)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.foundry/bin:$PATH" FOUNDRY_DISABLE_NIGHTLY_WARNING=1
MODE="${1:-open}"

# ---- config (live testnet 96368 defaults; all overridable via env) -----------
RPC="${THINK_RPC:-https://api.lux-test.network/ext/bc/C/rpc}"
GOV="${THINK_GOV:-0xa24318F24739d92a2e1c2997C18F5103d0fD708e}"
BRIDGE="${THINK_BRIDGE:-0x905b1907d4b8262B220A7aF7ad0a375F3A2F05cb}"
REP="${THINK_REP:-0x7803f099cdA82732e98C9f82815e7Acf18CA02C8}"
OBS="${THINK_OBS:-0xa1a2cE4377fee42b09Da6376d4887156FeE54c8b}"
PARAMS_ADDR="${THINK_PARAMS:-0xDd30113b484671A35Ca236ec5A97C1c5327d72FA}"
MN="${THINK_MNEMONIC:-$(cat /tmp/.luxmn 2>/dev/null)}"
WINDOW="${THINK_WINDOW:-604800}"        # 1 WEEK — real governance cadence: a "read + vote" task even a CPU-only
#                                         validator can answer in time (no GPU gate). THINK_WINDOW=3700 for a fast demo.
QUESTION="${THINK_QUESTION:-Beluga L3: require a 4-of-5 validator quorum (instead of 3-of-5) for high-value AI-task settlement, to better protect conservation funds?}"
KNOB="${THINK_KNOB:-aivm.quorum.threshold}"
STATE="${THINK_STATE:-$HERE/.testnet-round.json}"
[ -n "$MN" ] || { echo "no mnemonic (set THINK_MNEMONIC or /tmp/.luxmn)"; exit 1; }

say(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
pk(){ cast wallet private-key --mnemonic "$MN" --mnemonic-index "$1" 2>/dev/null; }
ad(){ cast wallet address --mnemonic "$MN" --mnemonic-index "$1" 2>/dev/null; }
K0="$(pk 0)"; A0="$(ad 0)"               # funder = the deployer (also the treasury)
OPENER_K="$(pk 6)"; OPENER_A="$(ad 6)"   # opener MUST NOT be the treasury or a voter
OPIDX=(1 2 3 4 5)                        # 5 thinking-validators (mnemonic-derived)
SPEC=$(cast keccak "zen/thinking-governor/model-spec/v1")

show(){ command -v node >/dev/null 2>&1 && node "$HERE/observe.mjs" --rpc "$RPC" --observatory "$OBS" --parameters "$PARAMS_ADDR" --reputation "$REP" 2>/dev/null || true; }

do_settle(){
  local TID="$1"
  say "settling thought #$TID on chainId $(cast chain-id --rpc-url "$RPC")"
  # On an idle chain the latest block.timestamp lags wall-clock, so eth_estimateGas
  # (which runs against that stale block) reverts SettleTooEarly even though the tx
  # would land in a fresh, post-deadline block. Bypass estimation with --gas-limit.
  local GL="${THINK_GAS_LIMIT:-6000000}"
  if cast send "$GOV" "settle(uint256)" "$TID" --gas-limit "$GL" --private-key "$K0" --rpc-url "$RPC" >/dev/null 2>&1; then
    echo "  settled."
  else
    echo "  settle skipped (already settled) — showing current on-chain state"
  fi
  cast send "$BRIDGE" "recordThought(uint256)" "$TID" --gas-limit "$GL" --private-key "$K0" --rpc-url "$RPC" >/dev/null 2>&1 \
    && echo "  PoT receipt recorded for thought #$TID" || echo "  no quorum -> no PoT receipt (safety: no quorum, no action)"
  cast send "$REP" "recordSettled(uint256)" "$TID" --gas-limit "$GL" --private-key "$K0" --rpc-url "$RPC" >/dev/null 2>&1 \
    && echo "  reputation updated" || echo "  reputation update skipped"
  say "ON-CHAIN RESULT (read back via observe.mjs — defaults point here)"
  show
  say "DONE — Beluga thought on the LIVE testnet; the decision persists on-chain."
}

# ---- settle phase ------------------------------------------------------------
if [ "$MODE" = "settle" ]; then
  TID="${THINK_SETTLE_TID:-$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["taskId"])' "$STATE" 2>/dev/null || echo '')}"
  [ -n "$TID" ] || { echo "no taskId (run 'open' first, or set THINK_SETTLE_TID)"; exit 1; }
  DL=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["deadline"])' "$STATE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ "${DL:-0}" -gt 0 ] 2>/dev/null && [ "$now" -lt "$DL" ]; then
    say "voting window still open — $((DL-now))s remain before settle is allowed (taskId=$TID)"
    show; exit 0
  fi
  do_settle "$TID"; exit 0
fi

# ---- open phase (fund + register + open + verdicts) --------------------------
say "attaching to live deployment on chainId $(cast chain-id --rpc-url "$RPC")"
echo "  rpc=$RPC  governor=$GOV  opener=$A0  thoughts so far: $(cast call "$GOV" 'taskCount()(uint256)' --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')"

say "funding + registering 5 thinking-validators (1 bond each; idempotent)"
for i in "${OPIDX[@]}"; do
  OPK="$(pk "$i")"; OPA="$(ad "$i")"
  bal=$(cast balance "$OPA" --rpc-url "$RPC" 2>/dev/null || echo 0)
  if [ "$(cast to-unit "${bal:-0}" ether 2>/dev/null | cut -d. -f1)" -lt 2 ] 2>/dev/null; then
    cast send "$OPA" --value 2ether --private-key "$K0" --rpc-url "$RPC" >/dev/null; fi
  if [ "$(cast call "$GOV" 'isOperator(address)(bool)' "$OPA" --rpc-url "$RPC" 2>/dev/null)" = "true" ]; then
    echo "  operator $i already bonded: $OPA"
  else
    cast send "$GOV" "registerOperator()" --value 1ether --private-key "$OPK" --rpc-url "$RPC" >/dev/null
    echo "  operator $i bonded: $OPA"; fi
done

say "opening governance Thought (window ${WINDOW}s ~ 1h MIN_VOTING_WINDOW)"
echo "  Q: $QUESTION"
# fund the dedicated opener (non-treasury, non-voter) for the open fee + gas
obal=$(cast balance "$OPENER_A" --rpc-url "$RPC" 2>/dev/null || echo 0)
if [ "$(cast to-unit "${obal:-0}" ether 2>/dev/null | cut -d. -f1)" -lt 1 ] 2>/dev/null; then
  cast send "$OPENER_A" --value 1ether --private-key "$K0" --rpc-url "$RPC" >/dev/null; fi
echo "  opener=$OPENER_A (separate from treasury $A0)"
QH=$(cast keccak "$QUESTION"); EH=$(cast keccak "beluga-l3-conservation-evidence-live")
TID=$(cast call "$GOV" 'taskCount()(uint256)' --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
# open payment = openFee + per-validator reward pool; for n=5 the contract wants 0.6 (proven in beluga-think-local.sh)
cast send "$GOV" "openThought(bytes32,bytes32,bytes32,uint8,uint8,uint64,string)" \
  "$SPEC" "$QH" "$EH" 5 3 "$WINDOW" "$KNOB" --value 0.6ether --private-key "$OPENER_K" --rpc-url "$RPC" >/dev/null
DEADLINE=$(( $(date +%s) + WINDOW ))
echo "  taskId=$TID  knob='$KNOB'  n=5 threshold=3 window=${WINDOW}s"

say "thinking validators decide (LLM) + submit signed verdicts on-chain"
for i in "${OPIDX[@]}"; do
  OPK="$(pk "$i")"; OPA="$(ad "$i")"
  read -r VOTE BUCKET < <(bash "$HERE/decide.sh" "$i" "$QUESTION" 2>/tmp/decide-t-$i.log; )
  grep -m1 'verdict from\|stand-in' /tmp/decide-t-$i.log >&2 || true
  EV=$(cast keccak "validator-$i-rationale")
  DIG=$(cast call "$GOV" "verdictDigest(uint256,address,bytes32,uint8,uint16,bytes32)(bytes32)" "$TID" "$OPA" "$SPEC" "$VOTE" "$BUCKET" "$EV" --rpc-url "$RPC")
  SIG=$(cast wallet sign --no-hash "$DIG" --private-key "$OPK")
  cast send "$GOV" "submitVerdict(uint256,uint8,uint16,bytes32,bytes)" "$TID" "$VOTE" "$BUCKET" "$EV" "$SIG" --private-key "$OPK" --rpc-url "$RPC" >/dev/null
  vn=YES; [ "$VOTE" = 2 ] && vn=NO; [ "$VOTE" = 3 ] && vn=ABSTAIN
  echo "  validator $i -> $vn @ $((BUCKET/100))% confidence  (on-chain)"
done
python3 -c "import json,sys;json.dump({'taskId':int(sys.argv[1]),'deadline':int(sys.argv[2]),'knob':sys.argv[3]},open(sys.argv[4],'w'))" "$TID" "$DEADLINE" "$KNOB" "$STATE"
echo "  state -> $STATE  (taskId=$TID, deadline=$DEADLINE)"

if [ "$MODE" = "auto" ]; then
  say "waiting out the voting window (real time, ~1h)…"
  rem=$(( DEADLINE - $(date +%s) + 10 )); [ "$rem" -gt 0 ] && python3 -c "import time;time.sleep($rem)" || true
  do_settle "$TID"
else
  say "OPEN phase complete — 5 verdicts submitted on-chain"
  echo "  settle after the 1h window with:  ./beluga-think-testnet.sh settle   (taskId=$TID)"
  show
fi
