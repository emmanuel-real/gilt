#!/usr/bin/env bash
# Forked-mainnet gate for Gilt's rate adapters. Run before any deployment.
# The local suite uses mocks and cannot see an upstream signature or contract
# change; this can.
#
# The console runs in a scratch copy holding only the fork manifest, the
# adapters and devnet settings. Clarinet keeps one deployment plan per project
# directory, so running in the repo would pick up the plan `npm test` writes
# and silently drop an adapter call.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/contracts/mainnet" "$WORK/settings"
cp Clarinet-fork.toml "$WORK/"
cp contracts/rate-source-trait.clar "$WORK/contracts/"
cp contracts/mainnet/stackingdao-rate-source.clar contracts/mainnet/stbtc-rate-source.clar "$WORK/contracts/mainnet/"
cp settings/Devnet.toml "$WORK/settings/"

HEIGHT=$(sed -n 's/^initial_height *= *//p' Clarinet-fork.toml)
echo "Mainnet state at stacks height $HEIGHT"

LOG=$(printf '(contract-call? .stackingdao-rate-source get-stx-per-ststx)\n(contract-call? .stbtc-rate-source get-stx-per-ststx)\n' \
  | (cd "$WORK" && clarinet console --manifest-path Clarinet-fork.toml 2>&1) || true)
OUT=$(printf '%s\n' "$LOG" | grep -E '^\((ok|err) ' || true)

if [ "$(printf '%s\n' "$OUT" | grep -c .)" -ne 2 ]; then
  echo "FAIL expected 2 adapter results, got:"
  printf '%s\n' "$OUT"
  echo "--- console output ---"
  printf '%s\n' "$LOG" | tail -20
  exit 1
fi

check() { # label result min max
  local v
  v=$(printf '%s' "$2" | sed -nE 's/^\(ok u([0-9]+)\)$/\1/p')
  if [ -z "$v" ] || [ "$v" -lt "$3" ] || [ "$v" -gt "$4" ]; then
    echo "FAIL $1 adapter outside band [$3, $4]: $2"
    exit 1
  fi
  printf '%-6s %s\n' "$1" "$2"
}
check stSTX "$(printf '%s\n' "$OUT" | sed -n 1p)" 1000000 3000000
check stBTC "$(printf '%s\n' "$OUT" | sed -n 2p)" 100000000 300000000
echo
echo "OK  both adapters read mainnet and returned rates in band"
