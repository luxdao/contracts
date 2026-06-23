#!/usr/bin/env bash
# Migrate every thinking-stack contract's `admin` from the bootstrap deployer EOA
# to a 1-of-1 Safe (owned by a KMS-held key). One uniform move per contract:
# `transferAdmin(SAFE)`, signed by the CURRENT admin. Minters/relayers are left
# alone — those are the mint paths; only the managing `admin` role moves.
#
# The bootstrap deployer (0x9011…4714) stays the admin until you run this with
# --execute. Default is a DRY RUN: it reads every contract's on-chain admin and
# prints the exact transfer it WOULD send, mutating nothing.
#
#   migrate-admin-to-safe.sh <deployments.json> <rpc> [--execute]
#
# Required env:
#   SAFE=0x…            the 1-of-1 Safe to receive admin (deploy-safe-1of1.sh).
# For --execute only:
#   ADMIN_KEY=0x…       private key of the CURRENT admin (the bootstrap EOA).
#                       NEVER hardcoded here. Source it yourself at run time
#                       (KMS export / hardware signer). On mainnet it must be a
#                       secure signer, not a leaked key — see the mainnet guard.
#   MAINNET_OK=1        explicit ack required to --execute on Lux mainnet (96369).
#
# Idempotent: a contract already owned by SAFE is skipped; a contract whose admin
# is neither the bootstrap EOA nor SAFE is reported and skipped for manual review.
#
# ─── ROTATION RUNBOOK (deployer EOA → 1-of-1 KMS Safe, all chains) ────────────
# The bootstrap EOA stays admin of everything until step 3. Nothing here uses the
# leaked key; you supply the current-admin signer at run time.
#
#   0. KMS — get the owner address. The new Safe's sole owner is a key held in
#      lux/kms (~/work/lux/kms). Export only its ADDRESS (the key never leaves KMS;
#      it signs Safe txs later, manually). Call it $OWNER.
#   1. Safe — create the 1-of-1 Safe with that owner, per chain, using the Safe
#      stack (~/work/lux/safe = @luxfi/safe): deploy the singleton/proxy-factory
#      suite, then createProxyWithNonce + setup(owners=[$OWNER], threshold=1, …).
#      Record the resulting Safe address as $SAFE.
#   2. Dry run — SAFE=$SAFE ./migrate-admin-to-safe.sh deployments/<chain>.json <rpc>
#      Reads every contract's admin and prints the planned transfers. Mutates nothing.
#   3. Execute — when ready, append --execute with ADMIN_KEY set to the CURRENT
#      admin signer (the bootstrap EOA). Repeat per chain:
#        deployments/lux-local.json  (31337)   deployments/lux-devnet.json (96370)
#        deployments/lux-testnet.json|thinking-96368.json (96368)
#        deployments/zoo-l2-hub.json (200200)  deployments/lux-mainnet.json (96369)
#      Mainnet (96369) additionally needs MAINNET_OK=1 and a SECURE (non-leaked)
#      ADMIN_KEY — the retirement of a leaked key must not be its own mainnet sig.
#   4. Verify — re-run step 2; every contract should read "already owned by Safe".
#      The bootstrap EOA now holds nothing; retire it. Later, reconfigure the Safe's
#      owners/threshold (1-of-1 → N-of-M) directly in the Safe — out of scope here.
set -euo pipefail

CAST="${CAST:-cast}"; command -v "$CAST" >/dev/null || CAST="$HOME/.foundry/bin/cast"
DEPLOY="${1:?usage: migrate-admin-to-safe.sh <deployments.json> <rpc> [--execute]}"
RPC="${2:?need rpc url}"
EXECUTE=0; [ "${3:-}" = "--execute" ] && EXECUTE=1

# the deployer EOA being retired (override per chain if a chain bootstrapped from a different key)
BOOTSTRAP="${BOOTSTRAP:-0x9011E888251AB053B7bD1cdB598Db4f9DEd94714}"
LUX_MAINNET=96369

