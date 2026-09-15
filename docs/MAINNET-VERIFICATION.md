# Mainnet verification

All values verified against Stacks mainnet on **2026-09-01** (stacks height
8,894,945 / burn height 965,067), via `clarinet console` with
`[repl.remote_data]` and Hiro read-only calls. Reproduce with
`scripts/verify-mainnet-rates.sh`.

## The bug this caught

Gilt originally read the rate through StackingDAO's published path:

```clarity
(contract-call? 'SP4SZE...DVMDPBG.data-core-v2 get-stx-per-ststx
                'SP4SZE...DVMDPBG.reserve-v1)
```

That call **succeeds** and returns `(ok u14919)` — i.e. 0.0149 STX per stSTX.
It is off by ~78x, and it is wrong in the dangerous direction: PT face value
would have been minted at ~1.3% of its correct value. Every series would have
been catastrophically mispriced, and nothing in the contract would have
noticed, because the call returns `ok`.

Cause: `reserve-v1` is wound down. Verified directly:

| `reserve-v1` read | value |
| --- | --- |
| `get-stx-balance` | 704,168.805254 STX |
| `get-stx-stacking` | **0** |
| `get-stx-for-withdrawals` | 704,168.805254 STX |

Its entire remaining balance is earmarked for pending withdrawals and nothing
is stacking. StackingDAO migrated to a v4 architecture (`stx-reserve-v2`, plus
`stx-staker-*-v2` and `stbtc-staker-bond-1..6-v2`, registered by the
`prop-register-v4-stakers-v1` governance proposal).

`data-core-v3` does not fix it either — the v4 reserve does not satisfy the
old trait:

```
error: invalid signature for method 'get-stx-balance'
       regarding trait's specification <reserve-trait>
```

**Conclusion: never route the rate through `data-core-*`. Read the reserve and
token supply directly.**

## Correct rates (verified live)

**stSTX — 6 dp**

```
rate = (stx-reserve-v2.get-total-stx - ststxbtc-token.supply
        - ststxbtc-token-v2.supply) * 1e6 / ststx-token.supply
     = (82,938,577.016335 - 0 - 27,789,242.99151) * 1e6 / 47,197,386.669227
     = u1168482  =  1.168482 STX per stSTX
```

**stBTC — 8 dp**

```
rate = stbtc-reserve.get-total-sbtc * 1e8 / stbtc-token.supply
     = 4,000,044,072 / 3,995,356,389
     = u100117328  =  1.00117328 BTC per stBTC   (1 Sep launch-period reading, not yield)
```

## stBTC is live, but not accruing yet

> **Correction, 14 Sep 2026.** The figures in this section were read on 1 Sep,
> when stBTC supply was close to zero, and the "accruing" reading was launch
> noise. Supply reached 152.5 BTC by 5 Sep and the rate then stayed flat
> (100117333 to 100117349 over 9 days). What still holds is the token shape:
> 8 decimals, no rebasing, all yield surfacing through the exchange rate. See
> `RATE-SOURCE.md` for the measured stSTX and stBTC history.


| Fact | Value |
| --- | --- |
| `stbtc-token` | deployed, symbol `stBTC`, **8 decimals** |
| Supply | 39.95356389 stBTC |
| `stbtc-reserve` holdings | 40.00044072 BTC |
| `get-sbtc-staking` | 0 (bonds not yet stacking) |
| Exchange rate | 1.00117328 on 1 Sep (launch noise); flat near 1.0011734 from 5 to 14 Sep |

An earlier note here read a 1 sat change between two script runs as live
yield. It was not; see the correction above.

**This confirms the design premise.** `stbtc-token` is a plain SIP-010 with
`mint-for-protocol`; it does **not** rebase, so all yield surfaces through the
reserve/supply exchange rate. That is exactly the token shape Gilt splits,
so the series contract works unchanged apart from the decimal base — which is
why `init` now takes a `denom` parameter (`u1000000` for stSTX, `u100000000`
for stBTC).

## Why the mainnet adapters are not compiled

`contracts/mainnet/stackingdao-rate-source.clar` and
`contracts/mainnet/stbtc-rate-source.clar` hold the corrected logic but are
**excluded from `Clarinet.toml`**. StackingDAO's v4 contracts are **Clarity 6**,
and clarinet 3.23.2 cannot resolve them as requirements at any supported
epoch (tried 3.1, 3.4, 4.0, latest):

```
Contract ... is deployed at epoch 3.1, but dependency
'SP4SZE...DVMDPBG.stx-reserve-v2' requires epoch 3.4.
error: Clarity 6 can not be used with 3.4
```

The runtime path is fine — `[repl.remote_data]` reads those same Clarity 6
contracts without trouble, which is how the rates above were confirmed. So
this is a local static-analysis limitation, not a mainnet blocker. Revisit
when clarinet supports Clarity 6 requirements; until then
`scripts/verify-mainnet-rates.sh` is the gate, and it asserts both rates fall
in a sane band so a repeat of the `u14919` failure cannot pass silently.
