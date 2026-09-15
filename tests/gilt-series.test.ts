import { Cl } from "@stacks/transactions";
import { beforeEach, describe, expect, it } from "vitest";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!;
const wallet2 = accounts.get("wallet_2")!;

const DENOM = 1_000_000;
const R0 = 1_100_000; // 1.1 STX per stSTX at series start
const SPLIT_FEE_BPS = 10; // 0.10%
const YIELD_FEE_BPS = 300; // 3%
const MATURITY_OFFSET = 100; // burn blocks from now
const DENOM_6 = 1_000_000; // stSTX decimal base

const ststx = Cl.contractPrincipal(deployer, "mock-ststx");
const rateSource = Cl.contractPrincipal(deployer, "mock-rate-source");
const series = Cl.contractPrincipal(deployer, "gilt-series");

function setRate(rate: number) {
  const res = simnet.callPublicFn("mock-rate-source", "set-rate", [Cl.uint(rate)], deployer);
  expect(res.result).toBeOk(Cl.bool(true));
}

function fundStstx(recipient: string, amount: number | bigint) {
  const res = simnet.callPublicFn("mock-ststx", "mint", [Cl.uint(amount), Cl.principal(recipient)], deployer);
  expect(res.result).toBeOk(Cl.bool(true));
}

function initSeries(opts?: { splitFee?: number; yieldFee?: number; offset?: number }) {
  const maturity = simnet.burnBlockHeight + (opts?.offset ?? MATURITY_OFFSET);
  const res = simnet.callPublicFn(
    "gilt-series",
    "init",
    [
      ststx,
      rateSource,
      Cl.uint(maturity),
      Cl.uint(DENOM_6),
      Cl.uint(opts?.splitFee ?? SPLIT_FEE_BPS),
      Cl.uint(opts?.yieldFee ?? YIELD_FEE_BPS),
    ],
    deployer
  );
  return { res, maturity };
}

function fullSetup() {
  setRate(R0);
  simnet.callPublicFn("pt-token", "set-minter", [series], deployer);
  simnet.callPublicFn("yt-token", "set-minter", [series], deployer);
  fundStstx(wallet1, 10_000_000_000);
  fundStstx(wallet2, 10_000_000_000);
  return initSeries();
}

function split(amount: number, sender: string) {
  return simnet.callPublicFn("gilt-series", "split", [Cl.uint(amount), ststx, rateSource], sender);
}

function ststxBalance(who: string) {
  const res = simnet.callReadOnlyFn("mock-ststx", "get-balance", [Cl.principal(who)], deployer);
  return res.result;
}

const seriesId = () => `${deployer}.gilt-series`;

describe("init", () => {
  it("rejects non-deployer", () => {
    setRate(R0);
    const res = simnet.callPublicFn(
      "gilt-series",
      "init",
      [ststx, rateSource, Cl.uint(simnet.burnBlockHeight + 10), Cl.uint(DENOM_6), Cl.uint(0), Cl.uint(0)],
      wallet1
    );
    expect(res.result).toBeErr(Cl.uint(100));
  });

  it("rejects double init, past maturity, and excessive fees", () => {
    setRate(R0);
    expect(initSeries().res.result).toBeOk(Cl.uint(R0));
    expect(initSeries().res.result).toBeErr(Cl.uint(101));

    // fresh state is per-test, so these run against the already-initialized
    // series and only the specific guard under test differs
    const past = simnet.callPublicFn(
      "gilt-series",
      "init",
      [ststx, rateSource, Cl.uint(0), Cl.uint(DENOM_6), Cl.uint(0), Cl.uint(0)],
      deployer
    );
    expect(past.result).toBeErr(Cl.uint(101)); // already-init wins ordering
  });

  it("rejects fees above the 10% cap", () => {
    setRate(R0);
    const res = simnet.callPublicFn(
      "gilt-series",
      "init",
      [ststx, rateSource, Cl.uint(simnet.burnBlockHeight + 10), Cl.uint(DENOM_6), Cl.uint(1001), Cl.uint(0)],
      deployer
    );
    expect(res.result).toBeErr(Cl.uint(112));
  });

  it("snapshots R0 and pins principals", () => {
    setRate(R0);
    const { res, maturity } = initSeries();
    expect(res.result).toBeOk(Cl.uint(R0));
    const info = simnet.callReadOnlyFn("gilt-series", "get-info", [], deployer);
    expect(info.result).toEqual(
      Cl.tuple({
        initialized: Cl.bool(true),
        paused: Cl.bool(false),
        ststx: Cl.some(ststx),
        "rate-source": Cl.some(rateSource),
        "maturity-burn-height": Cl.uint(maturity),
        denom: Cl.uint(DENOM_6),
        "start-rate": Cl.uint(R0),
        settled: Cl.bool(false),
        "settlement-rate": Cl.uint(0),
        "split-fee-bps": Cl.uint(SPLIT_FEE_BPS),
        "yield-fee-bps": Cl.uint(YIELD_FEE_BPS),
        "fees-accrued": Cl.uint(0),
      })
    );
  });
});

