#!/usr/bin/env bash
# Read StackingDAO's published stSTX and stBTC rates from mainnet at the chain
# tip, and check they sit inside the same bands the rate adapters enforce.
#
# This calls the published functions directly. It deliberately does not
# recompute rates from reserve totals and token supplies: that derivation
# ignores pending withdrawals, escrow and pending shares, and came out about
# 1.4% low for stSTX when checked against mainnet (see docs/RATE-SOURCE.md).
set -euo pipefail

API="${HIRO_API:-https://api.hiro.so}"
D=SP4SZE494VC2YC5JYG7AYFQ44F5Q4PYV7DVMDPBG

read_uint() {  # contract function
  curl -s -X POST "$API/v2/contracts/call-read/$D/$1/$2" \
    -H "Content-Type: application/json" \
    -d "{\"sender\":\"$D\",\"arguments\":[]}" \
  | python3 -c '
import json, sys
r = json.load(sys.stdin)
if not r.get("okay"):
    sys.exit("read failed: %s" % r.get("cause"))
h = r["result"][2:]
if h.startswith("07"):  # (ok uint)
    h = h[2:]
if not h.startswith("01"):
    sys.exit("unexpected Clarity value: " + r["result"])
print(int(h[2:], 16))'
}

check() {  # name value min max decimals unit
  python3 - "$@" << 'PY'
import sys
name, unit = sys.argv[1], sys.argv[6]
value, lo, hi, dec = (int(x) for x in (sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]))
print(f"{name}: u{value} = {value / 10**dec:.{dec}f} {unit}")
if not lo <= value <= hi:
    sys.exit(f"FAIL: {name} rate outside the adapter band [{lo}, {hi}]")
PY
}

STSTX=$(read_uint data-stx-v2 get-stx-per-ststx)
STBTC=$(read_uint data-stbtc-v1 get-sbtc-per-stbtc)

check stSTX "$STSTX" 1000000 3000000 6 "STX per stSTX"
check stBTC "$STBTC" 100000000 300000000 8 "sBTC per stBTC"
echo "OK: published rates are inside the adapter bands"
