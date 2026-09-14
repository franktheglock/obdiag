/**
 * Server-side model catalog.
 *
 * The client no longer decides which models exist or what they cost — it asks
 * the server. That means you can add, remove or re-price a model without an
 * App Store release, and a tampered client cannot route to an expensive model
 * its plan doesn't allow.
 *
 * Prices are USD per token and were verified against OpenRouter's public model
 * list in September 2026. `tierForPrice` re-derives the tier at load time so a
 * stale price can never silently grant a higher tier than intended — but the
 * tier is also checked against the plan in `authorizeModel`.
 */

import { ModelTier, tierForPrice } from "./plans";

export interface ModelDefinition {
  id: string;
  name: string;
  provider: string;
  contextLength: number;
  promptPricePerToken: number;
  completionPricePerToken: number;
  supportsTools: boolean;
  supportsReasoning: boolean;
  supportsImages: boolean;
  isFree: boolean;
  isRecommended: boolean;
  description?: string;
  /** Explicit tier override. When omitted, derived from price. */
  tierOverride?: ModelTier;
}

export const DEFAULT_MODEL_ID = "google/gemini-3.8-flash";

const CATALOG: ModelDefinition[] = [
  // Flash — fast and cheap
  {
    id: "google/gemini-3.8-flash",
    name: "Gemini 3.8 Flash",
    provider: "Google",
    contextLength: 1_048_576,
    promptPricePerToken: 0.75e-6,
    completionPricePerToken: 3.75e-6,
    supportsTools: true,
    supportsReasoning: true,
    supportsImages: true,
    isFree: false,
    isRecommended: true,
    description:
      "Fast, current-generation generalist with vision and strong tool use. The default for everyday diagnosis.",
  },
  {
    id: "openai/gpt-5.6-luna",
    name: "GPT-5.6 Luna",
    provider: "OpenAI",
    contextLength: 1_048_576,
    promptPricePerToken: 0.2e-6,
    completionPricePerToken: 1.2e-6,
    supportsTools: true,
    supportsReasoning: true,
    supportsImages: true,
    isFree: false,
    isRecommended: true,
    description: "OpenAI's value tier — excellent price/performance with vision.",
  },
  {
    id: "deepseek/deepseek-v4.1-flash",
    name: "DeepSeek V4.1 Flash",
    provider: "DeepSeek",
    contextLength: 1_048_576,
    promptPricePerToken: 0.15e-6,
    completionPricePerToken: 0.6e-6,
    supportsTools: true,
    supportsReasoning: true,
    supportsImages: true,
    isFree: false,
    isRecommended: false,
    description: "Very cheap, vision-capable, million-token context.",
  },

  // Plus — balanced everyday power
  {
    id: "x-ai/grok-4.3",
    name: "Grok 4.3",
    provider: "xAI",
    contextLength: 1_000_000,
    promptPricePerToken: 1.25e-6,
    completionPricePerToken: 2.5e-6,
    supportsTools: true,
    supportsReasoning: true,
    supportsImages: true,
    isFree: false,
    isRecommended: false,
    description: "Fast frontier model with live knowledge and vision.",
  },
  {
    id: "anthropic/claude-sonnet-5",
    name: "Claude Sonnet 5",
    provider: "Anthropic",
    contextLength: 1_000_000,
    promptPricePerToken: 2.0e-6,
    completionPricePerToken: 10.0e-6,
    supportsTools: true,
    supportsReasoning: true,
    supportsImages: true,
    isFree: false,
    isRecommended: true,
    description:
      "Careful, well-cited reasoning — a strong default for real diagnostic work.",
  },
  {
    id: "x-ai/grok-4.6",
    name: "Grok 4.6",
    provider: "xAI",
    contextLength: 500_000,
    promptPricePerToken: 2.0e-6,
    completionPricePerToken: 6.0e-6,
    supportsTools: true,
    supportsReasoning: true,
    supportsImages: true,
    isFree: false,
    isRecommended: false,
    description: "Frontier reasoning at a mid-tier price.",
  },
  {
    id: "openai/gpt-5.6-sol",
    name: "GPT-5.6 Sol",
    provider: "OpenAI",
    contextLength: 1_048_576,
    promptPricePerToken: 2.0e-6,
    completionPricePerToken: 10.0e-6,
    supportsTools: true,
    supportsReasoning: true,
    supportsImages: true,
    isFree: false,
    isRecommended: false,
    description: "OpenAI's mid tier with strong tool calling.",
  },
  {
    id: "google/gemini-3.5-flash",
    name: "Gemini 3.5 Flash",
    provider: "Google",
    contextLength: 1_048_576,
    promptPricePerToken: 1.5e-6,
    completionPricePerToken: 9.0e-6,
    supportsTools: true,
    supportsReasoning: true,
    supportsImages: true,
    isFree: false,
    isRecommended: false,
    description: "Previous-generation Flash with a proven track record.",
  },
  {
    id: "qwen/qwen3.8-max-0902",
    name: "Qwen 3.8 Max",
    provider: "Qwen",
    contextLength: 1_000_000,
    promptPricePerToken: 2.0e-6,
    completionPricePerToken: 6.0e-6,
    supportsTools: true,
    supportsReasoning: true,
    supportsImages: true,
    isFree: false,
    isRecommended: false,
    description: "Strong open-weight family flagship with vision.",
  },
  {
    id: "moonshotai/kimi-k3",
    name: "Kimi K3",
    provider: "Moonshot",
    contextLength: 1_048_576,
    promptPricePerToken: 2.3e-6,
    completionPricePerToken: 11.55e-6,
    supportsTools: true,
    supportsReasoning: true,
    supportsImages: true,
    isFree: false,
    isRecommended: false,
    description: "Long-context agentic model with good tool use.",
  },
  {
    id: "z-ai/glm-5.3",
    name: "GLM-5.3",
    provider: "Z.ai",
    contextLength: 1_310_720,
    promptPricePerToken: 1.4e-6,
    completionPricePerToken: 4.4e-6,
    supportsTools: true,
    supportsReasoning: true,
    supportsImages: false,
    isFree: false,
    isRecommended: false,
    description: "High-value frontier model with a huge context window.",
  },
  {
    id: "anthropic/claude-opus-5",
    name: "Claude Opus 5",
    provider: "Anthropic",
    contextLength: 1_000_000,
    promptPricePerToken: 5.0e-6,
    completionPricePerToken: 25.0e-6,
    supportsTools: true,
    supportsReasoning: true,
    supportsImages: true,
    isFree: false,
    isRecommended: true,
    description:
      "Anthropic's frontier model for the hardest, most ambiguous faults.",
  },

  // Max — frontier reasoning
  {
    id: "openai/gpt-6-astra",
    name: "GPT-6 Astra",
    provider: "OpenAI",
    contextLength: 1_050_000,
    promptPricePerToken: 10.0e-6,
    completionPricePerToken: 50.0e-6,
    supportsTools: true,
    supportsReasoning: true,
    supportsImages: true,
    isFree: false,
    isRecommended: false,
    description: "OpenAI's flagship — deepest reasoning, highest cost.",
  },
  {
    id: "anthropic/claude-fable-5.1",
    name: "Claude Fable 5.1",
    provider: "Anthropic",
    contextLength: 1_000_000,
    promptPricePerToken: 10.0e-6,
    completionPricePerToken: 50.0e-6,
    supportsTools: true,
    supportsReasoning: true,
    supportsImages: true,
    isFree: false,
    isRecommended: false,
    description: "Anthropic's newest frontier tier (limited availability).",
  },

  // Free
  {
    id: "google/gemma-4-31b-it:free",
    name: "Gemma 4 31B (free)",
    provider: "Google",
    contextLength: 262_144,
    promptPricePerToken: 0,
    completionPricePerToken: 0,
    supportsTools: true,
    supportsReasoning: false,
    supportsImages: true,
    isFree: true,
    isRecommended: false,
    description: "No-cost vision option for straightforward questions.",
  },
  {
    id: "thinkingmachines/inkling:free",
    name: "Inkling (free)",
    provider: "Thinking Machines",
    contextLength: 1_048_576,
    promptPricePerToken: 0,
    completionPricePerToken: 0,
    supportsTools: true,
    supportsReasoning: false,
    supportsImages: true,
    isFree: true,
    isRecommended: false,
    description: "Free million-token-context model with vision.",
  },
];

