#!/usr/bin/env bash
# Verify Gilt's rate sources against LIVE mainnet state.
#
# The StackingDAO v4 contracts are Clarity 6 and cannot be pulled into the
# Clarinet project as requirements (see docs/MAINNET-VERIFICATION.md), so this
# script reads them directly from mainnet instead. Run before any deployment.
set -euo pipefail
D=SP4SZE494VC2YC5JYG7AYFQ44F5Q4PYV7DVMDPBG
read_fn() {
  curl -s -X POST "https://api.hiro.so/v2/contracts/call-read/$D/$1/$2" \
    -H "Content-Type: application/json" \
    -d "{\"sender\":\"$D\",\"arguments\":[]}" \
  | python3 -c "
import json,sys
r=json.load(sys.stdin)
if not r.get('okay'): print('ERR', r.get('cause')); sys.exit(1)
h=r['result'][2:]
if h.startswith('07'): h=h[2:]
print(int(h[2:],16))"
}
echo "== stSTX (6 dp) =="
TOT=$(read_fn stx-reserve-v2 get-total-stx)
B1=$(read_fn ststxbtc-token get-total-supply)
B2=$(read_fn ststxbtc-token-v2 get-total-supply)
SUP=$(read_fn ststx-token get-total-supply)
python3 -c "print(f'  reserve={$TOT} ststxbtc={$B1}+{$B2} supply={$SUP}'); r=($TOT-$B1-$B2)*10**6//$SUP; print(f'  rate = u{r} = {r/1e6:.6f} STX/stSTX'); assert 900000 < r < 3000000, 'RATE OUT OF SANE RANGE'"
echo "== stBTC (8 dp) =="
TB=$(read_fn stbtc-reserve get-total-sbtc)
SB=$(read_fn stbtc-token get-total-supply)
python3 -c "print(f'  reserve={$TB} sats supply={$SB} sats'); r=$TB*10**8//$SB; print(f'  rate = u{r} = {r/1e8:.8f} BTC/stBTC'); assert 90000000 < r < 300000000, 'RATE OUT OF SANE RANGE'"
echo "OK - both rates within sane bounds"
