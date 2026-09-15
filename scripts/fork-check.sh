#!/usr/bin/env bash
# Forked-mainnet gate for Gilt's rate adapters. Run before any deployment.
# The local suite uses mocks and cannot see an upstream signature or contract
# change; this can.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(printf '(contract-call? .stackingdao-rate-source get-stx-per-ststx)\n(contract-call? .stbtc-rate-source get-stx-per-ststx)\n' \
  | clarinet console --manifest-path Clarinet-fork.toml 2>&1 | grep -E '^\(ok|^\(err')
echo "$OUT" | nl -ba
STSTX=$(echo "$OUT" | sed -n 1p); STBTC=$(echo "$OUT" | sed -n 2p)
echo "$STSTX" | grep -qE '^\(ok u1[0-9]{6}\)$' || { echo "FAIL stSTX rate outside band: $STSTX"; exit 1; }
echo "$STBTC" | grep -qE '^\(ok u10[0-9]{7}\)$' || { echo "FAIL stBTC rate outside band: $STBTC"; exit 1; }
echo
echo "OK  stSTX $STSTX  ·  stBTC $STBTC  (canonical sources, in band)"