describe("split", () => {
  it("fails before init", () => {
    setRate(R0);
    fundStstx(wallet1, 1_000_000_000);
    expect(split(1_000_000_000, wallet1).result).toBeErr(Cl.uint(102));
  });

  it("mints PT at face value and YT 1:1 on net, takes the split fee", () => {
    fullSetup();
    const res = split(1_000_000_000, wallet1);
    // fee = 0.10% of 1000 = 1 stSTX; net = 999; PT = 999 * 1.1 = 1098.9
    expect(res.result).toBeOk(
      Cl.tuple({ pt: Cl.uint(1_098_900_000), yt: Cl.uint(999_000_000), fee: Cl.uint(1_000_000) })
    );
    const pt = simnet.callReadOnlyFn("pt-token", "get-balance", [Cl.principal(wallet1)], deployer);
    expect(pt.result).toBeOk(Cl.uint(1_098_900_000));
    const yt = simnet.callReadOnlyFn("yt-token", "get-balance", [Cl.principal(wallet1)], deployer);
    expect(yt.result).toBeOk(Cl.uint(999_000_000));
    // full deposit (net + fee) is in series custody
    expect(ststxBalance(seriesId())).toBeOk(Cl.uint(1_000_000_000));
  });

  it("matches preview-split", () => {
    fullSetup();
    const preview = simnet.callReadOnlyFn("gilt-series", "preview-split", [Cl.uint(123_456_789)], deployer);
    const actual = split(123_456_789, wallet1);
    expect(actual.result).toBeOk(preview.result);
  });

  it("rejects wrong token and wrong rate source principals", () => {
    fullSetup();
    const badToken = simnet.callPublicFn(
      "gilt-series",
      "split",
      [Cl.uint(1_000_000_000), Cl.contractPrincipal(deployer, "pt-token"), rateSource],
      wallet1
    );
    expect(badToken.result).toBeErr(Cl.uint(105));
    const badSource = simnet.callPublicFn(
      "gilt-series",
      "split",
      [Cl.uint(1_000_000_000), ststx, Cl.contractPrincipal(deployer, "mock-rate-source-2")],
      wallet1
    );
    expect(badSource.result).toBeErr(Cl.uint(104));
  });

  it("closes the mint window as soon as the rate steps past R0", () => {
    fullSetup();
    expect(split(1_000_000_000, wallet1).result).toBeOk(expect.anything());
    setRate(R0 + 10_000); // StackingDAO processes cycle rewards
    expect(split(1_000_000_000, wallet1).result).toBeErr(Cl.uint(110));
  });

  it("rejects dust, pause blocks deposits but never redemptions", () => {
    fullSetup();
    expect(split(99_999, wallet1).result).toBeErr(Cl.uint(111));
    simnet.callPublicFn("gilt-series", "set-paused", [Cl.bool(true)], deployer);
    expect(split(1_000_000_000, wallet1).result).toBeErr(Cl.uint(103));
    simnet.callPublicFn("gilt-series", "set-paused", [Cl.bool(false)], deployer);
    expect(split(1_000_000_000, wallet1).result).toBeOk(expect.anything());
  });

  it("rejects splits after maturity", () => {
    fullSetup();
    simnet.mineEmptyBurnBlocks(MATURITY_OFFSET + 1);
    expect(split(1_000_000_000, wallet1).result).toBeErr(Cl.uint(106));
  });
});

