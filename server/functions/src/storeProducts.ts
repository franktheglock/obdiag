/**
 * Store product identifiers, mirroring `OBDiag/Resources/StoreKit/OBDiag.storekit`
 * and `OBDiag/Core/Models/SubscriptionModels.swift`.
 *
 * These IDs must match App Store Connect exactly. The client never tells us how
 * many credits a purchase is worth — it only reports what it bought, and this
 * table decides the value.
 */

import { PlanTier } from "./plans";

export const SUBSCRIPTION_PRODUCTS: Record<string, PlanTier> = {
  "com.obdiag.plus.monthly": "plus",
  "com.obdiag.plus.yearly": "plus",
  "com.obdiag.pro.monthly": "pro",
  "com.obdiag.pro.yearly": "pro",
};

export const CONSUMABLE_PRODUCTS: Record<string, number> = {
  "com.obdiag.credits.500": 500,
  "com.obdiag.credits.1500": 1_500,
  "com.obdiag.credits.4000": 4_000,
};

export const ALL_PRODUCTS = [
  ...Object.keys(SUBSCRIPTION_PRODUCTS),
  ...Object.keys(CONSUMABLE_PRODUCTS),
];

export function planForProduct(productId: string): PlanTier | null {
  return SUBSCRIPTION_PRODUCTS[productId] ?? null;
}

export function creditsForProduct(productId: string): number | null {
  return CONSUMABLE_PRODUCTS[productId] ?? null;
}

/**
 * The entitlement identifier configured in RevenueCat. RevenueCat reports the
 * entitlement, which is more reliable than parsing the product ID — but we fall
 * back to the product mapping when the payload omits it.
 */
export function planForEntitlement(entitlementId: string): PlanTier | null {
  const normalized = entitlementId.toLowerCase();
  if (normalized.includes("pro")) return "pro";
  if (normalized.includes("plus")) return "plus";
  return null;
}
