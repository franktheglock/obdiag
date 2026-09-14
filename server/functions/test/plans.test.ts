import { describe, expect, it } from "vitest";
import {
  creditsForUSD,
  estimateCredits,
  estimateTokens,
  isPlanTier,
  MODEL_TIER_RANK,
  planConfig,
  tierForPrice,
  USD_PER_CREDIT,
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

describe("creditsForUSD", () => {
  it("converts at $0.001 per credit", () => {
    // $0.01 = 10 base credits; Pro has a 1.0 multiplier.
    expect(creditsForUSD(0.01, "pro")).toBe(10);
    expect(USD_PER_CREDIT).toBe(0.001);
  });

  it("applies the plan multiplier so cheaper plans burn faster", () => {
    const usd = 0.01;
    expect(creditsForUSD(usd, "free")).toBe(15); // ×1.5
    expect(creditsForUSD(usd, "plus")).toBe(12); // ×1.2
    expect(creditsForUSD(usd, "pro")).toBe(10); // ×1.0
  });

  it("rounds up and enforces a minimum charge", () => {
    expect(creditsForUSD(0.0001, "pro")).toBe(1); // minimum, not 0.1
    expect(creditsForUSD(0.0015, "pro")).toBe(2); // ceil(1.5)
  });

  it("charges nothing for zero or negative cost", () => {
    expect(creditsForUSD(0, "pro")).toBe(0);
    expect(creditsForUSD(-5, "pro")).toBe(0);
    expect(creditsForUSD(Number.NaN, "pro")).toBe(0);
  });
});

describe("estimateCredits", () => {
  it("reserves based on max output, so it never under-reserves output", () => {
    const model = { promptPricePerToken: 2e-6, completionPricePerToken: 10e-6 };
    const cheap = estimateCredits({
      plan: "pro",
      ...model,
      promptTokens: 1_000,
      maxOutputTokens: 100,
    });
    const expensive = estimateCredits({
      plan: "pro",
      ...model,
      promptTokens: 1_000,
      maxOutputTokens: 4_000,
    });
    expect(expensive).toBeGreaterThan(cheap);
  });

  it("scales the reservation with the plan multiplier", () => {
    const base = {
      promptPricePerToken: 0,
      completionPricePerToken: 10e-6,
      promptTokens: 0,
      maxOutputTokens: 1_000,
    };
    expect(estimateCredits({ ...base, plan: "free" })).toBeGreaterThan(
      estimateCredits({ ...base, plan: "pro" }),
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

  it("gives higher plans more credits and a smaller multiplier", () => {
    expect(planConfig("free").monthlyCredits).toBeLessThan(
      planConfig("plus").monthlyCredits,
    );
    expect(planConfig("plus").monthlyCredits).toBeLessThan(
      planConfig("pro").monthlyCredits,
    );
    expect(planConfig("free").creditMultiplier).toBeGreaterThan(
      planConfig("pro").creditMultiplier,
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
