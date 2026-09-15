# Gilt

**Fixed-rate Bitcoin-layer yield on Stacks.** Lock stSTX for a term and receive
a known return:

    lock 1,000 stSTX for a quarter  ->  redeem stSTX worth 1,191 STX

(at a start rate of 1.1855 STX/stSTX and a 0.5% rate for the quarter. A series
must promise less than stSTX actually accrues to leave the vault a spread. On
chain, stSTX accrued about 0.65% a year during the PoX-5 bootstrap in late
August and about 4.3% a year over the week to 14 Sep 2026; StackingDAO's site
displays 6.21%. The rate is set per series, with a 20% hard ceiling in the
contract; the 3% in the test suite is a test constant, not a product rate.)

The vault holds the deposited stSTX and takes the floating side itself, so a
depositor never has to find a speculator to trade against: the decision is
one-sided. A separate split engine (`gilt-series`) turns stSTX into Principal
and Yield Tokens for anyone who wants to trade the two sides separately.

Built for the Stacks Endowment Q3 2026 cycle — *Market Efficiency & Risk*
("risk-management and hedging infrastructure") and *Bitcoin Staking & sBTC
Utility* ("Bitcoin-backed financial products"). Selling future yield forward is
a hedge; buying it is the other side of that trade.

## Status

Working prototype:

- 4 core contracts — `gilt-vault` (the product), `gilt-series` (the split
  engine), `pt-token`, `yt-token` — plus a rate-source trait and canonical
  adapters for stSTX and stBTC
- 45-test Clarinet suite, all green, including randomised solvency runs
- A forked-mainnet gate (`./scripts/fork-check.sh`) that runs the real adapters
  against live StackingDAO state
- No AMM, no price oracle, no liquidations anywhere in the design

Launch asset is **stSTX**: 47.2M supply and the liquid market. stBTC is a
roadmap series. Its supply reached 152.5 BTC by 5 Sep 2026, but its rate stayed
flat from 5 to 14 Sep while Bitcoin Staking capacity is whitelisted to
institutions, so there is no yield to fix against yet. The adapter is written
and gated so the series can open once stBTC accrues.

## Why the vault can promise a fixed rate safely

Each deposit becomes a note recording the depositor, the amount, the live stSTX
rate at deposit (its entry rate) and a premium:

    premium = amount x rate x blocks remaining / term blocks
    promise = (amount + premium) x entry rate                      in STX
    payout  = (amount + premium) x entry rate
              / max(settlement rate, entry rate)                   in stSTX

The premium is pro-rated to the time actually locked, so a deposit made just
before the deadline cannot collect a full term's return from the reserve.

If stSTX accrues past the note's entry rate, the payout is worth exactly the
promise. If the rate dips below entry (it can, briefly, when users queue
withdrawals), the payout is clamped to deposit plus premium in stSTX. Either
way a note takes out at most deposit plus premium, having brought the deposit
in, so the vault only needs reserve for premiums:

    sum of premiums on open notes <= reserve        checked on every deposit

That check is in stSTX, with no rate valuation at all. The operator cannot
oversell, and the reserve can only be withdrawn once no notes are open.

Deposits are priced at the live rate on purpose. StackingDAO updates the stSTX
rate about every 12 hours, and an earlier design that only accepted deposits
while the rate equalled a fixed start rate would have closed within hours of
launch. The unit tests missed it because their mock rate never moved; they now
move it between deposits.

The suite covers the hard cases: zero accrual (the premium comes out of
reserve), a rate dip below entry, notes with different entry rates settling
together, and randomised runs checking that total payouts never exceed what the
vault holds.

No oracle, no liquidation, no margin call.

## How the split engine works

Rates are 6-decimal fixed point (`u1000000` = 1.0 STX per stSTX). stSTX is
value-accruing: its STX exchange rate rises as StackingDAO compounds cycle
rewards.

```text
        R0 = rate at series init          Rm = rate at settlement (>= R0)

split(a stSTX)  ──►  PT = a·R0/1e6  (face value in micro-STX)
                     YT = a         (one YT per micro-stSTX deposited)

recombine(a)    ──►  burn ceil(a·R0/1e6) PT + a YT  ──►  a stSTX back

after maturity, settle() snapshots Rm, then:
redeem-pt(p)    ──►  p·1e6/Rm stSTX        (worth exactly p micro-STX)
redeem-yt(y)    ──►  y·(Rm−R0)/Rm stSTX    (the accrued yield)
```

Solvency is structural, not managed: PT payouts total `net·R0/Rm`, YT payouts
total `net·(Rm−R0)/Rm`, and those sum to exactly the custodied deposits. The
test suite proves it to the microunit: after every holder redeems, the
contract balance equals accrued fees exactly, and `claim-fees` drains it to
zero.

### The mint window (why there is no dilution exploit)

Continuous-mint yield protocols (Pendle) run per-holder interest indexes to stop
a late depositor from diluting accrued yield. The split engine avoids that by
only accepting a split while the live rate still equals the series start rate,
so every Yield Token in a series carries identical entitlement.

