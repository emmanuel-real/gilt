import { Cl } from "@stacks/transactions";
import { describe, expect, it } from "vitest";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!;
const wallet2 = accounts.get("wallet_2")!;
const wallet3 = accounts.get("wallet_3")!;

const DENOM = 1_000_000n;
const BPS = 10_000n;
const R_A = 1_185_000; // entry rate for the first deposit
const R_B = 1_186_000; // the live rate after StackingDAO's next update
const RATE_BPS = 50; // 0.5% for a deposit held the full term
const DEPOSIT = 1_000_000_000n; // 1,000 stSTX

const ststx = Cl.contractPrincipal(deployer, "mock-ststx");
const rateSource = Cl.contractPrincipal(deployer, "mock-rate-source");
const otherSource = Cl.contractPrincipal(deployer, "mock-rate-source-2");
const notStstx = Cl.contractPrincipal(deployer, "pt-token");
const vaultId = `${deployer}.gilt-vault`;

const big = (cv: any): bigint => BigInt(cv.value);
const height = () => BigInt(simnet.burnBlockHeight);

function setRate(v: number) {
  expect(simnet.callPublicFn("mock-rate-source", "set-rate", [Cl.uint(v)], deployer).result)
    .toBeOk(Cl.bool(true));
}
function mint(who: string, v: bigint) {
  expect(simnet.callPublicFn("mock-ststx", "mint", [Cl.uint(v), Cl.principal(who)], deployer).result)
    .toBeOk(Cl.bool(true));
}
function balance(who: string): bigint {
  const r: any = simnet.callReadOnlyFn("mock-ststx", "get-balance", [Cl.principal(who)], deployer).result;
  return big(r.value);
}
function info(): Record<string, any> {
  return (simnet.callReadOnlyFn("gilt-vault", "get-info", [], deployer).result as any).value;
}

type Schedule = { start: bigint; depositEnd: bigint; maturity: bigint };

function setup(opts: { reserve?: bigint; rateBps?: number; span?: number; term?: number } = {}): Schedule {
  const reserve = opts.reserve ?? 100_000_000n;
  const rateBps = opts.rateBps ?? RATE_BPS;
  const span = opts.span ?? 50;
  const term = opts.term ?? 100;
  setRate(R_A);
  for (const w of [wallet1, wallet2, wallet3]) mint(w, 10_000_000_000n);
  const h = simnet.burnBlockHeight;
  expect(simnet.callPublicFn("gilt-vault", "init",
    [ststx, rateSource, Cl.uint(DENOM), Cl.uint(rateBps), Cl.uint(h + span), Cl.uint(h + term)],
    deployer).result).toBeOk(Cl.bool(true));
  if (reserve > 0n) {
    mint(deployer, reserve);
    expect(simnet.callPublicFn("gilt-vault", "fund-reserve", [Cl.uint(reserve), ststx], deployer).result)
      .toBeOk(Cl.uint(reserve));
  }
  const i = info();
  return { start: big(i["start-height"]), depositEnd: big(i["deposit-end"]), maturity: big(i.maturity) };
}

function premiumAt(s: Schedule, amount: bigint, at: bigint, rateBps = BigInt(RATE_BPS)): bigint {
  const remaining = s.maturity > at ? s.maturity - at : 0n;
  return (amount * rateBps * remaining) / (BPS * (s.maturity - s.start));
}
function payoutOf(amount: bigint, premium: bigint, entry: bigint, settleRate: bigint): bigint {
  const effective = settleRate > entry ? settleRate : entry;
  return ((amount + premium) * entry) / effective;
}
function noteTuple(id: bigint, amount: bigint, rate: bigint, premium: bigint) {
  return Cl.tuple({
    "note-id": Cl.uint(id),
    "entry-rate": Cl.uint(rate),
    "premium-ststx": Cl.uint(premium),
    "principal-stx": Cl.uint((amount * rate) / DENOM),
    "payout-stx": Cl.uint(((amount + premium) * rate) / DENOM),
  });
}

const deposit = (who: string, amount: bigint = DEPOSIT, source = rateSource, token = ststx) =>
  simnet.callPublicFn("gilt-vault", "deposit", [Cl.uint(amount), token, source], who);
const settle = (source = rateSource) =>
  simnet.callPublicFn("gilt-vault", "settle", [source], wallet3);
const redeem = (who: string, id: bigint | number) =>
  simnet.callPublicFn("gilt-vault", "redeem", [Cl.uint(id), ststx], who);
const withdraw = (v: bigint) =>
  simnet.callPublicFn("gilt-vault", "withdraw-surplus", [Cl.uint(v), ststx], deployer);