SAFE="${SAFE:?set SAFE=0x… (the 1-of-1 Safe to receive admin)}"
[[ "$SAFE" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "✗ SAFE is not an address: $SAFE"; exit 1; }

lc(){ tr '[:upper:]' '[:lower:]'; }
SAFE_LC="$(printf '%s' "$SAFE" | lc)"
BOOT_LC="$(printf '%s' "$BOOTSTRAP" | lc)"

CID="$("$CAST" chain-id --rpc-url "$RPC")"
echo "── migrate admin → Safe ───────────────────────────────"
echo "   deployments=$DEPLOY  rpc=$RPC  chainId=$CID"
echo "   bootstrap=${BOOTSTRAP}  →  safe=${SAFE}"
echo "   mode=$([ $EXECUTE = 1 ] && echo EXECUTE || echo 'DRY RUN (nothing sent)')"

# Mainnet guard: never broadcast to Lux mainnet without an explicit ack, and never
# with the leaked bootstrap key. The retirement of a leaked key must not itself be
# the leaked key's signature on mainnet.
if [ "$EXECUTE" = 1 ] && [ "$CID" = "$LUX_MAINNET" ]; then
  [ "${MAINNET_OK:-0}" = 1 ] || { echo "✗ refusing --execute on Lux mainnet ($LUX_MAINNET) without MAINNET_OK=1 and a secure ADMIN_KEY"; exit 1; }
  echo "   ⚠ MAINNET execute acknowledged — ADMIN_KEY must be a secure (non-leaked) signer"
fi
[ "$EXECUTE" = 1 ] && [ -z "${ADMIN_KEY:-}" ] && { echo "✗ --execute needs ADMIN_KEY (current admin signer)"; exit 1; }

# Extract every 0x…40 address value from the deployment JSON, keyed by name, but
# skip the "deployer" provenance field — that's the EOA, not a contract to migrate.
# bash 3.2 (macOS default) has no `mapfile` — read the lines portably.
ENTRIES=()
while IFS= read -r line; do [ -n "$line" ] && ENTRIES+=("$line"); done < <(node -e '
  const fs=require("fs");const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const walk=(o,p="")=>Object.entries(o).flatMap(([k,v])=>
    v&&typeof v==="object"?walk(v,p+k+"."):
    (typeof v==="string"&&/^0x[0-9a-fA-F]{40}$/.test(v)&&!/deployer/i.test(k)?[`${p}${k} ${v}`]:[]));
  walk(d).forEach(l=>console.log(l));
' "$DEPLOY")

planned=0; skipped=0; done_=0; foreign=0
for e in "${ENTRIES[@]}"; do
  name="${e%% *}"; addr="${e##* }"
  # read admin(); contracts without an admin() (e.g. pure libs, the coin's miners) just fail → skip
  cur="$("$CAST" call "$addr" "admin()(address)" --rpc-url "$RPC" 2>/dev/null || true)"
  if [ -z "$cur" ]; then printf "   ·   %-26s %s  (no admin() — skip)\n" "$name" "$addr"; continue; fi
  cur_lc="$(printf '%s' "$cur" | lc)"
  if [ "$cur_lc" = "$SAFE_LC" ]; then
    printf "   ✓   %-26s %s  already owned by Safe\n" "$name" "$addr"; done_=$((done_+1)); continue
  fi
  if [ "$cur_lc" != "$BOOT_LC" ]; then
    printf "   ?   %-26s %s  admin=%s  (not the bootstrap EOA — manual review)\n" "$name" "$addr" "$cur"; foreign=$((foreign+1)); continue
  fi
  # admin is the bootstrap EOA → plan/execute the transfer
  if [ "$EXECUTE" = 1 ]; then
    "$CAST" send "$addr" "transferAdmin(address)" "$SAFE" --private-key "$ADMIN_KEY" --rpc-url "$RPC" >/dev/null
    # verify it landed
    now="$("$CAST" call "$addr" "admin()(address)" --rpc-url "$RPC" 2>/dev/null | lc || true)"
    if [ "$now" = "$SAFE_LC" ]; then printf "   →   %-26s %s  transferred admin → Safe ✓\n" "$name" "$addr"; planned=$((planned+1));
    else printf "   ✗   %-26s %s  transfer did NOT land (admin=%s)\n" "$name" "$addr" "$now"; fi
  else
    printf "   →   %-26s %s  WOULD transferAdmin → Safe\n" "$name" "$addr"; planned=$((planned+1))
  fi
done

echo "──────────────────────────────────────────────────────"
echo "   $([ $EXECUTE = 1 ] && echo transferred || echo to-transfer)=$planned  already-Safe=$done_  foreign-admin=$foreign"
[ "$EXECUTE" = 0 ] && echo "   DRY RUN — re-run with --execute (and ADMIN_KEY set) when ready."
[ "$foreign" -gt 0 ] && echo "   ⚠ $foreign contract(s) have an admin that is neither the bootstrap EOA nor the Safe — review before retiring the EOA."
exit 0
