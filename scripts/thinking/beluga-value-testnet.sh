#!/usr/bin/env bash
# beluga-value-testnet.sh — run a VALUE-DECIDING governance round on the live
# Lux testnet (chainId 96368), the companion to beluga-think-testnet.sh.
#
# Where beluga-think-testnet.sh runs a BINARY (YES/NO) ThinkingGovernor vote, this
# runs a ThinkingParameters round: the thinking-validators' LLMs each PROPOSE a
# NUMBER for a governed knob, and the chain settles the MEDIAN of the sortition-
# sampled committee — the parameter is decided BY the models, not ratified. This is
# the "knobs/params based on the LLM of the node operator" half of the design.
#
# ThinkingParameters enforces MIN_WINDOW = 1h, so (like the binary round) it splits
# into phases that fit the hourly cadence:
#   open   : open a round -> each operator decides a value (decide-value.sh) ->
#            signs + submitProposal on-chain (sortition-gated). State -> file.
#   settle : after the 1h window -> settle -> read valueOf + observe.
#
#   ./beluga-value-testnet.sh open      # phase 1 (default)
#   ./beluga-value-testnet.sh settle    # phase 2 (after the deadline)
#   ./beluga-value-testnet.sh auto      # open, wait out the window, settle (~1h)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.foundry/bin:$PATH" FOUNDRY_DISABLE_NIGHTLY_WARNING=1
MODE="${1:-open}"

# ---- config (live testnet 96368 defaults; all overridable via env) -----------
RPC="${THINK_RPC:-https://api.lux-test.network/ext/bc/C/rpc}"
GOV="${THINK_GOV:-0xa24318F24739d92a2e1c2997C18F5103d0fD708e}"
PARAMS="${THINK_PARAMS:-0xDd30113b484671A35Ca236ec5A97C1c5327d72FA}"
REP="${THINK_REP:-0x7803f099cdA82732e98C9f82815e7Acf18CA02C8}"
OBS="${THINK_OBS:-0xa1a2cE4377fee42b09Da6376d4887156FeE54c8b}"
MN="${THINK_MNEMONIC:-$(cat /tmp/.luxmn 2>/dev/null)}"
WINDOW="${THINK_WINDOW:-604800}"                     # 1 WEEK — real cadence so CPU-only validators can propose in
#                                                      time (median is a "read + answer a number" task). THINK_WINDOW=3700 for a fast demo.
GL="${THINK_GAS_LIMIT:-6000000}"                     # bypass idle-chain stale-block estimation
KNOB="${THINK_KNOB:-beluga.conservation.tithe.bps}"
PLO="${THINK_LO:-0}"; PHI="${THINK_HI:-2000}"
PQ="${THINK_QUESTION:-Propose the conservation tithe in basis points routed from every settled AI-task fee to ocean and beluga-whale conservation, balancing the mission against fee competitiveness.}"
STATE="${THINK_STATE:-$HERE/.value-round.json}"
[ -n "$MN" ] || { echo "no mnemonic (set THINK_MNEMONIC or /tmp/.luxmn)"; exit 1; }

say(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
pk(){ cast wallet private-key --mnemonic "$MN" --mnemonic-index "$1" 2>/dev/null; }
ad(){ cast wallet address --mnemonic "$MN" --mnemonic-index "$1" 2>/dev/null; }
K0="$(pk 0)"                                         # opener/funder = deployer (not a proposer)
OPIDX=(1 2 3 4 5)                                    # 5 thinking-validators (also bond the governor)
SPEC=$(cast keccak "zen/thinking-governor/model-spec/v1")
show(){ command -v node >/dev/null 2>&1 && node "$HERE/observe.mjs" --rpc "$RPC" --observatory "$OBS" --parameters "$PARAMS" --reputation "$REP" 2>/dev/null || true; }

do_settle(){
  local RID="$1"
  say "settling value round #$RID on chainId $(cast chain-id --rpc-url "$RPC")"
  if cast send "$PARAMS" "settle(uint256)" "$RID" --gas-limit "$GL" --private-key "$K0" --rpc-url "$RPC" >/dev/null 2>&1; then
    echo "  settled."
  else
    echo "  settle skipped (already settled or no quorum) — showing current state"
  fi
  local VOUT; VOUT=$(cast call "$PARAMS" "valueOf(bytes32,string)(uint256,bool)" "$SPEC" "$KNOB" --rpc-url "$RPC" 2>/dev/null || true)
  echo "  valueOf($KNOB) -> $(printf '%s' "$VOUT" | tr '\n' ' ')"
  say "ON-CHAIN RESULT (read back via observe.mjs)"
  show
  say "DONE — Beluga decided a knob VALUE by validator-LLM median on the LIVE testnet."
}

# ---- settle phase ------------------------------------------------------------
if [ "$MODE" = "settle" ]; then
  RID="${THINK_SETTLE_RID:-$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["roundId"])' "$STATE" 2>/dev/null || echo '')}"
  [ -n "$RID" ] || { echo "no roundId (run 'open' first, or set THINK_SETTLE_RID)"; exit 1; }
  DL=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["deadline"])' "$STATE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ "${DL:-0}" -gt 0 ] 2>/dev/null && [ "$now" -lt "$DL" ]; then
    say "voting window still open — $((DL-now))s remain before settle is allowed (round #$RID)"; show; exit 0
  fi
  do_settle "$RID"; exit 0
