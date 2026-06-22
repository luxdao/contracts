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
#   1. REAL LLM  — if $ZEN_LLM_URL is set (an ollama /api/generate-compatible
#      endpoint), the operator asks its local model and parses VOTE/CONFIDENCE.
#      Point it at a restored hanzo-engine / ollama / any OpenAI-ish gateway and
#      the verdicts become real model cognition with zero changes here.
#
#   2. CONSERVATION POLICY (deterministic stand-in) — when no local inference
#      backend is reachable (as in a stubbed-engine dev box), the operator falls
#      back to a transparent, reproducible policy so the on-chain mechanism can
#      still be exercised end-to-end. This is NOT model output and is labelled as
#      such on stderr; it must never be presented as LLM reasoning.
set -euo pipefail

vid="${1:?validatorId}"; question="${2:?question}"

# round a 0..100 percent to the nearest 1000-bps bucket the contract accepts
snap() { local c="$1"; ((c<0))&&c=0; ((c>100))&&c=100; echo $(( ((c+5)/10) * 1000 )); }

if [ -n "${ZEN_LLM_URL:-}" ]; then
  prompt="You are thinking-validator #${vid} for the Beluga L3 conservation blockchain. \
Governance question: ${question} \
Reply with EXACTLY one line, no preamble: VOTE=<YES|NO|ABSTAIN> CONFIDENCE=<integer 0-100> /no_think"
  body=$(printf '{"model":"%s","prompt":%s,"stream":false,"options":{"temperature":0.3,"seed":%s,"num_predict":40}}' \
        "${ZEN_LLM_MODEL:-qwen3:0.6b}" "$(printf '%s' "$prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" "$vid")
  resp=$(curl -s --max-time 60 "$ZEN_LLM_URL" -d "$body" 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("response",""))' 2>/dev/null || true)
  if [ -n "$resp" ]; then
    up=$(printf '%s' "$resp" | tr 'a-z' 'A-Z')
    vote=1; case "$up" in *NO*) vote=2;; *ABSTAIN*) vote=3;; esac
    conf=$(printf '%s' "$up" | grep -oE 'CONFIDENCE[=: ]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
    [ -z "$conf" ] && conf=$(printf '%s' "$up" | grep -oE '[0-9]+' | head -1 || echo 70)
    echo "operator#${vid}: REAL-LLM verdict from ${ZEN_LLM_URL} -> '${resp}'" >&2
    echo "$vote $(snap "$conf")"; exit 0
  fi
  echo "operator#${vid}: ZEN_LLM_URL set but no response; using policy stand-in" >&2
fi

# Deterministic conservation policy (LLM runtime unavailable). Validators favour
# stronger safeguards for conservation funds; confidence varies; one dissents — a
# realistic quorum that exercises settle()'s winning-group + dissent-exclusion.
echo "operator#${vid}: [policy stand-in — no local LLM runtime; set ZEN_LLM_URL for real cognition]" >&2
case "$vid" in
  1|2|3) echo "1 8000" ;;   # YES, high confidence  -> the winning group (>=3)
  4)     echo "1 7000" ;;   # YES, less sure        -> excluded (off-bucket)
  *)     echo "2 6000" ;;   # NO, dissent           -> excluded
esac
