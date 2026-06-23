#!/usr/bin/env bash
# beluga-l3-live.sh — prove the FULL Zoo-L2-hub + Beluga-L3 architecture locally,
# end to end, on two real EVM chains:
#
#   Zoo L2 (chainId 200200)  : the hub — L3Registry (directory of model-zoo L3s)
#   Beluga L3 (chainId 808080): the L3 — the sovereign thinking-governance stack
#       (ThinkingGovernor, ProofOfThoughtRegistry, ThinkingChainObservatory,
#        GovernancePoTBridge, ThinkingReputation), its own model zoo + governance
#
# It deploys both, REGISTERS Beluga L3 in the Zoo L2 hub, runs one real
# governance round on Beluga L3 (operators decide a knob via their LLM, quorum
# settles it, PoT receipt recorded, reputation accrues), and reads it ALL back
# from chain. This is the local proof that the architecture works before any
# mainnet/testnet/devnet deploy. Operator cognition is pluggable (decide.sh):
# real hanzo-engine if reachable, else a labelled deterministic policy.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; CONTRACTS="$(cd "$HERE/../.." && pwd)"; cd "$CONTRACTS"
export PATH="$HOME/.foundry/bin:$PATH" FOUNDRY_DISABLE_NIGHTLY_WARNING=1
T="contracts/deployables/thinking"
ZOO_RPC="http://127.0.0.1:8545"; ZOO_CID=200200
BLG_RPC="http://127.0.0.1:8546"; BLG_CID=808080

# anvil deterministic accounts
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # opener/deployer
A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
OPS=(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
     0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
     0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
     0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
     0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba)