function matureAndSettle(s: Schedule, rate: number) {
  const gap = Number(s.maturity - height());
  if (gap > 0) simnet.mineEmptyBurnBlocks(gap);
  setRate(rate);
  expect(settle().result).toBeOk(Cl.uint(rate));
}

describe("the bug this redesign fixes", () => {
  it("still accepts deposits after StackingDAO updates the live rate", () => {
    // The old vault routed deposits through gilt-series split, which refuses
    // once the rate moves. StackingDAO moves it about every 12 hours.
    const s = setup();
    const p = premiumAt(s, DEPOSIT, height());
    expect(deposit(wallet1).result).toBeOk(noteTuple(1n, DEPOSIT, BigInt(R_A), p));
    setRate(R_B);
    expect(deposit(wallet2).result).toBeOk(noteTuple(2n, DEPOSIT, BigInt(R_B), p));
  });

  it("records each note's own entry rate and owner", () => {
    setup();
    deposit(wallet1);
    setRate(R_B);
    deposit(wallet2);
    const n1: any = simnet.callReadOnlyFn("gilt-vault", "get-note", [Cl.uint(1)], deployer).result;
    const n2: any = simnet.callReadOnlyFn("gilt-vault", "get-note", [Cl.uint(2)], deployer).result;
    expect(big(n1.value.value["entry-rate"])).toBe(BigInt(R_A));
    expect(big(n2.value.value["entry-rate"])).toBe(BigInt(R_B));
    expect(n1.value.value.owner.value).toBe(wallet1);
    expect(n2.value.value.owner.value).toBe(wallet2);
  });
});

describe("the fixed return is pro-rated to time locked", () => {
  it("pays a late depositor proportionally less premium", () => {
    const s = setup();
    const early = premiumAt(s, DEPOSIT, height());
    expect(deposit(wallet1).result).toBeOk(noteTuple(1n, DEPOSIT, BigInt(R_A), early));
    simnet.mineEmptyBurnBlocks(30);
    const late = premiumAt(s, DEPOSIT, height());
    expect(deposit(wallet2).result).toBeOk(noteTuple(2n, DEPOSIT, BigInt(R_A), late));
    expect(late < early).toBe(true);
    expect(late * (s.maturity - s.start)).toBe(early * (s.maturity - height()));
  });

  it("closes deposits at the deadline", () => {
    const s = setup();
    simnet.mineEmptyBurnBlocks(Number(s.depositEnd - height()));
    expect(deposit(wallet1).result).toBeErr(Cl.uint(315));
  });
});

describe("capacity: open premiums never exceed the reserve", () => {
  it("accepts a deposit up to the reserve and refuses anything beyond", () => {
    const s = setup({ reserve: 5_000_000n });
    expect(premiumAt(s, DEPOSIT, height())).toBe(5_000_000n);
    expect(deposit(wallet1).result).toBeOk(expect.anything());
    expect(deposit(wallet2, 1_000_000n).result).toBeErr(Cl.uint(306));
  });

  it("reports remaining capacity", () => {
    const s = setup();
    const cap = () => simnet.callReadOnlyFn("gilt-vault", "get-remaining-capacity", [], deployer).result;
    expect(cap()).toBeUint(100_000_000n);
    const p = premiumAt(s, DEPOSIT, height());
    deposit(wallet1);
    expect(cap()).toBeUint(100_000_000n - p);
  });
});

