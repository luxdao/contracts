#!/usr/bin/env bash
# decide-value.sh — the node operator's "brain" for one Beluga L3 PARAMETER round.
#
# Where decide.sh turns a question into a YES/NO verdict, this turns it into a
# NUMBER: the operator's LLM proposes a value within [lo, hi] for a governed knob.
# The chain settles a round to the MEDIAN of the quorum's proposals
# (ThinkingParameters), so the parameter is decided BY the models, not ratified.
#
#   Usage:  decide-value.sh <validatorId> "<question>" <lo> <hi>
#   Output (last line):  "<value> <bucket>"   value: integer in [lo,hi]
#                                              bucket: confidence in bps (mult. of 1000)
#
# Two paths, ONE interface (orthogonal): native hanzo-engine, else a labelled,
# reproducible policy stand-in (NEVER presented as model output).
set -euo pipefail

vid="${1:?validatorId}"; question="${2:?question}"; lo="${3:?lo}"; hi="${4:?hi}"

snap() { local c="$1"; ((c<0))&&c=0; ((c>100))&&c=100; echo $(( ((c+10)/20) * 2000 )); }
clamp() { local x="$1"; ((x<lo))&&x=$lo; ((x>hi))&&x=$hi; echo "$x"; }

ENGINE_URL="${ZEN_LLM_URL:-http://127.0.0.1:36900/v1/chat/completions}"
ENGINE_MODEL="${ZEN_LLM_MODEL:-Qwen/Qwen3-0.6B}"
prompt="You are thinking-validator #${vid} for the Beluga L3 conservation blockchain. \
Decide a governance parameter. ${question} \
The value MUST be an integer between ${lo} and ${hi}. \
Reply with EXACTLY one line, no preamble: VALUE=<integer ${lo}-${hi}> CONFIDENCE=<integer 0-100> /no_think"
body=$(python3 -c 'import json,sys;print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":sys.argv[2]}],"max_tokens":24,"temperature":0.4}))' "$ENGINE_MODEL" "$prompt")
resp=$(curl -s --max-time "${ZEN_LLM_TIMEOUT:-300}" "$ENGINE_URL" -H 'Content-Type: application/json' -d "$body" 2>/dev/null \
      | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("choices",[{}])[0].get("message",{}).get("content","") or d.get("response",""))' 2>/dev/null || true)
if [ -n "$resp" ]; then
  up=$(printf '%s' "$resp" | tr 'a-z' 'A-Z')
  val=$(printf '%s' "$up" | grep -oE 'VALUE[=: ]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  [ -z "$val" ] && val=$(printf '%s' "$up" | grep -oE '[0-9]+' | head -1 || echo $(( (lo+hi)/2 )))
  conf=$(printf '%s' "$up" | grep -oE 'CONFIDENCE[=: ]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  [ -z "$conf" ] && conf=70
  echo "operator#${vid}: hanzo-engine value from ${ENGINE_URL} -> '${resp}'" >&2
  echo "$(clamp "$val") $(snap "$conf")"; exit 0
fi

# Deterministic conservation policy (LLM runtime unavailable): validators cluster
# near a sensible tithe with honest spread; two sit at the extremes so the demo
# exercises the median's Byzantine-robustness. Labelled; NOT model output.
echo "operator#${vid}: [policy stand-in — hanzo-engine not reachable; start it: hanzo-server --port 36900 run -m Qwen/Qwen3-0.6B]" >&2
mid=$(( (lo+hi)/2 ))
case "$vid" in
  1) echo "$(clamp $lo) 6000" ;;          # adversary/low outlier
  2) echo "$(clamp $((mid-100))) 8000" ;; # honest
  3) echo "$(clamp $mid) 9000" ;;         # honest center -> the median
  4) echo "$(clamp $((mid+100))) 8000" ;; # honest
  *) echo "$(clamp $hi) 6000" ;;          # adversary/high outlier
esac
