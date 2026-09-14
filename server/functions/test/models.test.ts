import { describe, expect, it } from "vitest";
import { allModels, defaultModel, modelById, publicCatalog } from "../src/models";
import {
  ALL_PRODUCTS,
  CONSUMABLE_PRODUCTS,
  creditsForProduct,
  planForEntitlement,
  planForProduct,
  SUBSCRIPTION_PRODUCTS,
} from "../src/storeProducts";
import { MODEL_TIER_RANK } from "../src/plans";

describe("model catalog", () => {
  it("has unique model ids", () => {
    const ids = allModels().map((model) => model.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("resolves a default model that exists in the catalog", () => {
    const fallback = defaultModel();
    expect(fallback).toBeDefined();
    expect(modelById(fallback.id)?.id).toBe(fallback.id);
  });

  it("derives tiers consistent with the price rule", () => {
    for (const model of allModels()) {
      if (model.isFree) {
        expect(model.tier).toBe("flash");
        continue;
      }
      const perMillion = model.promptPricePerToken * 1_000_000;
      const expected = perMillion < 1 ? "flash" : perMillion <= 5 ? "plus" : "max";
      expect(
        model.tier,
        `${model.id} at $${perMillion}/M should be ${expected}`,
      ).toBe(expected);
    }
  });

  it("keeps the capability the plan gating depends on", () => {
    // Every catalogue entry must map to a known tier rank, or gating breaks.
    for (const model of allModels()) {
      expect(MODEL_TIER_RANK[model.tier]).toBeTypeOf("number");
    }
  });

  it("does not expose tier overrides that contradict the plan ladder", () => {
    // All three tiers should be reachable, otherwise a plan buys nothing.
    const tiers = new Set(allModels().map((model) => model.tier));
    expect(tiers.has("flash")).toBe(true);
    expect(tiers.has("plus")).toBe(true);
    expect(tiers.has("max")).toBe(true);
  });

  it("returns an unknown id as undefined instead of throwing", () => {
    expect(modelById("does/not-exist")).toBeUndefined();
  });

  it("exposes a public catalog with the fields the client needs", () => {
    const [first] = publicCatalog();
    expect(first).toBeDefined();
    for (const key of ["id", "name", "provider", "tier", "isFree"]) {
      expect(first).toHaveProperty(key);
    }
  });
});

describe("store products", () => {
  it("maps every subscription product to a plan", () => {
    expect(planForProduct("com.obdiag.plus.monthly")).toBe("plus");
    expect(planForProduct("com.obdiag.plus.yearly")).toBe("plus");
    expect(planForProduct("com.obdiag.pro.monthly")).toBe("pro");
    expect(planForProduct("com.obdiag.pro.yearly")).toBe("pro");
    expect(planForProduct("com.obdiag.credits.500")).toBeNull();
  });

  it("maps every consumable to a credit amount", () => {
    expect(creditsForProduct("com.obdiag.credits.500")).toBe(500);
    expect(creditsForProduct("com.obdiag.credits.1500")).toBe(1_500);
    expect(creditsForProduct("com.obdiag.credits.4000")).toBe(4_000);
    expect(creditsForProduct("com.obdiag.plus.monthly")).toBeNull();
  });

  it("keeps subscription and consumable namespaces disjoint", () => {
    const overlap = Object.keys(SUBSCRIPTION_PRODUCTS).filter((id) =>
      Object.prototype.hasOwnProperty.call(CONSUMABLE_PRODUCTS, id),
    );
    expect(overlap).toEqual([]);
  });

  it("lists every product id exactly once", () => {
    expect(new Set(ALL_PRODUCTS).size).toBe(ALL_PRODUCTS.length);
  });

  it("infers a plan from a RevenueCat entitlement identifier", () => {
    expect(planForEntitlement("plus")).toBe("plus");
    expect(planForEntitlement("pro")).toBe("pro");
    expect(planForEntitlement("OBDiag Pro")).toBe("pro");
    expect(planForEntitlement("mystery")).toBeNull();
  });

  it("treats an unknown product as valueless rather than guessing", () => {
    // Defensive: a webhook for an unmapped product must not grant credits.
    expect(creditsForProduct("com.obdiag.credits.999999")).toBeNull();
    expect(planForProduct("com.obdiag.unknown")).toBeNull();
  });
});