describe("payouts", () => {
  it("pays the promised STX value when stSTX accrues past the entry rate", () => {
    const s = setup();
    const p = premiumAt(s, DEPOSIT, height());
    deposit(wallet1);
    matureAndSettle(s, 1_200_000);
    const expected = payoutOf(DEPOSIT, p, BigInt(R_A), 1_200_000n);
    const before = balance(wallet1);
    expect(redeem(wallet1, 1).result).toBeOk(Cl.uint(expected));
    expect(balance(wallet1) - before).toBe(expected);
    const promise = ((DEPOSIT + p) * BigInt(R_A)) / DENOM;
    const worth = (expected * 1_200_000n) / DENOM;
    expect(promise - worth <= 2n).toBe(true);
  });

  it("pays deposit plus premium in stSTX when stSTX earns nothing, from reserve", () => {
    const s = setup();
    const p = premiumAt(s, DEPOSIT, height());
    deposit(wallet1);
    matureAndSettle(s, R_A);
    expect(redeem(wallet1, 1).result).toBeOk(Cl.uint(DEPOSIT + p));
    expect(balance(vaultId)).toBe(100_000_000n - p);
  });

  it("never pays more than deposit plus premium when the rate dips below entry", () => {
    const s = setup();
    const p = premiumAt(s, DEPOSIT, height());
    deposit(wallet1);
    matureAndSettle(s, 1_180_000);
    expect(redeem(wallet1, 1).result).toBeOk(Cl.uint(DEPOSIT + p));
  });

  it("settles notes with different entry rates against one settlement rate", () => {
    const s = setup();
    const p = premiumAt(s, DEPOSIT, height());
    deposit(wallet1);
    setRate(R_B);
    deposit(wallet2);
    matureAndSettle(s, 1_185_500); // above note 1's entry, below note 2's
    expect(redeem(wallet1, 1).result).toBeOk(Cl.uint(payoutOf(DEPOSIT, p, BigInt(R_A), 1_185_500n)));
    expect(redeem(wallet2, 2).result).toBeOk(Cl.uint(DEPOSIT + p));
  });

  it("preview-deposit matches what a deposit records", () => {
    setup();
    const preview = simnet.callReadOnlyFn("gilt-vault", "preview-deposit",
      [Cl.uint(DEPOSIT), Cl.uint(R_A)], deployer).result;
    const r: any = deposit(wallet1).result;
    expect(preview).toEqual(Cl.tuple({
      "premium-ststx": r.value.value["premium-ststx"],
      "principal-stx": r.value.value["principal-stx"],
      "payout-stx": r.value.value["payout-stx"],
    }));
  });
});

describe("solvency across randomised scenarios", () => {
  for (const seed of [1, 2, 3, 4, 5, 6, 7, 8]) {
    it(`seed ${seed}: never owes more than it holds`, () => {
      let x = (seed * 2654435761) % 4294967296;
      const rnd = (n: number) => {
        x = (x * 1664525 + 1013904223) % 4294967296;
        return x % n;
      };
      const reserve = BigInt(20 + rnd(200)) * 1_000_000n;
      const rateBps = 10 + rnd(290);
      const s = setup({ reserve, rateBps });
      const owners = [wallet1, wallet2, wallet3];
      const notes: { id: bigint; owner: string; amount: bigint; premium: bigint; entry: bigint }[] = [];
      let rate = R_A;
      let deposited = 0n;

      for (let k = 0; k < 8; k++) {
        const step = rnd(6);
        if (step > 0 && height() + BigInt(step) < s.depositEnd) simnet.mineEmptyBurnBlocks(step);
        rate = Math.max(1_000_000, rate + rnd(2300) - 300); // mostly up, sometimes a dip
        setRate(rate);
        const owner = owners[k % 3];
        const amount = BigInt(1 + rnd(400)) * 1_000_000n;
        const premium = premiumAt(s, amount, height(), BigInt(rateBps));
        const r: any = deposit(owner, amount).result;
        if (r.type === "err") {
          expect(r).toBeErr(Cl.uint(306)); // the only acceptable refusal is capacity
          continue;
        }
        expect(big(r.value.value["premium-ststx"])).toBe(premium);
        notes.push({ id: big(r.value.value["note-id"]), owner, amount, premium, entry: BigInt(rate) });
        deposited += amount;
      }

      const premiums = notes.reduce((a, n) => a + n.premium, 0n);
      expect(premiums <= reserve).toBe(true);

      const entries = notes.map((n) => Number(n.entry));
      const lo = Math.min(R_A, ...entries);
      const hi = Math.max(R_A, ...entries);
      const settleRate = Math.max(1_000_000, lo - 3_000 + rnd(hi - lo + 43_000));
      matureAndSettle(s, settleRate);

      const held = balance(vaultId);
      expect(held).toBe(deposited + reserve);
      let paid = 0n;
      for (const n of notes) {
        const expected = payoutOf(n.amount, n.premium, n.entry, BigInt(settleRate));
        expect(redeem(n.owner, n.id).result).toBeOk(Cl.uint(expected));
        expect(expected <= n.amount + n.premium).toBe(true);
        if (BigInt(settleRate) >= n.entry) {
          // delivers the promised STX value, less at most one unit of rounding
          expect(expected * BigInt(settleRate) + BigInt(settleRate) >= (n.amount + n.premium) * n.entry)
            .toBe(true);
        }
        paid += expected;
      }
      expect(paid <= held).toBe(true);
      expect(balance(vaultId)).toBe(held - paid);
      const after = info();
      expect(big(after.committed)).toBe(0n);
      expect(big(after["notes-outstanding"])).toBe(0n);
    });
  }
});

