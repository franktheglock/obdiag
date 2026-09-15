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
  /** Hard ceiling on `max_tokens` for this plan, regardless of client input. */
  maxOutputTokens: number;
}

export const PLANS: Record<PlanTier, PlanConfig> = {
  free: {
    tier: "free",
    rank: 0,
    maxModelTier: "flash",
    monthlyCredits: 150,
    maxOutputTokens: 2_048,
  },
  plus: {
    tier: "plus",
    rank: 1,
    maxModelTier: "plus",
    monthlyCredits: 2_500,
    maxOutputTokens: 4_096,
  },
  pro: {
    tier: "pro",
    rank: 2,
    maxModelTier: "max",
    monthlyCredits: 8_000,
    maxOutputTokens: 8_192,
  },
};

export const MODEL_TIER_RANK: Record<ModelTier, number> = {
  flash: 0,
  plus: 1,
  max: 2,
};

/** 1 credit = 1,000 tokens at the base (Plus) rate. */
export const TOKENS_PER_CREDIT = 1_000;

/**
 * Billing multiplier per model tier.
 *
 * Credits charged for a request are:
 *
 *     ceil( total_tokens / 1000 × MODEL_TIER_MULTIPLIER[tier] )
 *
 * Flash bills at a third of the base rate, Plus at the base rate, Max at 5×.
 * The multiplier encodes how much the model costs to run, so a credit stays
 * roughly comparable across tiers without exposing provider pricing.
 */
export const MODEL_TIER_MULTIPLIER: Record<ModelTier, number> = {
  flash: 0.33,
  plus: 1,
  max: 5,
};

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

/** The core billing formula. 0 for free/local models, which never bill. */
export function creditsForTokens(tokens: number, tier: ModelTier): number {
  if (!(tokens > 0)) return 0;
  const raw = (tokens / TOKENS_PER_CREDIT) * MODEL_TIER_MULTIPLIER[tier];
  return Math.max(MINIMUM_CHARGE, Math.ceil(raw));
}

/**
 * Conservative credit estimate used to reserve balance before a stream starts.
 * Counts the prompt plus the maximum output the plan permits, so the hold is
 * never smaller than the eventual charge.
 */
export function estimateCredits(params: {
  tier: ModelTier;
  promptTokens: number;
  maxOutputTokens: number;
}): number {
  return creditsForTokens(params.promptTokens + params.maxOutputTokens, params.tier);
}

/** Rough token count for pre-flight estimation: ~4 characters per token. */
export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}