export interface ResolvedModel extends ModelDefinition {
  tier: ModelTier;
}

function resolve(model: ModelDefinition): ResolvedModel {
  return {
    ...model,
    tier: model.tierOverride ?? tierForPrice(model.promptPricePerToken, model.isFree),
  };
}

const RESOLVED: ResolvedModel[] = CATALOG.map(resolve);
const BY_ID = new Map<string, ResolvedModel>(RESOLVED.map((m) => [m.id, m]));

export function allModels(): ResolvedModel[] {
  return RESOLVED;
}

export function modelById(id: string): ResolvedModel | undefined {
  return BY_ID.get(id);
}

export function defaultModel(): ResolvedModel {
  return BY_ID.get(DEFAULT_MODEL_ID) ?? RESOLVED[0]!;
}

/** The client-facing shape. Tier is included so the app can group the picker. */
export function publicCatalog(): Array<Record<string, unknown>> {
  return RESOLVED.map((m) => ({
    id: m.id,
    name: m.name,
    provider: m.provider,
    contextLength: m.contextLength,
    promptPricePerToken: m.promptPricePerToken,
    completionPricePerToken: m.completionPricePerToken,
    supportsTools: m.supportsTools,
    supportsReasoning: m.supportsReasoning,
    supportsImages: m.supportsImages,
    isFree: m.isFree,
    isRecommended: m.isRecommended,
    description: m.description ?? null,
    tier: m.tier,
  }));
}