fi

# ---- open phase --------------------------------------------------------------
say "attaching to live ThinkingParameters on chainId $(cast chain-id --rpc-url "$RPC")"
echo "  rpc=$RPC  parameters=$PARAMS  rounds so far: $(cast call "$PARAMS" 'roundCount()(uint256)' --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')"
echo "  knob='$KNOB'  range [$PLO, $PHI]"

# Operators must be bonded BEFORE the round opens (sortition population + eligibility).
say "verifying 5 thinking-validators are bonded (sortition population)"
for i in "${OPIDX[@]}"; do
  OPA="$(ad "$i")"
  if [ "$(cast call "$GOV" 'isOperator(address)(bool)' "$OPA" --rpc-url "$RPC" 2>/dev/null)" = "true" ]; then
    echo "  operator $i bonded: $OPA"
  else
    echo "  operator $i NOT bonded — run beluga-think-testnet.sh open first"; exit 1
  fi
done

say "opening value round (window ${WINDOW}s ~ 1h MIN_WINDOW; n=5 threshold=3)"
echo "  Q: $PQ"
PPH=$(cast keccak "$PQ")
RID=$(cast call "$PARAMS" 'roundCount()(uint256)' --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
cast send "$PARAMS" "open(bytes32,bytes32,string,uint256,uint256,uint8,uint8,uint64)" \
  "$SPEC" "$PPH" "$KNOB" "$PLO" "$PHI" 5 3 "$WINDOW" --gas-limit "$GL" --private-key "$K0" --rpc-url "$RPC" >/dev/null
DEADLINE=$(( $(date +%s) + WINDOW ))
echo "  roundId=$RID  opened at block $(cast block-number --rpc-url "$RPC" 2>/dev/null)"

# A block must pass between open and the first proposal (seed = blockhash(openBlock)).
# Each cast send mines a block on this idle chain, so submitting with --gas-limit
# (which skips estimation against the stale open block) lands each proposal in a
# fresh block > openBlock and computes the sortition seed correctly.
say "thinking validators PROPOSE a value (LLM) + submit signed proposals on-chain"
for i in "${OPIDX[@]}"; do
  OPK="$(pk "$i")"; OPA="$(ad "$i")"
  read -r VAL VBUCKET < <(bash "$HERE/decide-value.sh" "$i" "$PQ" "$PLO" "$PHI" 2>/tmp/decval-t-$i.log; )
  grep -m1 'value from\|stand-in' /tmp/decval-t-$i.log >&2 || true
  PEV=$(cast keccak "tithe-rationale-$i")
  PDIG=$(cast call "$PARAMS" "proposalDigest(uint256,address,bytes32,uint256,uint16,bytes32)(bytes32)" "$RID" "$OPA" "$SPEC" "$VAL" "$VBUCKET" "$PEV" --rpc-url "$RPC")
  PSIG=$(cast wallet sign --no-hash "$PDIG" --private-key "$OPK")
  if cast send "$PARAMS" "submitProposal(uint256,uint256,uint16,bytes32,bytes)" "$RID" "$VAL" "$VBUCKET" "$PEV" "$PSIG" --gas-limit "$GL" --private-key "$OPK" --rpc-url "$RPC" >/dev/null 2>&1; then
    echo "  validator $i -> proposes $VAL bps @ $((VBUCKET/100))% confidence  (on-chain)"
  else
    echo "  validator $i -> proposal rejected (sortition: not sampled, or duplicate)"
  fi
done
python3 -c "import json,sys;json.dump({'roundId':int(sys.argv[1]),'deadline':int(sys.argv[2]),'knob':sys.argv[3]},open(sys.argv[4],'w'))" "$RID" "$DEADLINE" "$KNOB" "$STATE"
echo "  state -> $STATE  (roundId=$RID, deadline=$DEADLINE)"

if [ "$MODE" = "auto" ]; then
  say "waiting out the window (~1h)…"
  rem=$(( DEADLINE - $(date +%s) + 10 )); [ "$rem" -gt 0 ] && python3 -c "import time;time.sleep($rem)" || true
  do_settle "$RID"
else
  say "OPEN phase complete — proposals submitted on-chain for round #$RID"
  echo "  settle after the 1h window with:  ./beluga-value-testnet.sh settle"
  show
fi
