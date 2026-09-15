import { describe, expect, it } from "vitest";
import {
  creditsForTokens,
  estimateCredits,
  estimateTokens,
  isPlanTier,
  MODEL_TIER_MULTIPLIER,
  MODEL_TIER_RANK,
  planConfig,
  tierForPrice,
  TOKENS_PER_CREDIT,
} from "../src/plans";

describe("tierForPrice", () => {
  it("puts sub-$1/M models in Flash", () => {
    expect(tierForPrice(0.75e-6)).toBe("flash"); // $0.75/M
    expect(tierForPrice(0.2e-6)).toBe("flash");
    expect(tierForPrice(0.15e-6)).toBe("flash");
  });

  it("puts $1–5/M models in Plus, inclusive of the boundary", () => {
    expect(tierForPrice(1.0e-6)).toBe("plus");
    expect(tierForPrice(2.5e-6)).toBe("plus");
    expect(tierForPrice(5.0e-6)).toBe("plus");
  });

  it("puts above-$5/M models in Max", () => {
    expect(tierForPrice(5.01e-6)).toBe("max");
    expect(tierForPrice(10e-6)).toBe("max");
  });

  it("treats free models as Flash regardless of price", () => {
    expect(tierForPrice(0, true)).toBe("flash");
    expect(tierForPrice(50e-6, true)).toBe("flash");
  });
});

describe("creditsForTokens", () => {
  it("bills 1 credit per 1,000 tokens at the base rate", () => {
    expect(TOKENS_PER_CREDIT).toBe(1_000);
    expect(creditsForTokens(1_000, "plus")).toBe(1);
    expect(creditsForTokens(5_000, "plus")).toBe(5);
  });

  it("bills Flash at a third of the base rate", () => {
    expect(MODEL_TIER_MULTIPLIER.flash).toBe(0.33);
    // 3,000 tokens → 3 × 0.33 = 0.99 → ceil 1
    expect(creditsForTokens(3_000, "flash")).toBe(1);
    // 10,000 tokens → 10 × 0.33 = 3.3 → ceil 4
    expect(creditsForTokens(10_000, "flash")).toBe(4);
  });

  it("bills Max at 5x the base rate", () => {
    expect(MODEL_TIER_MULTIPLIER.max).toBe(5);
    expect(creditsForTokens(1_000, "max")).toBe(5);
    expect(creditsForTokens(3_800, "max")).toBe(19);
  });

  it("rounds up and enforces a minimum charge", () => {
    // A tiny Flash request would floor to 0 without the minimum.
    expect(creditsForTokens(100, "flash")).toBe(1);
    // 1,500 tokens on Plus = 1.5 → 2
    expect(creditsForTokens(1_500, "plus")).toBe(2);
  });

  it("charges nothing for zero or negative tokens", () => {
    expect(creditsForTokens(0, "plus")).toBe(0);
    expect(creditsForTokens(-100, "plus")).toBe(0);
    expect(creditsForTokens(Number.NaN, "plus")).toBe(0);
  });

  it("orders tiers by cost: flash < plus < max for the same tokens", () => {
    const tokens = 10_000;
    expect(creditsForTokens(tokens, "flash")).toBeLessThan(
      creditsForTokens(tokens, "plus"),
    );
    expect(creditsForTokens(tokens, "plus")).toBeLessThan(
      creditsForTokens(tokens, "max"),
    );
  });
});

describe("estimateCredits", () => {
  it("reserves prompt plus max output so the hold covers the real charge", () => {
    const tier = "plus" as const;
    const hold = estimateCredits({ tier, promptTokens: 1_000, maxOutputTokens: 2_000 });
    const actual = creditsForTokens(2_500, tier);
    expect(hold).toBeGreaterThanOrEqual(actual);
  });

  it("scales with the tier multiplier", () => {
    const base = { promptTokens: 1_000, maxOutputTokens: 1_000 };
    expect(estimateCredits({ ...base, tier: "flash" })).toBeLessThan(
      estimateCredits({ ...base, tier: "plus" }),
    );
    expect(estimateCredits({ ...base, tier: "plus" })).toBeLessThan(
      estimateCredits({ ...base, tier: "max" }),
    );
  });
});

describe("plan gating", () => {
  it("orders model tiers flash < plus < max", () => {
    expect(MODEL_TIER_RANK.flash).toBeLessThan(MODEL_TIER_RANK.plus);
    expect(MODEL_TIER_RANK.plus).toBeLessThan(MODEL_TIER_RANK.max);
  });

  it("limits free to flash and pro to max", () => {
    expect(planConfig("free").maxModelTier).toBe("flash");
    expect(planConfig("plus").maxModelTier).toBe("plus");
    expect(planConfig("pro").maxModelTier).toBe("max");
  });

  it("gives higher plans more credits", () => {
    expect(planConfig("free").monthlyCredits).toBeLessThan(
      planConfig("plus").monthlyCredits,
    );
    expect(planConfig("plus").monthlyCredits).toBeLessThan(
      planConfig("pro").monthlyCredits,
    );
  });

  it("validates plan tiers", () => {
    expect(isPlanTier("free")).toBe(true);
    expect(isPlanTier("pro")).toBe(true);
    expect(isPlanTier("enterprise")).toBe(false);
    expect(isPlanTier(null)).toBe(false);
  });
});

describe("estimateTokens", () => {
  it("approximates four characters per token", () => {
    expect(estimateTokens("")).toBe(0);
    expect(estimateTokens("abcd")).toBe(1);
    expect(estimateTokens("a".repeat(400))).toBe(100);
  });
});