describe("guards", () => {
  it("validates init", () => {
    const h = simnet.burnBlockHeight;
    const init = (sender: string, rateBps: number, denom: bigint, end: number, mat: number) =>
      simnet.callPublicFn("gilt-vault", "init",
        [ststx, rateSource, Cl.uint(denom), Cl.uint(rateBps), Cl.uint(end), Cl.uint(mat)], sender).result;
    expect(init(wallet1, 50, DENOM, h + 50, h + 100)).toBeErr(Cl.uint(300));
    expect(init(deployer, 2001, DENOM, h + 50, h + 100)).toBeErr(Cl.uint(304));
    expect(init(deployer, 50, 1_000n, h + 50, h + 100)).toBeErr(Cl.uint(319));
    expect(init(deployer, 50, DENOM, h, h + 100)).toBeErr(Cl.uint(314));
    expect(init(deployer, 50, DENOM, h + 50, h + 50)).toBeErr(Cl.uint(314));
    expect(init(deployer, 50, DENOM, h + 50, h + 100)).toBeOk(Cl.bool(true));
    expect(init(deployer, 50, DENOM, h + 50, h + 100)).toBeErr(Cl.uint(301));
  });

  it("guards deposits", () => {
    mint(wallet1, 10_000_000_000n);
    expect(deposit(wallet1).result).toBeErr(Cl.uint(302));
    setup();
    expect(deposit(wallet1, DEPOSIT, rateSource, notStstx).result).toBeErr(Cl.uint(303));
    expect(deposit(wallet1, DEPOSIT, otherSource).result).toBeErr(Cl.uint(313));
    expect(deposit(wallet1, 999_999n).result).toBeErr(Cl.uint(305));
    simnet.callPublicFn("gilt-vault", "set-closed", [Cl.bool(true)], deployer);
    expect(deposit(wallet1).result).toBeErr(Cl.uint(310));
    simnet.callPublicFn("gilt-vault", "set-closed", [Cl.bool(false)], deployer);
    expect(deposit(wallet1).result).toBeOk(expect.anything());
  });

  it("guards settlement", () => {
    const s = setup();
    expect(settle().result).toBeErr(Cl.uint(316));
    simnet.mineEmptyBurnBlocks(Number(s.maturity - height()));
    expect(settle(otherSource).result).toBeErr(Cl.uint(313));
    expect(settle().result).toBeOk(Cl.uint(R_A)); // anyone can settle
    expect(settle().result).toBeErr(Cl.uint(317));
  });

  it("guards redemption", () => {
    const s = setup();
    deposit(wallet1);
    expect(redeem(wallet1, 1).result).toBeErr(Cl.uint(308));
    matureAndSettle(s, 1_200_000);
    expect(redeem(wallet2, 1).result).toBeErr(Cl.uint(318));
    expect(redeem(wallet1, 99).result).toBeErr(Cl.uint(307));
    expect(redeem(wallet1, 1).result).toBeOk(expect.anything());
    expect(redeem(wallet1, 1).result).toBeErr(Cl.uint(309));
  });

  it("guards the reserve and admin calls", () => {
    expect(simnet.callPublicFn("gilt-vault", "fund-reserve", [Cl.uint(1), ststx], deployer).result)
      .toBeErr(Cl.uint(302));
    setup();
    expect(simnet.callPublicFn("gilt-vault", "fund-reserve", [Cl.uint(0), ststx], deployer).result)
      .toBeErr(Cl.uint(312));
    expect(simnet.callPublicFn("gilt-vault", "withdraw-surplus", [Cl.uint(1), ststx], wallet1).result)
      .toBeErr(Cl.uint(300));
    expect(simnet.callPublicFn("gilt-vault", "set-closed", [Cl.bool(true)], wallet1).result)
      .toBeErr(Cl.uint(300));
    expect(withdraw(100_000_001n).result).toBeErr(Cl.uint(321));
  });
});

describe("the reserve cannot be pulled out from under depositors", () => {
  it("blocks withdrawal while notes are open and allows it once every note is redeemed", () => {
    const s = setup();
    deposit(wallet1);
    expect(withdraw(1_000_000n).result).toBeErr(Cl.uint(311));
    matureAndSettle(s, 1_200_000);
    redeem(wallet1, 1);
    const left = balance(vaultId);
    expect(withdraw(left).result).toBeOk(Cl.uint(left));
    expect(balance(vaultId)).toBe(0n);
  });

  it("resets the recorded reserve on withdrawal, so capacity cannot count stSTX that left", () => {
    // Regression: the old vault kept the reserve figure after a withdrawal,
    // so a later deposit could be backed by stSTX that was no longer there.
    setup();
    expect(withdraw(100_000_000n).result).toBeOk(Cl.uint(100_000_000n));
    expect(big(info().reserve)).toBe(0n);
    expect(deposit(wallet1).result).toBeErr(Cl.uint(306));
  });
});