The cost is a short deposit window: StackingDAO updates the stSTX rate about
every 12 hours, so a split series fills only until the next update. That suits
a trading series seeded in one go. It does not suit a product that gathers
depositors over weeks, which is why the fixed-rate vault prices each deposit at
the live rate instead of using this engine.

### No oracle, no flash-loan surface

The exchange rate is a protocol-internal ratio of reserve backing to token
supply, published by StackingDAO. It is not a spot-market price and cannot be
moved within a transaction, so there is nothing to flash-loan against.

## Rate source

Gilt reads StackingDAO's **published** rate functions —
`data-stx-v2.get-stx-per-ststx` (6dp) and `data-stbtc-v1.get-sbtc-per-stbtc`
(8dp) — rather than deriving the rate itself. An earlier version derived it and
was **1.4% wrong**: small enough to pass a sanity band, large enough to misprice
every series. See `docs/RATE-SOURCE.md`.

Both are read-only returning a bare `uint`, which a Clarity trait cannot
express, so a thin adapter republishes each behind a dispatchable trait and
absorbs version churn. `./scripts/fork-check.sh` gates deployment against live
mainnet.

## Canonical dependencies

| Contract | Role |
| --- | --- |
| `SP4SZE494VC2YC5JYG7AYFQ44F5Q4PYV7DVMDPBG.ststx-token` | Deposit asset (mainnet init pins this) |
| `SP4SZE494VC2YC5JYG7AYFQ44F5Q4PYV7DVMDPBG.data-stx-v2` | stSTX rate — `get-stx-per-ststx` |
| `SP4SZE494VC2YC5JYG7AYFQ44F5Q4PYV7DVMDPBG.data-stbtc-v1` | stBTC rate — `get-sbtc-per-stbtc` (roadmap) |
| `SP3FBR2AGK5H9QBDH3EEN6DF8EK8JY7RX8QJ5SVTE.sip-010-trait-ft-standard` | Token trait for PT/YT/stSTX |

The series contract pins the token and rate-source principals once at `init`
and validates every trait argument against them. On mainnet the pins are the
adapters in `contracts/mainnet/`; in tests and on testnet — where StackingDAO
is not deployed — they are the mocks in this repo.

The adapters live outside the compiled set because the data contracts are
Clarity 6, which clarinet 3.23.2 cannot resolve as requirements at any epoch.
They are exercised through `Clarinet-fork.toml` with `[repl.remote_data]`
instead, which reads them without trouble.

## Repo layout

```text
contracts/
  gilt-vault.clar           the product: fixed-rate notes, reserve-capped
  gilt-series.clar          split engine: init / split / recombine / settle / redeem / fees
  pt-token.clar               SIP-010, mint/burn gated to the series (set once)
  yt-token.clar               SIP-010, mint/burn gated to the series (set once)
  rate-source-trait.clar      rate trait the series dispatches on
  mainnet/
    stackingdao-rate-source.clar  stSTX, calls data-stx-v2 (6dp)
    stbtc-rate-source.clar        stBTC, calls data-stbtc-v1 (8dp)
  mock-rate-source.clar       settable rate (tests/testnet only)
  mock-ststx.clar             mintable stSTX stand-in (tests/testnet only)
tests/
  gilt-series.test.ts       lifecycle, math, auth, edge cases, solvency
  gilt-vault.test.ts        live-rate deposits, pro-rating, capacity, payouts, randomised solvency
scripts/
  fork-check.sh               real adapters vs live mainnet -- the deploy gate
docs/
  RATE-SOURCE.md              why Gilt reads rather than derives
```

## Run it

```bash
clarinet check            # compiles the local contract set
npm install && npm test   # 45 tests
./scripts/fork-check.sh   # real adapters vs live mainnet
```

## Safety properties

- **Pause cannot trap funds** — pause gates deposits only; recombine and
  redemption are never pausable.
- **Rate-decrease clamp** — settlement clamps to `max(rate, R0)`, so PT
  redeems the original deposit exactly and YT redeems zero. This is a real
  case, not a theoretical one: the canonical rate is **not strictly
  monotonic**, because entering the withdrawal queue reduces both backing and
  active supply. The clamp is where that is handled; the adapter deliberately
  guards on a band only and never rejects a decrease.
- **Rounding always favors the pool** — payouts floor, recombine PT rounds
  up; dust accrues to the contract.
- **Fees hard-capped** at 10% (yield fee) on-chain; set once at init.
- **One-shot wiring** — token minter and series pins are set-once; no
  upgrade path can redirect user funds.

## Roadmap (post-grant)

- Series factory + registry (multiple concurrent maturities from one deploy)
- stBTC series once Bitcoin Staking capacity opens beyond whitelisted
  institutions (the adapter and 8dp support already exist)
- Seeded PT/stSTX pools on existing DEXs (Bitflow/Velar) — fixed-rate
  discovery without building an AMM
- Auto-rolling PT vault ("fixed rate forever")
- Per-holder interest indexes if continuous minting ever becomes worth the
  complexity
