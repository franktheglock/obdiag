/**
 * Plan definitions and credit math.
 *
 * This is the server-side source of truth for what a plan may do. The iOS
 * client mirrors these numbers for display only — the server always
 * re-validates, because the client is untrusted.
 *
 * Keep in sync with `OBDiag/Core/Models/UserProfile.swift`.
 */

export type PlanTier = "free" | "plus" | "pro";
export type ModelTier = "flash" | "plus" | "max";

export interface PlanConfig {
  tier: PlanTier;
  /** Higher wins when merging entitlements from multiple sources. */
  rank: number;
  /** The most capable model tier this plan may call. */
  maxModelTier: ModelTier;
  /** Credits granted at the start of each billing month. */
  monthlyCredits: number;
  /** Spending multiplier — lower plans burn credits faster. */
  creditMultiplier: number;
  /** Hard ceiling on `max_tokens` for this plan, regardless of client input. */
  maxOutputTokens: number;
}

export const PLANS: Record<PlanTier, PlanConfig> = {
  free: {
    tier: "free",
    rank: 0,
    maxModelTier: "flash",
    monthlyCredits: 150,
    creditMultiplier: 1.5,
    maxOutputTokens: 2_048,
  },
  plus: {
    tier: "plus",
    rank: 1,
    maxModelTier: "plus",
    monthlyCredits: 2_500,
    creditMultiplier: 1.2,
    maxOutputTokens: 4_096,
  },
  pro: {
    tier: "pro",
    rank: 2,
    maxModelTier: "max",
    monthlyCredits: 8_000,
    creditMultiplier: 1.0,
    maxOutputTokens: 8_192,
  },
};

export const MODEL_TIER_RANK: Record<ModelTier, number> = {
  flash: 0,
  plus: 1,
  max: 2,
};

/** 1 credit ≈ $0.001 of model usage, before the plan multiplier. */
export const USD_PER_CREDIT = 0.001;

/** Minimum charge for any billable request, so free riders still cost something. */
export const MINIMUM_CHARGE = 1;

export function planConfig(tier: PlanTier): PlanConfig {
  return PLANS[tier];
}

export function isPlanTier(value: unknown): value is PlanTier {
  return value === "free" || value === "plus" || value === "pro";
}

/**
 * Derive the capability tier from input price per million tokens, matching the
 * client's rule: Flash < $1/M · Plus $1–5/M · Max > $5/M. Free models are Flash.
 */
export function tierForPrice(promptPricePerToken: number, isFree = false): ModelTier {
  if (isFree || promptPricePerToken <= 0) return "flash";
  const perMillion = promptPricePerToken * 1_000_000;
  if (perMillion < 1) return "flash";
  if (perMillion <= 5) return "plus";
  return "max";
}

/**
 * Convert a real USD cost into credits for a given plan.
 * Mirrors `CreditPricing.credits(for:model:plan:)` on the client.
 */
export function creditsForUSD(usd: number, plan: PlanTier): number {
  if (!(usd > 0)) return 0;
  const raw = (usd / USD_PER_CREDIT) * planConfig(plan).creditMultiplier;
  return Math.max(MINIMUM_CHARGE, Math.ceil(raw));
}

/**
 * Conservative credit estimate used to reserve balance before a stream starts.
 * Deliberately pessimistic: over-reserving is refunded at settle time, whereas
 * under-reserving lets a user overspend.
 */
export function estimateCredits(params: {
  plan: PlanTier;
  promptPricePerToken: number;
  completionPricePerToken: number;
  promptTokens: number;
  maxOutputTokens: number;
}): number {
  const usd =
    params.promptTokens * params.promptPricePerToken +
    params.maxOutputTokens * params.completionPricePerToken;
  return creditsForUSD(usd, params.plan);
}

/** Rough token count for pre-flight estimation: ~4 characters per token. */
export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}