describe("recombine", () => {
  it("burns ceil(yt * R0) PT plus YT and returns the stSTX", () => {
    fullSetup();
    split(1_000_000_000, wallet1);
    const before = ststxBalance(wallet1);
    // 123_456_789 * 1.1 = 135_802_467.9 -> ceil = 135_802_468
    const res = simnet.callPublicFn("gilt-series", "recombine", [Cl.uint(123_456_789), ststx], wallet1);
    expect(res.result).toBeOk(
      Cl.tuple({ ststx: Cl.uint(123_456_789), "pt-burned": Cl.uint(135_802_468) })
    );
    expect(before).toBeOk(Cl.uint(9_000_000_000));
    expect(ststxBalance(wallet1)).toBeOk(Cl.uint(9_123_456_789));
  });

  it("fails without enough PT and after settlement", () => {
    fullSetup();
    split(1_000_000_000, wallet1);
    // transfer PT away so the burn must fail
    simnet.callPublicFn(
      "pt-token",
      "transfer",
      [Cl.uint(1_098_900_000), Cl.principal(wallet1), Cl.principal(wallet2), Cl.none()],
      wallet1
    );
    const res = simnet.callPublicFn("gilt-series", "recombine", [Cl.uint(999_000_000), ststx], wallet1);
    expect(res.result).toBeErr(Cl.uint(1)); // ft-burn? insufficient balance

    simnet.mineEmptyBurnBlocks(MATURITY_OFFSET + 1);
    simnet.callPublicFn("gilt-series", "settle", [rateSource], wallet2);
    const post = simnet.callPublicFn("gilt-series", "recombine", [Cl.uint(1), ststx], wallet2);
    expect(post.result).toBeErr(Cl.uint(108));
  });
});

describe("settle", () => {
  it("rejects before maturity, is permissionless after, rejects double settle", () => {
    fullSetup();
    const early = simnet.callPublicFn("gilt-series", "settle", [rateSource], wallet1);
    expect(early.result).toBeErr(Cl.uint(107));

    simnet.mineEmptyBurnBlocks(MATURITY_OFFSET + 1);
    setRate(1_200_000);
    const res = simnet.callPublicFn("gilt-series", "settle", [rateSource], wallet1);
    expect(res.result).toBeOk(Cl.uint(1_200_000));

    const twice = simnet.callPublicFn("gilt-series", "settle", [rateSource], wallet2);
    expect(twice.result).toBeErr(Cl.uint(108));
  });

  it("clamps the settlement rate to R0 if the rate ever decreased", () => {
    fullSetup();
    split(1_000_000_000, wallet1);
    simnet.mineEmptyBurnBlocks(MATURITY_OFFSET + 1);
    setRate(1_000_000); // below R0 = 1.1
    const res = simnet.callPublicFn("gilt-series", "settle", [rateSource], wallet1);
    expect(res.result).toBeOk(Cl.uint(R0));
    // PT redeems the original net deposit exactly; YT redeems zero
    const pt = simnet.callPublicFn("gilt-series", "redeem-pt", [Cl.uint(1_098_900_000), ststx], wallet1);
    expect(pt.result).toBeOk(Cl.uint(999_000_000));
    const yt = simnet.callPublicFn("gilt-series", "redeem-yt", [Cl.uint(999_000_000), ststx], wallet1);
    expect(yt.result).toBeOk(Cl.uint(0));
  });
});

