#!/usr/bin/env bash
# decide.sh — the node operator's "brain" for one Beluga L3 governance verdict.
#
# This is the LLM-of-the-node-operator seam. Each thinking validator runs THIS to
# turn a governance question into a structured verdict {vote, confidence} that it
# then signs and submits on-chain to the ThinkingGovernor.
#
#   Usage:  decide.sh <validatorId> "<question>"
#   Output (last line):  "<vote> <bucket>"   vote: 1=YES 2=NO 3=ABSTAIN
#                                             bucket: confidence in bps (mult. of 1000)
#
# Two paths, ONE interface (orthogonal — the orchestrator does not care which ran):
#
#   1. NATIVE HANZO-ENGINE — the operator asks the hanzo-engine (mistral.rs), the
#      inference engine the Hanzo node integrates, at its OpenAI-compatible
#      /v1/chat/completions on :36900, and parses VOTE/CONFIDENCE. Override the
#      endpoint/model with $ZEN_LLM_URL / $ZEN_LLM_MODEL.
#
#   2. CONSERVATION POLICY (deterministic stand-in) — when no local inference
#      backend is reachable (as in a stubbed-engine dev box), the operator falls
#      back to a transparent, reproducible policy so the on-chain mechanism can
#      still be exercised end-to-end. This is NOT model output and is labelled as
#      such on stderr; it must never be presented as LLM reasoning.
set -euo pipefail

vid="${1:?validatorId}"; question="${2:?question}"

# round a 0..100 percent to the nearest 1000-bps bucket the contract accepts
# snap a 0..100 percent to the nearest 2000-bps (20%) bucket — coarse enough that
# independently-reasoned confidences cluster into a settleable consensus key, while
# still a valid multiple of 1000 the contract accepts.
snap() { local c="$1"; ((c<0))&&c=0; ((c>100))&&c=100; echo $(( ((c+10)/20) * 2000 )); }

# The operator's brain is the NATIVE hanzo-engine (mistral.rs) — the inference
# engine the Hanzo node integrates, served OpenAI-compatible at
# /v1/chat/completions on :36900. (Ollama was retired: hanzo/desktop
# cleanup/ollama-runtime.) Override host/model with ZEN_LLM_URL / ZEN_LLM_MODEL.
ENGINE_URL="${ZEN_LLM_URL:-http://127.0.0.1:36900/v1/chat/completions}"
ENGINE_MODEL="${ZEN_LLM_MODEL:-Qwen/Qwen3-0.6B}"
prompt="You are thinking-validator #${vid} for the Beluga L3 conservation blockchain. \
Governance question: ${question} \
Reply with EXACTLY one line, no preamble: VOTE=<YES|NO|ABSTAIN> CONFIDENCE=<integer 0-100> /no_think"
body=$(python3 -c 'import json,sys;print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":sys.argv[2]}],"max_tokens":24,"temperature":0.3}))' "$ENGINE_MODEL" "$prompt")
resp=$(curl -s --max-time "${ZEN_LLM_TIMEOUT:-300}" "$ENGINE_URL" -H 'Content-Type: application/json' -d "$body" 2>/dev/null \
      | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("choices",[{}])[0].get("message",{}).get("content","") or d.get("response",""))' 2>/dev/null || true)
if [ -n "$resp" ]; then
  up=$(printf '%s' "$resp" | tr 'a-z' 'A-Z')
  vote=1; case "$up" in *NO*) vote=2;; *ABSTAIN*) vote=3;; esac
  conf=$(printf '%s' "$up" | grep -oE 'CONFIDENCE[=: ]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  [ -z "$conf" ] && conf=$(printf '%s' "$up" | grep -oE '[0-9]+' | head -1 || echo 70)
  echo "operator#${vid}: hanzo-engine verdict from ${ENGINE_URL} -> '${resp}'" >&2
  echo "$vote $(snap "$conf")"; exit 0
fi
echo "operator#${vid}: hanzo-engine unreachable at ${ENGINE_URL}; using policy stand-in" >&2

# Deterministic conservation policy (LLM runtime unavailable). Validators favour
# stronger safeguards for conservation funds; confidence varies; one dissents — a
# realistic quorum that exercises settle()'s winning-group + dissent-exclusion.
echo "operator#${vid}: [policy stand-in — hanzo-engine not reachable; start it: hanzo-server --port 36900 run -m Qwen/Qwen3-0.6B]" >&2
case "$vid" in
  1|2|3) echo "1 8000" ;;   # YES, high confidence  -> the winning group (>=3)
  4)     echo "1 7000" ;;   # YES, less sure        -> excluded (off-bucket)
  *)     echo "2 6000" ;;   # NO, dissent           -> excluded
esac