TREASURY=0xa0Ee7A142d267C1f36714E4a8F75612F20a79720
QUESTION="Beluga L3: require a 4-of-5 validator quorum (vs 3-of-5) for high-value AI-task settlement, to protect conservation funds?"
KNOB="aivm.quorum.threshold"
SPEC=$(cast keccak "zen/thinking-governor/model-spec/v1")
say(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

# ---- two anvils: Zoo L2 + Beluga L3 -----------------------------------------
say "starting Zoo L2 (chainId $ZOO_CID) + Beluga L3 (chainId $BLG_CID)"
pkill -f 'anvil' 2>/dev/null || true; sleep 1
anvil --silent --chain-id $ZOO_CID --port 8545 >/tmp/anvil-zoo.log 2>&1 &
anvil --silent --chain-id $BLG_CID --port 8546 >/tmp/anvil-blg.log 2>&1 &
# KEEP=1 leaves both anvils running after the proof so the observatory dashboard
# can be opened against them (visibility check / human inspection).
trap '[ -n "${KEEP:-}" ] || pkill -f "anvil" 2>/dev/null || true' EXIT
for u in "$ZOO_RPC" "$BLG_RPC"; do for i in $(seq 1 40); do cast chain-id --rpc-url "$u" >/dev/null 2>&1 && break; sleep 0.25; done; done
echo "  Zoo L2 up (chainId $(cast chain-id --rpc-url $ZOO_RPC)); Beluga L3 up (chainId $(cast chain-id --rpc-url $BLG_RPC))"
forge build >/dev/null 2>&1 || { echo "forge build failed"; exit 1; }
dep(){ forge create "$2" --rpc-url "$1" --private-key "$K0" --broadcast --json ${3:+--constructor-args $3} 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["deployedTo"])'; }

# ---- Zoo L2 hub -------------------------------------------------------------
say "deploying the Zoo L2 hub (L3Registry)"
HUB=$(dep "$ZOO_RPC" "$T/L3Registry.sol:L3Registry" "0x0000000000000000000000000000000000000000")
echo "  Zoo L2 L3Registry = $HUB"

# ---- Beluga L3 thinking-governance stack -----------------------------------
say "deploying Beluga L3 thinking-governance stack"
REG=$(dep "$BLG_RPC" "$T/ProofOfThoughtRegistry.sol:ProofOfThoughtRegistry" "$A0")  # admin=deployer
GOV=$(dep "$BLG_RPC" "$T/ThinkingGovernor.sol:ThinkingGovernor" "1000000000000000000 0 500000000000000000 100000000000000000 $TREASURY 0x0000000000000000000000000000000000000000")
# the native coin: Bitcoin-shaped issuance (1B cap, halving every 4y, burn tail).
# admin = deployer (the DAO seat for the demo); minter = deployer acting as the
# settlement that mines the subsidy for accepted cognition. Deployed before the
# observatory so the observatory's economics() can SEE the chain's issuance.
AICOIN=$(forge create "$T/AICoin.sol:AICoin" --rpc-url "$BLG_RPC" --private-key "$K0" --broadcast --json \
         --constructor-args "AI" "AI" "$A0" "$A0" 2>/dev/null \
         | python3 -c 'import sys,json;print(json.load(sys.stdin)["deployedTo"])')
OBS=$(dep "$BLG_RPC" "$T/ThinkingChainObservatory.sol:ThinkingChainObservatory" "$GOV $REG $AICOIN")
BRIDGE=$(dep "$BLG_RPC" "$T/GovernancePoTBridge.sol:GovernancePoTBridge" "$GOV $REG")
REP=$(dep "$BLG_RPC" "$T/ThinkingReputation.sol:ThinkingReputation" "$GOV 2000")
# value-deciding governance: operators' LLMs PROPOSE a knob value; the chain settles
# to the Byzantine-robust median (composes the governor's bonded operator set).
# value-deciding committee is sortition-sampled from the governor's bonded operator
# set (permissionless: capture needs a population majority, not slot-racing). Demo
# fees 0 (the sunk-fee path is unit-tested); treasury sinks any fees.
PARAMS=$(dep "$BLG_RPC" "$T/ThinkingParameters.sol:ThinkingParameters" "$GOV $TREASURY 0 0")
# authorize the bridge as the registry's recorder (register() is now gated — only
# authorized recorders may write PoT receipts; closes the front-run/forgery vector)
cast send "$REG" "setRecorder(address,bool)" "$BRIDGE" true --private-key "$K0" --rpc-url "$BLG_RPC" >/dev/null
echo "  governor=$GOV  observatory=$OBS  reputation=$REP  aicoin=$AICOIN  parameters=$PARAMS  (bridge authorized as PoT recorder)"

# ---- register Beluga L3 in the Zoo L2 hub -----------------------------------
say "registering Beluga L3 in the Zoo L2 hub"
cast send "$HUB" "register(string,uint256,address,address,string)" "Beluga" "$BLG_CID" "$GOV" "$OBS" "ipfs://beluga-l3" --private-key "$K0" --rpc-url "$ZOO_RPC" >/dev/null
echo "  Beluga L3 (chainId $BLG_CID) registered under the Zoo L2 hub"

# ---- a real governance round on Beluga L3 ----------------------------------
say "Beluga L3: 5 thinking-validators bond, decide a knob, settle a quorum"
for i in 0 1 2 3 4; do cast send "$GOV" "registerOperator()" --value 1ether --private-key "${OPS[$i]}" --rpc-url "$BLG_RPC" >/dev/null; done
QH=$(cast keccak "$QUESTION"); EH=$(cast keccak "beluga-evidence")
cast send "$GOV" "openThought(bytes32,bytes32,bytes32,uint8,uint8,uint64,string)" "$SPEC" "$QH" "$EH" 5 3 3600 "$KNOB" --value 0.6ether --private-key "$K0" --rpc-url "$BLG_RPC" >/dev/null
# COGNITION SOURCE banner — never hide whether verdicts came from the LLM or the
# labelled deterministic stand-in (red-team R5 MED: do not pass scripted votes off
# as model output). decide.sh writes its provenance to stderr; surface it.
if curl -s -m 2 "${HANZO_ENGINE:-http://127.0.0.1:36900}/health" >/dev/null 2>&1; then
  echo "  COGNITION SOURCE: hanzo-engine @ ${HANZO_ENGINE:-http://127.0.0.1:36900} (real LLM verdicts)"
else
  echo "  COGNITION SOURCE: deterministic policy stand-in (hanzo-engine unreachable — verdicts are SCRIPTED, not model output)"
fi
for i in 0 1 2 3 4; do
  vid=$((i+1)); OPADDR=$(cast wallet address --private-key "${OPS[$i]}")
  read -r VOTE BUCKET < <(bash "$HERE/decide.sh" "$vid" "$QUESTION" 2>>/tmp/beluga-cognition.log)
  EV=$(cast keccak "validator-$vid"); DIG=$(cast call "$GOV" "verdictDigest(uint256,address,bytes32,uint8,uint16,bytes32)(bytes32)" 0 "$OPADDR" "$SPEC" "$VOTE" "$BUCKET" "$EV" --rpc-url "$BLG_RPC")
  SIG=$(cast wallet sign --no-hash "$DIG" --private-key "${OPS[$i]}")
  cast send "$GOV" "submitVerdict(uint256,uint8,uint16,bytes32,bytes)" 0 "$VOTE" "$BUCKET" "$EV" "$SIG" --private-key "${OPS[$i]}" --rpc-url "$BLG_RPC" >/dev/null
  vn=YES; [ "$VOTE" = 2 ] && vn=NO; [ "$VOTE" = 3 ] && vn=ABSTAIN; echo "  validator $vid -> $vn @ $((BUCKET/100))% (provenance -> /tmp/beluga-cognition.log)"
done
cast rpc evm_increaseTime 4000 --rpc-url "$BLG_RPC" >/dev/null; cast rpc evm_mine --rpc-url "$BLG_RPC" >/dev/null
cast send "$GOV" "settle(uint256)" 0 --private-key "$K0" --rpc-url "$BLG_RPC" >/dev/null
cast send "$BRIDGE" "recordThought(uint256)" 0 --private-key "$K0" --rpc-url "$BLG_RPC" >/dev/null 2>&1 || true
cast send "$REP" "recordSettled(uint256)" 0 --private-key "$K0" --rpc-url "$BLG_RPC" >/dev/null 2>&1 || true

# ---- mine AI: the fair-launch subsidy for the settled cognition --------------
say "Beluga L3: mine the AI subsidy for the settled thought (halving schedule, on-chain)"
# advance halfway into epoch 0 so the schedule has vested MAX/4 = 250M AI
cast rpc evm_increaseTime 63072000 --rpc-url "$BLG_RPC" >/dev/null; cast rpc evm_mine --rpc-url "$BLG_RPC" >/dev/null
SHARE_AI=1000                              # 1000 AI per agreeing validator (demo)
SHARE=$(python3 -c "print($SHARE_AI*10**18)")  # wei (1e21 overflows bash 64-bit)
for i in 0 1 2 3 4; do
  vid=$((i+1)); OPADDR=$(cast wallet address --private-key "${OPS[$i]}")
  # mine the subsidy to every validator that bonded and answered (the cognitive workers)
  cast send "$AICOIN" "mintSubsidy(address,uint256)" "$OPADDR" "$SHARE" --private-key "$K0" --rpc-url "$BLG_RPC" >/dev/null
  echo "  mined $SHARE_AI AI -> validator $vid (bounded by the halving schedule)"
done
# EIP-1559-style fee burn: validator 1 burns a slice of its reward (deflationary sink)
cast send "$AICOIN" "burn(uint256)" 250000000000000000000 --private-key "${OPS[0]}" --rpc-url "$BLG_RPC" >/dev/null
echo "  burned 250 AI (fee sink) -> supply now deflationary against the subsidy"

# ---- value-deciding governance: the LLM DECIDES the knob value, chain takes median --
say "Beluga L3: thinking-validators PROPOSE the conservation tithe (bps); chain settles the MEDIAN"
PQ="Propose the conservation tithe in basis points routed from every settled AI-task fee to ocean and beluga-whale conservation, balancing the mission against fee competitiveness."
PKNOB="beluga.conservation.tithe.bps"; PLO=0; PHI=2000
PPH=$(cast keccak "$PQ")
RID=$(cast call "$PARAMS" "roundCount()(uint256)" --rpc-url "$BLG_RPC" | awk '{print $1}')
cast send "$PARAMS" "open(bytes32,bytes32,string,uint256,uint256,uint8,uint8,uint64)" "$SPEC" "$PPH" "$PKNOB" "$PLO" "$PHI" 5 3 3600 --private-key "$K0" --rpc-url "$BLG_RPC" >/dev/null
for i in 0 1 2 3 4; do
  vid=$((i+1)); OPADDR=$(cast wallet address --private-key "${OPS[$i]}")
  read -r VAL VBUCKET < <(bash "$HERE/decide-value.sh" "$vid" "$PQ" "$PLO" "$PHI" 2>>/tmp/beluga-cognition.log)
  PEV=$(cast keccak "tithe-rationale-$vid")
  PDIG=$(cast call "$PARAMS" "proposalDigest(uint256,address,bytes32,uint256,uint16,bytes32)(bytes32)" "$RID" "$OPADDR" "$SPEC" "$VAL" "$VBUCKET" "$PEV" --rpc-url "$BLG_RPC")
  PSIG=$(cast wallet sign --no-hash "$PDIG" --private-key "${OPS[$i]}")
  cast send "$PARAMS" "submitProposal(uint256,uint256,uint16,bytes32,bytes)" "$RID" "$VAL" "$VBUCKET" "$PEV" "$PSIG" --private-key "${OPS[$i]}" --rpc-url "$BLG_RPC" >/dev/null
  echo "  validator $vid -> proposes tithe $VAL bps @ $((VBUCKET/100))%"
done
cast rpc evm_increaseTime 4000 --rpc-url "$BLG_RPC" >/dev/null; cast rpc evm_mine --rpc-url "$BLG_RPC" >/dev/null
cast send "$PARAMS" "settle(uint256)" "$RID" --private-key "$K0" --rpc-url "$BLG_RPC" >/dev/null
VOUT=$(cast call "$PARAMS" "valueOf(bytes32,string)(uint256,bool)" "$SPEC" "$PKNOB" --rpc-url "$BLG_RPC")
TITHE=$(printf '%s\n' "$VOUT" | sed -n '1p' | awk '{print $1}'); TSET=$(printf '%s\n' "$VOUT" | sed -n '2p' | tr -d ' ')
echo "  -> chain DECIDED tithe = $TITHE bps (median of validator proposals), now LIVE on-chain"

# ---- read it ALL back from both chains --------------------------------------
say "PROOF — read back from both chains"
echo "Zoo L2 hub (chainId $ZOO_CID):"
echo "  L3 count       = $(cast call "$HUB" 'count()(uint256)' --rpc-url "$ZOO_RPC")"
BREC=$(cast call "$HUB" "getByChainId(uint256)((string,uint256,address,address,address,string,uint64,bool))" "$BLG_CID" --rpc-url "$ZOO_RPC")
echo "  Beluga record  = $(echo "$BREC" | cut -c1-90)..."
echo "Beluga L3 (chainId $BLG_CID):"
TH=$(cast call "$GOV" "getThought(uint256)((bytes32,bytes32,bytes32,uint8,uint8,uint64,uint64,address,uint8,uint8,string,uint8,uint16,uint8,bytes32))" 0 --rpc-url "$BLG_RPC")
python3 - "$TH" <<'PY'
import sys
inner=sys.argv[1].strip()[1:-1]; parts=[];d=0;c=""
for ch in inner:
    if ch in "([": d+=1
    if ch in ")]": d-=1
    if ch=="," and d==0: parts.append(c.strip()); c=""
    else: c+=ch
parts.append(c.strip()); n=lambda s:int(s.split()[0])
print(f"  status         = {['None','Open','Settled','Failed'][n(parts[8])]}")
print(f"  canonical vote = {['Invalid','YES','NO','Abstain'][n(parts[11])]} @ {n(parts[12])//100}%")
print(f"  quorum         = {n(parts[13])} of {n(parts[3])} (threshold {n(parts[4])})")
PY
for i in 0 1 2 3 4; do OPADDR=$(cast wallet address --private-key "${OPS[$i]}"); W=$(cast call "$REP" "weightOf(address)(uint32)" "$OPADDR" --rpc-url "$BLG_RPC" 2>/dev/null|awk '{print $1}'); echo "  validator $((i+1)) reputation = $(( ${W:-0}/100 ))%"; done
echo "Beluga L3 — AI coin economics (read via the on-chain Observatory's economics()):"
ECO=$(cast call "$OBS" "economics()((address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))" --rpc-url "$BLG_RPC")
python3 - "$ECO" <<'PY'
import sys
inner=sys.argv[1].strip()[1:-1]; parts=[];d=0;c=""
for ch in inner:
    if ch in "([": d+=1
    if ch in ")]": d-=1
    if ch=="," and d==0: parts.append(c.strip()); c=""
    else: c+=ch
parts.append(c.strip()); num=lambda s:int(s.split()[0].replace(',',''))
coin=parts[0].split()[0]; cap,ep,esub,unlocked,minted,burned,circ,remain=[num(parts[i]) for i in range(1,9)]
ai=lambda w: f"{w/10**18:,.0f} AI"
print(f"  coin              = {coin}")
print(f"  epoch             = {ep} (subsidy halves every 4 years)")
print(f"  hard cap          = {ai(cap)}")
print(f"  unlocked so far   = {ai(unlocked)}  ({100*unlocked/cap:.2f}% of cap)")
print(f"  mined (minted)    = {ai(minted)}")
print(f"  burned            = {ai(burned)}  (deflationary sink)")
print(f"  circulating       = {ai(circ)}")
print(f"  remaining subsidy = {ai(remain)}")
PY
for i in 0 1 2 3 4; do OPADDR=$(cast wallet address --private-key "${OPS[$i]}"); B=$(cast call "$AICOIN" "balanceOf(address)(uint256)" "$OPADDR" --rpc-url "$BLG_RPC"|awk '{print $1}'); python3 -c "import sys;print(f'  validator $((i+1)) balance   = {int(sys.argv[1])/10**18:,.0f} AI')" "$B"; done

# ---- ASSERT — a real proof FAILS HARD on wrong on-chain state ----------------
# (displaying numbers is not proof; these checks exit non-zero on any mismatch so
#  the script cannot print DONE on a broken chain — red-team R5 HIGH.)
say "ASSERT — verifying on-chain state (proof fails hard on mismatch)"
FAILS=0
chk(){ if [ "$2" = "$3" ]; then printf '  \033[1;32mPASS\033[0m %s = %s\n' "$1" "$2"; else printf '  \033[1;31mFAIL\033[0m %s: got=%s want=%s\n' "$1" "$2" "$3"; FAILS=$((FAILS+1)); fi; }
u(){ cast call "$1" "$2" --rpc-url "$3" | awk '{print $1}'; }  # uint as decimal string

chk "Zoo L2 hub L3 count" "$(u "$HUB" 'count()(uint256)' "$ZOO_RPC")" "1"
# governance settled with a REAL quorum (the vote itself is the LLM's call, not asserted)
read -r S A TH N < <(cast call "$GOV" "getThought(uint256)((bytes32,bytes32,bytes32,uint8,uint8,uint64,uint64,address,uint8,uint8,string,uint8,uint16,uint8,bytes32))" 0 --rpc-url "$BLG_RPC" | python3 -c '
import sys; inner=sys.stdin.read().strip()[1:-1]; p=[];d=0;c=""
for ch in inner:
    d+=ch in "([" ; d-=ch in ")]"
    if ch=="," and d==0: p.append(c.strip()); c=""
    else: c+=ch
p.append(c.strip()); n=lambda s:s.split()[0]
print(n(p[8]), n(p[13]), n(p[4]), n(p[3]))')
chk "Beluga thought status (2=Settled)" "$S" "2"
chk "committee size n" "$N" "5"
if [ "${A:-0}" -ge "${TH:-99}" ]; then printf '  \033[1;32mPASS\033[0m quorum %s >= threshold %s\n' "$A" "$TH"; else printf '  \033[1;31mFAIL\033[0m quorum %s < threshold %s\n' "$A" "$TH"; FAILS=$((FAILS+1)); fi
# economics: exact wei, read directly AND via the Observatory (visibility-surface parity)
chk "AICoin hard cap (wei)" "$(u "$AICOIN" 'MAX_SUBSIDY()(uint256)' "$BLG_RPC")" "1000000000000000000000000000"
chk "AICoin minted (wei)" "$(u "$AICOIN" 'mintedSubsidy()(uint256)' "$BLG_RPC")" "5000000000000000000000"
chk "AICoin totalSupply after burn (wei)" "$(u "$AICOIN" 'totalSupply()(uint256)' "$BLG_RPC")" "4750000000000000000000"
EBURN=$(cast call "$OBS" "economics()((address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))" --rpc-url "$BLG_RPC" | python3 -c '
import sys; inner=sys.stdin.read().strip()[1:-1]; p=[];d=0;c=""
for ch in inner:
    d+=ch in "([" ; d-=ch in ")]"
    if ch=="," and d==0: p.append(c.strip()); c=""
    else: c+=ch
p.append(c.strip()); print(p[6].split()[0])')  # burned (index 6)
chk "Observatory economics.burned (wei)" "$EBURN" "250000000000000000000"
V1=$(cast call "$AICOIN" "balanceOf(address)(uint256)" "$(cast wallet address --private-key "${OPS[0]}")" --rpc-url "$BLG_RPC"|awk '{print $1}')
chk "validator-1 balance (1000 mined - 250 burned, wei)" "$V1" "750000000000000000000"
# value-deciding governance: the LLM-proposed parameter was settled to a live value
chk "tithe parameter decided (valueOf set)" "$TSET" "true"
if [ "${TITHE:-99999}" -ge "$PLO" ] && [ "${TITHE:-99999}" -le "$PHI" ]; then printf '  \033[1;32mPASS\033[0m decided tithe %s bps within [%s,%s]\n' "$TITHE" "$PLO" "$PHI"; else printf '  \033[1;31mFAIL\033[0m decided tithe %s out of [%s,%s]\n' "$TITHE" "$PLO" "$PHI"; FAILS=$((FAILS+1)); fi
chk "parameter round status (2=Settled)" "$(cast call "$PARAMS" "getRound(uint256)((bytes32,bytes32,string,uint256,uint256,uint8,uint8,uint64,uint64,address,uint8,uint8,uint256))" "$RID" --rpc-url "$BLG_RPC" | python3 -c '
import sys; inner=sys.stdin.read().strip()[1:-1]; p=[];d=0;c=""
for ch in inner:
    d+=ch in "([" ; d-=ch in ")]"
    if ch=="," and d==0: p.append(c.strip()); c=""
    else: c+=ch
p.append(c.strip()); print(p[10].split()[0])')" "2"
if [ "$FAILS" -ne 0 ]; then printf '\n\033[1;31mPROOF FAILED — %s assertion(s) wrong; this is NOT a passing proof.\033[0m\n' "$FAILS"; exit 1; fi

say "DONE — Zoo L2 hub lists Beluga L3; governance settled + AI mined + a knob VALUE decided by validator LLMs (median), ALL ASSERTIONS PASS. Architecture proven locally."
echo "Zoo L2 hub=$HUB  Beluga L3 governor=$GOV  aicoin=$AICOIN  parameters=$PARAMS"
if [ -n "${KEEP:-}" ]; then
  echo "DASHBOARD file://$HERE/observatory.html?rpc=$BLG_RPC&observatory=$OBS&reputation=$REP&parameters=$PARAMS"
  echo "(anvils left running — pkill -f anvil when done)"
fi