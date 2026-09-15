# Rate source — decisions and evidence

Verified against mainnet 2026-09-01 / 09-02. Gate: `./scripts/fork-check.sh`.

## Gilt reads StackingDAO's published function. It does not derive the rate.

Canonical sources:

| Asset | Contract | Function | Returns |
| --- | --- | --- | --- |
| stSTX | `SP4SZE…DVMDPBG.data-stx-v2` | `get-stx-per-ststx` | bare `uint`, 6dp |
| stBTC | `SP4SZE…DVMDPBG.data-stbtc-v1` | `get-sbtc-per-stbtc` | bare `uint`, 8dp |

Live values through the fork gate: stSTX `u1184416`, stBTC `u100117328`.

## Why not derive it

An earlier version of the adapter computed the rate from `stx-reserve-v2` and
the stSTXbtc token supplies. It returned **u1168482 against the canonical
u1184418 — a 1.4% error.**

The real accounting, from `data-stx-v2`:

```clarity
claimed        = get-stx-for-ststxbtc + get-stx-for-withdrawals
active-backing = total-stx - claimed
active-supply  = ststx-supply - live-escrow
rate           = active-backing * 1e6 / active-supply
```

The derivation missed `stx-for-withdrawals` and `live-escrow` entirely, and
used the stSTXbtc *token supply* instead of the reserve's
`get-stx-for-ststxbtc`. There is also a `-up` variant, which exists because
collateral and debt must round in opposite directions.

**1.4% is the dangerous magnitude.** It is small enough to pass any sanity band
and large enough to misprice every series. A yield product that gets its own
settlement rate wrong is worthless, so Gilt defers to the team that owns the
accounting.

## Why an adapter exists at all

Both canonical functions are **read-only returning a bare `uint`**. A Clarity
trait cannot express that — `define-trait` rejects it with `invalid trait
definition` — so they cannot be reached by trait dispatch. The adapter
republishes the value behind a trait Gilt can dispatch on.

That also confines version risk. `data-core-v2` → `data-stx-v2` has already
happened once, and the superseded `reserve-v1` is **still callable and still
returns a wound-down value** (`get-stx-stacking` = 0, whole balance earmarked
for withdrawals). When StackingDAO next versions its data contract, one small
adapter is redeployed and the series contract is untouched.

## The rate is NOT strictly monotonic — do not guard on that

Tempting assumption, and wrong. Both sides of the ratio move when users enter
or leave the withdrawal queue: a request adds to `stx-for-withdrawals`
(reducing backing) and moves stSTX into escrow (reducing supply). The ratio can
therefore tick **down** slightly without anything being broken.

So the adapter guards with a **band only** — below par or implausibly high
means the source has been migrated, drained, or replaced — and never rejects a
decrease. Downside protection for PT holders lives where it belongs, in
`gilt-series`, which clamps the settlement rate to `max(rate, R0)`. A hard
monotonic rejection in the adapter would produce false failures during ordinary
withdrawal activity.

## Gate

`./scripts/fork-check.sh` runs the real adapters against live mainnet through
`[repl.remote_data]` and asserts both rates land in band. The local suite uses
mocks and cannot see an upstream signature change; this can. Run it before any
deployment.

## Update cadence and observed yield (measured 14 Sep 2026)

StackingDAO's docs state that all stSTX rewards accrue into the exchange rate
rather than being paid out, and that the ratio "updates roughly every 70
Bitcoin blocks (about every 12 hours)". Sampled from `data-stx-v2` on mainnet:

| Window | stSTX accrual, annualised |
| --- | --- |
| 29 Aug to 9 Sep (PoX-5 bootstrap, about +21 units a day) | about 0.65% |
| 7 Sep to 14 Sep (after a +433 step on 10 Sep) | 4.30% |
| 8 Aug to 14 Sep (37.6 days) | 1.59% |
| StackingDAO site, displayed | 6.21% |

### Consequences

1. **The vault's deposit window closes within about 12 hours.** `gilt-vault`
   routes every deposit through `gilt-series split`, which only accepts a split
   while the live rate equals the series start rate. With the rate updating
   roughly every 12 hours, deposits would stop within hours of launch. The unit
   tests hold the mock rate still before depositing, so they cannot see this.
   **Fixed 14 Sep 2026:** the vault now prices each deposit at the live rate and
   records the entry rate per note, and its tests move the rate between deposits.
2. **Promised rates must sit below measured accrual**, which was far below the
   displayed figure during bootstrap. Size each series from on-chain accrual,
   not the advertised APY.
3. **stBTC has no yield to fix yet.** Supply reached 152.5 BTC by 5 Sep, but the
   rate went from 100117333 to 100117349 over the next 9 days. The earlier
   1.00117328 reading dates from the launch period, when supply was close to
   zero, and reflects that noise rather than Bitcoin Staking rewards.
