# Thinking Chains — MAINNET deploy runbook

**DO NOT RUN until the user (a) confirms go-ahead AND (b) provides a KMS-sourced
deployer key.** The currently-funded seed (`/tmp/.luxmn`) is PLAINTEXT and is for
devnet/testnet ONLY. Mainnet must use a rotated, KMS-sourced key.

## Targets (verified 2026-06-22)

| Network          | RPC                                         | chainId | Status        |
|------------------|---------------------------------------------|---------|---------------|
| Lux **testnet**  | https://api.lux-test.network/ext/bc/C/rpc   | 96368   | DEPLOYED here |
| Lux **mainnet**  | https://api.lux.network/ext/bc/C/rpc        | 96369   | runbook below |
| Zoo  **mainnet** | https://api.zoo.network/ext/bc/C/rpc        | 200200  | runbook below |

NOTE the one-digit gap: testnet 96368 vs Lux-mainnet **96369**. Confirm chainId
before every mainnet send.

## Pre-flight

```bash
export PATH="$HOME/.foundry/bin:$PATH" FOUNDRY_DISABLE_NIGHTLY_WARNING=1
cd ~/work/lux/dao/contracts

# 1) Source the deployer from KMS into a 600-perm file (NEVER argv/stdout).
#    Replace with the real KMS fetch (hanzo/lux kms). The file must contain the
#    mnemonic (or use --private-key form via a KMS-issued hex key) and be 0600.
umask 077
kms get lux/mainnet/thinking-deployer-mnemonic > /tmp/.thinking-mn   # KMS, not plaintext-at-rest
chmod 600 /tmp/.thinking-mn

# 2) Confirm the deployer + chain + gas balance (no secret printed).
RPC=https://api.lux.network/ext/bc/C/rpc        # or Zoo: https://api.zoo.network/ext/bc/C/rpc
cast wallet address --mnemonic /tmp/.thinking-mn          # deployer addr
cast chain-id  --rpc-url "$RPC"                           # MUST be 96369 (Lux) or 200200 (Zoo)
cast balance "$(cast wallet address --mnemonic /tmp/.thinking-mn)" --rpc-url "$RPC"  # > 0 for gas
```

## Deploy

The deploy script is chain-agnostic; only RPC + MN_FILE + TREASURY change. TREASURY
should be the **DAO multisig**, not the deployer EOA, on mainnet.

```bash
RPC=https://api.lux.network/ext/bc/C/rpc \
MN_FILE=/tmp/.thinking-mn \
TREASURY=0x<DAO_MULTISIG> \
bash scripts/thinking/deploy-thinking.sh
```

It deploys ProofOfThoughtRegistry, ThinkingGovernor, AICoin, ThinkingChainObservatory,
GovernancePoTBridge, ThinkingReputation; calls `setRecorder(bridge,true)`; reads
`overview()` back; and writes `deployments/thinking-<chainId>.json`.

What the script does NOT do (deliberate — governance ratifies these):
- It leaves **AICoin.minter = 0x0** (issuance FROZEN). No coin can be minted until
  governance points the minter at the settlement contract.
- It sets TREASURY as AICoin/Governor admin but does not transfer admin to the DAO
  beyond that (pass TREASURY = DAO multisig to get this right at deploy time).

## Post-deploy wiring (the two switches)

After the DAO ratifies the mint policy and the settlement contract address is known:

```bash
REG=<ProofOfThoughtRegistry>
BRIDGE=<GovernancePoTBridge>
AICOIN=<AICoin>
SETTLEMENT=<the contract authorized to mine the subsidy>   # mints AI on accepted cognition
RPC=https://api.lux.network/ext/bc/C/rpc

# 1) Recorder: authorize the bridge to record PoT receipts (registry admin only).
#    The deploy script already did this; re-assert / verify:
cast call "$REG" 'isRecorder(address)(bool)' "$BRIDGE" --rpc-url "$RPC"     # expect true
# (if needed) cast send "$REG" 'setRecorder(address,bool)' "$BRIDGE" true --rpc-url "$RPC" --mnemonic /tmp/.thinking-mn

# 2) Minter: point AICoin's mint seam at the settlement (AICoin admin = TREASURY only).
#    THIS UNFREEZES ISSUANCE — do it only after the mint policy is ratified.
cast send "$AICOIN" 'setMinter(address)' "$SETTLEMENT" --rpc-url "$RPC" --mnemonic /tmp/.thinking-mn
cast call "$AICOIN" 'minter()(address)' --rpc-url "$RPC"                    # expect $SETTLEMENT

# 3) (optional) hand the DAO seat fully to the multisig if not already TREASURY:
# cast send "$AICOIN" 'transferAdmin(address)' 0x<DAO_MULTISIG> --rpc-url "$RPC" --mnemonic /tmp/.thinking-mn
```

`setMinter(0x0)` is recoverable (re-freezes issuance, can be re-pointed later).
`transferAdmin` is one-way to a non-zero address — guard against handing it to a
wrong address (it reverts on 0x0, so it can't be zero-bricked).

## Verify (read everything back on-chain)

```bash
OBS=<ThinkingChainObservatory>
cast call "$OBS" 'overview()((uint256,uint256,uint256,uint256,uint256,uint256,uint256,address))' --rpc-url "$RPC"
cast call "$OBS" 'economics()((uint256,uint256,uint256,uint256,uint256,uint256))' --rpc-url "$RPC"
# confirm code is present at each address:
for a in "$REG" "$GOV" "$OBS" "$BRIDGE" "$REP" "$AICOIN"; do echo "$a $(cast code "$a" --rpc-url "$RPC" | wc -c)"; done
```

## Constructor reference (if deploying a single contract by hand)

```
ProofOfThoughtRegistry(address admin)
ThinkingGovernor(uint256 minBond, uint64 deregisterCooldown, uint256 rewardPerThought, uint256 openFee, address treasury, address keyValuePairs)
AICoin(string name, string symbol, address admin, address minter)        # minter=0x0 to freeze
ThinkingChainObservatory(address governor, address registry, address coin)
GovernancePoTBridge(address governor, address registry)
ThinkingReputation(address governor, uint32 alphaBps)                     # alpha=2000 used on test/local
```

## Safety rules (enforced)

- KMS-sourced key only on mainnet; the plaintext `/tmp/.luxmn` is testnet/devnet only.
- Confirm chainId on every mainnet send (96369 Lux / 200200 Zoo; NOT 96368).
- Issuance stays frozen (`minter=0x0`) until the DAO ratifies the mint policy.
- TREASURY/admin = DAO multisig, not the deployer EOA.
