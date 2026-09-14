/**
 * Plan-based model gating. The server decides which models a plan may call —
 * the client's picker is a convenience, not a control.
 */

import { PlanTier, MODEL_TIER_RANK, planConfig } from "./plans";
import { ResolvedModel, modelById } from "./models";
import { DomainError } from "./credits";

export function authorizeModel(modelId: string, plan: PlanTier): ResolvedModel {
  const model = modelById(modelId);
  if (!model) {
    throw new DomainError(
      "invalid-argument",
      "That model isn't available. Pick another in Settings → AI model.",
    );
  }

  const allowed = MODEL_TIER_RANK[planConfig(plan).maxModelTier];
  if (MODEL_TIER_RANK[model.tier] > allowed) {
    throw new DomainError(
      "permission-denied",
      `${model.name} isn't included in your plan. Upgrade to use it.`,
    );
  }

  return model;
}
