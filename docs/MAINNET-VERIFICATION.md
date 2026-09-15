# Mainnet verification

How to reproduce the mainnet checks behind Gilt's rate adapters, and what
they returned.

## Reproduce

| Check | Command | What it reads |
| --- | --- | --- |
| Live published rates | `./scripts/verify-mainnet-rates.sh` | `data-stx-v2.get-stx-per-ststx` and `data-stbtc-v1.get-sbtc-per-stbtc` at the chain tip, through the Hiro API |
| Adapters on a mainnet fork | `./scripts/fork-check.sh` | Gilt's own adapter contracts, run through `Clarinet-fork.toml` against mainnet state at stacks height 8,895,400 |

Both fail unless each rate sits inside the adapter bands: 1.0 to 3.0 STX per
stSTX (6 decimals) and 1.0 to 3.0 sBTC per stBTC (8 decimals).

## Recorded results

Live, at stacks height 8,996,294 (15 Sep 2026, 14:50 UTC):

```
stSTX: u1185633 = 1.185633 STX per stSTX
stBTC: u100117349 = 1.00117349 sBTC per stBTC
```

Fork check, pinned at stacks height 8,895,400 (1 Sep 2026):

```
stSTX adapter: (ok u1184416)
stBTC adapter: (ok u100117328)
```

The 1 Sep stBTC figure dates from stBTC's launch period, when supply was close
to zero, and is noise rather than yield. Supply reached 152.5 BTC by 5 Sep and
the rate then stayed near 1.0011734 through 14 Sep. `RATE-SOURCE.md` has the
measured history.

## Where the published rate lives

StackingDAO documents the stSTX rate as `data-stx-v2.get-stx-per-ststx` and
the stBTC rate as `data-stbtc-v1.get-sbtc-per-stbtc`. Both are read-only
functions returning a bare `uint`, and Gilt's adapters call exactly these.

Do not substitute either alternative below. Both were tried on mainnet and
both give wrong numbers.

### Deprecated path: `data-core-v2` with `reserve-v1`

```clarity
(contract-call? 'SP4SZE...DVMDPBG.data-core-v2 get-stx-per-ststx
                'SP4SZE...DVMDPBG.reserve-v1)
```

This call still succeeds. On 1 Sep 2026 it returned `(ok u14919)`, 0.0149 STX
per stSTX, about 78 times too low. Because it returns `ok`, ordinary error
handling would not catch it. `reserve-v1` has been wound down since
StackingDAO moved to its v4 contracts:

| `reserve-v1` read (1 Sep 2026) | Value |
| --- | --- |
| `get-stx-balance` | 704,168.805254 STX |
| `get-stx-stacking` | 0 |
| `get-stx-for-withdrawals` | 704,168.805254 STX |

`data-core-v3` is no way around it: the v4 reserve does not satisfy the old
reserve trait (`invalid signature for method 'get-stx-balance'`).

### Deriving the rate from reserve totals

Computing `(stx-reserve-v2 total - stSTXbtc supplies) * 1e6 / stSTX supply`
gave u1168941 at the chain tip on 15 Sep 2026, against the published u1185633:
1.41% low. The published formula also nets off pending withdrawals and live
escrow, which this derivation misses. The equivalent stBTC derivation matches
the published rate today only because stBTC has no pending withdrawals or
pending shares yet.

## stBTC token shape

| Fact | Value |
| --- | --- |
| `stbtc-token` | deployed, symbol `stBTC`, 8 decimals |
| Rebasing | none; supply changes only through `mint-for-protocol` |
| Supply | 39.95356389 stBTC on 1 Sep 2026, 152.5 BTC by 5 Sep |

stBTC does not rebase, so any yield surfaces through its exchange rate. That is
the token shape the vault and series handle, with the decimal base set per
series through the `denom` parameter.

## Why the adapters are not in the local build

The adapters live in `contracts/mainnet/` and are excluded from
`Clarinet.toml`. StackingDAO's v4 data contracts are Clarity 6, and Clarinet
could not resolve them as requirements at any supported epoch (3.1, 3.4, 4.0
and latest were tried on clarinet 3.23.2):

```
error: Clarity 6 can not be used with 3.4
```

`[repl.remote_data]` reads the same contracts at runtime without trouble, so
this is a local tooling limit rather than a mainnet one. Until Clarinet can
resolve Clarity 6 requirements, `fork-check.sh` exercises the adapters and
`verify-mainnet-rates.sh` checks the live published rates.