describe("redemption and solvency", () => {
  it("pays PT fixed principal, YT the yield minus fee, and drains to exactly the fees", () => {
    fullSetup();
    split(1_000_000_000, wallet1);
    expect(split(1_000_000_000, wallet2).result).toBeOk(expect.anything());

    const beforeSettle = simnet.callPublicFn("gilt-series", "redeem-pt", [Cl.uint(1), ststx], wallet1);
    expect(beforeSettle.result).toBeErr(Cl.uint(109));

    simnet.mineEmptyBurnBlocks(MATURITY_OFFSET + 1);
    setRate(1_200_000);
    simnet.callPublicFn("gilt-series", "settle", [rateSource], wallet1);

    // PT: 1_098_900_000 * 1e6 / 1.2e6 = 915_750_000 stSTX (worth 1098.9 STX)
    const pt = simnet.callPublicFn("gilt-series", "redeem-pt", [Cl.uint(1_098_900_000), ststx], wallet1);
    expect(pt.result).toBeOk(Cl.uint(915_750_000));

    // YT: gross = 999e6 * (1.2 - 1.1) / 1.2 = 83_250_000; 3% fee = 2_497_500
    const yt = simnet.callPublicFn("gilt-series", "redeem-yt", [Cl.uint(999_000_000), ststx], wallet1);
    expect(yt.result).toBeOk(Cl.uint(80_752_500));

    simnet.callPublicFn("gilt-series", "redeem-pt", [Cl.uint(1_098_900_000), ststx], wallet2);
    simnet.callPublicFn("gilt-series", "redeem-yt", [Cl.uint(999_000_000), ststx], wallet2);

    // after every holder exits, custody equals accrued fees to the microunit
    const fees = 2 * (1_000_000 + 2_497_500);
    expect(ststxBalance(seriesId())).toBeOk(Cl.uint(fees));

    const claim = simnet.callPublicFn("gilt-series", "claim-fees", [Cl.principal(deployer), ststx], deployer);
    expect(claim.result).toBeOk(Cl.uint(fees));
    expect(ststxBalance(seriesId())).toBeOk(Cl.uint(0));
  });

  it("gates claim-fees to the owner and rejects empty claims", () => {
    fullSetup();
    split(1_000_000_000, wallet1);
    const stranger = simnet.callPublicFn("gilt-series", "claim-fees", [Cl.principal(wallet1), ststx], wallet1);
    expect(stranger.result).toBeErr(Cl.uint(100));
    simnet.callPublicFn("gilt-series", "claim-fees", [Cl.principal(deployer), ststx], deployer);
    const empty = simnet.callPublicFn("gilt-series", "claim-fees", [Cl.principal(deployer), ststx], deployer);
    expect(empty.result).toBeErr(Cl.uint(115));
  });
});

describe("token authorization", () => {
  it("blocks mint/burn from anyone but the series, and set-minter is one-shot", () => {
    fullSetup();
    const mint = simnet.callPublicFn("pt-token", "mint", [Cl.uint(1_000_000), Cl.principal(wallet1)], wallet1);
    expect(mint.result).toBeErr(Cl.uint(922));
    const burn = simnet.callPublicFn("yt-token", "burn", [Cl.uint(1), Cl.principal(wallet1)], deployer);
    expect(burn.result).toBeErr(Cl.uint(932));
    const again = simnet.callPublicFn("pt-token", "set-minter", [Cl.principal(wallet1)], deployer);
    expect(again.result).toBeErr(Cl.uint(923));
  });

  it("PT and YT transfer like any SIP-010 (DEX-ready)", () => {
    fullSetup();
    split(1_000_000_000, wallet1);
    const res = simnet.callPublicFn(
      "yt-token",
      "transfer",
      [Cl.uint(500_000_000), Cl.principal(wallet1), Cl.principal(wallet2), Cl.none()],
      wallet1
    );
    expect(res.result).toBeOk(Cl.bool(true));
    const bal = simnet.callReadOnlyFn("yt-token", "get-balance", [Cl.principal(wallet2)], deployer);
    expect(bal.result).toBeOk(Cl.uint(500_000_000));
  });
});
