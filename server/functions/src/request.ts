/**
 * Request validation and sanitisation.
 *
 * The client is untrusted. Everything the app sends is re-validated here, and
 * the payload is rebuilt from a strict allow-list rather than forwarded. That
 * means fields we don't know about — OpenRouter routing directives, fallback
 * model lists, provider plugins, transforms — are dropped instead of being
 * passed through to something that spends money.
 */

import { z } from "zod";
import { LIMITS } from "./config";

/* -------------------------------------------------------------------------- */
/* Schema                                                                     */
/* -------------------------------------------------------------------------- */

const jsonValueSchema: z.ZodType<unknown> = z.lazy(() =>
  z.union([
    z.string(),
    z.number(),
    z.boolean(),
    z.null(),
    z.array(jsonValueSchema),
    z.record(jsonValueSchema),
  ]),
);

/**
 * Anthropic-style cache breakpoint.
 *
 * Deliberately permissive here and validated in `sanitizeCacheControl`: a
 * malformed or unrecognised marker should be dropped, not fail the whole chat
 * request, since caching is an optimisation and never a correctness concern.
 */
const cacheControlSchema = z
  .object({
    type: z.string(),
    ttl: z.string().nullish(),
  })
  .nullish();

const textPartSchema = z.object({
  type: z.literal("text"),
  text: z.string(),
  cache_control: cacheControlSchema.nullish(),
});

const imagePartSchema = z.object({
  type: z.literal("image_url"),
  image_url: z.union([
    z.string(),
    z.object({ url: z.string() }),
  ]),
  cache_control: cacheControlSchema.nullish(),
});

const contentSchema = z.union([
  z.string(),
  z.array(z.union([textPartSchema, imagePartSchema])),
]);

const toolCallSchema = z.object({
  id: z.string(),
  type: z.literal("function").optional(),
  function: z.object({
    name: z.string(),
    arguments: z.string(),
  }),
});

const messageSchema = z
  .object({
    role: z.enum(["system", "user", "assistant", "tool", "developer"]),
    content: contentSchema.nullish(),
    name: z.string().nullish(),
    tool_call_id: z.string().nullish(),
    tool_calls: z.array(toolCallSchema).nullish(),
  })
  .strip();

const functionToolSchema = z
  .object({
    type: z.literal("function"),
    function: z.object({
      name: z.string(),
      description: z.string().default(""),
      parameters: jsonValueSchema.default({ type: "object", properties: {} }),
    }),
  })
  .strip();

/** OpenRouter server-executed tools, e.g. web search. */
const serverToolSchema = z
  .object({
    type: z.string().regex(/^openrouter:[a-z_]+$/),
    parameters: z.record(jsonValueSchema).nullish(),
  })
  .strip();

const toolSchema = z.union([functionToolSchema, serverToolSchema]);

export const chatRequestSchema = z
  .object({
    model: z.string().min(1).max(200),
    messages: z.array(messageSchema).min(1).max(LIMITS.maxMessages),
    tools: z.array(toolSchema).max(LIMITS.maxToolDefinitions).nullish(),
    tool_choice: z
      .union([
        z.enum(["auto", "none", "required"]),
        z.object({
          type: z.literal("function"),
          function: z.object({ name: z.string() }),
        }),
      ])
      .nullish(),
    reasoning: z
      .object({
        effort: z.enum(["minimal", "low", "medium", "high"]).nullish(),
        exclude: z.boolean().nullish(),
      })
      .nullish(),
    temperature: z.number().min(0).max(2).nullish(),
    max_tokens: z.number().int().positive().max(65_536).nullish(),
    provider: z
      .object({
        sort: z.enum(["price", "throughput", "latency"]).nullish(),
        require_parameters: z.boolean().nullish(),
      })
      .nullish(),
  })
  .strip();

export type ChatRequest = z.infer<typeof chatRequestSchema>;

/* -------------------------------------------------------------------------- */
/* Sanitisation                                                               */
/* -------------------------------------------------------------------------- */

/**
 * Server tools we permit, with hard caps on the parameters that cost money.
 */
const SERVER_TOOL_LIMITS: Record<string, Record<string, number>> = {
  "openrouter:web_search": { max_results: 5 },
  "openrouter:web_fetch": {},
};

/**
 * Anthropic accepts at most four cache breakpoints per request; exceeding that
 * is a hard 400. The client only ever sends two (end of the system block, end of
 * the transcript), so anything beyond this budget is a client bug or an attack.
 */
const MAX_CACHE_BREAKPOINTS = 4;

/**
 * Validate a cache breakpoint marker. Anthropic's `cache_control` is a small
 * closed shape, so anything unrecognised is dropped rather than forwarded.
 */
function sanitizeCacheControl(
  value: unknown,
): Record<string, unknown> | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const record = value as Record<string, unknown>;
  if (record.type !== "ephemeral") return undefined;
  const marker: Record<string, unknown> = { type: "ephemeral" };
  // The 1-hour TTL is opt-in and costs more to write, so it must be explicit.
  if (record.ttl === "5m" || record.ttl === "1h") marker.ttl = record.ttl;
  return marker;
}

export class RequestError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RequestError";
  }
}

function sanitizeServerTool(tool: {
  type: string;
  parameters?: Record<string, unknown> | null;
}): Record<string, unknown> | null {
  const caps = SERVER_TOOL_LIMITS[tool.type];
  if (!caps) return null; // Unknown server tool: drop it.

  const parameters: Record<string, unknown> = {};
  for (const [key, cap] of Object.entries(caps)) {
    const raw = tool.parameters?.[key];
    if (typeof raw === "number" && Number.isFinite(raw)) {
      parameters[key] = Math.min(Math.max(Math.trunc(raw), 1), cap);
    }
  }
  return { type: tool.type, parameters };
}

function sanitizeContent(
  content: unknown,
  budget: { breakpoints: number },
): unknown {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return content;

  const parts: unknown[] = [];
  for (const part of content) {
    if (typeof part !== "object" || part === null) continue;
    const record = part as Record<string, unknown>;

    // Prompt-cache breakpoints must survive the rebuild. Dropping them here
    // would silently disable caching for every managed request — the failure
    // mode is invisible (correct answers, higher bill) so it is worth being
    // explicit about it.
    let cacheControl: Record<string, unknown> | undefined;
    if (record.cache_control !== undefined) {
      if (budget.breakpoints < MAX_CACHE_BREAKPOINTS) {
        cacheControl = sanitizeCacheControl(record.cache_control);
        if (cacheControl) budget.breakpoints += 1;
      }
    }

    if (record.type === "text" && typeof record.text === "string") {
      parts.push({
        type: "text",
        text: record.text,
        ...(cacheControl ? { cache_control: cacheControl } : {}),
      });
      continue;
    }

    if (record.type === "image_url") {
      const url =
        typeof record.image_url === "string"
          ? record.image_url
          : (record.image_url as { url?: string } | undefined)?.url;
      if (typeof url !== "string") continue;
      // Reject oversized attachments rather than paying to upload them.
      if (url.length > LIMITS.maxImageBytes) {
        throw new RequestError("An attached image is too large.");
      }
      if (!url.startsWith("data:image/") && !url.startsWith("https://")) {
        throw new RequestError("Unsupported image attachment.");
      }
      parts.push({
        type: "image_url",
        image_url: { url },
        ...(cacheControl ? { cache_control: cacheControl } : {}),
      });
    }
  }
  return parts;
}

export interface SanitizeResult {
  payload: Record<string, unknown>;
  /** Characters of user/assistant text, used for the pre-flight token estimate. */
  estimatedPromptChars: number;
}

/**
 * Rebuild an OpenRouter chat-completions payload from validated input.
 *
 * @param planMaxTokens Hard ceiling on output tokens for the caller's plan.
 */
export function sanitizeRequest(
  request: ChatRequest,
  options: { planMaxTokens: number },
): SanitizeResult {
  let promptChars = 0;
  const messages: unknown[] = [];
  const budget = { breakpoints: 0 };

  for (const message of request.messages) {
    const content = sanitizeContent(message.content, budget);
    if (typeof content === "string") promptChars += content.length;

    const toolCalls = message.tool_calls
      ?.slice(0, LIMITS.maxToolDefinitions)
      .map((call) => ({
        id: call.id,
        type: "function" as const,
        function: {
          name: call.function.name,
          arguments: call.function.arguments,
        },
      }));

    for (const call of toolCalls ?? []) {
      promptChars += call.function.arguments.length;
    }

    messages.push({
      role: message.role,
      content: content ?? null,
      ...(message.name ? { name: message.name } : {}),
      ...(message.tool_call_id ? { tool_call_id: message.tool_call_id } : {}),
      ...(toolCalls && toolCalls.length > 0 ? { tool_calls: toolCalls } : {}),
    });

    if (promptChars > LIMITS.maxMessageChars) {
      throw new RequestError("This conversation is too large to send.");
    }
  }

  const tools: unknown[] = [];
  for (const tool of request.tools ?? []) {
    if ("function" in tool && tool.function) {
      tools.push({
        type: "function",
        function: {
          name: tool.function.name,
          description: tool.function.description,
          parameters: tool.function.parameters,
        },
      });
    } else if ("type" in tool && typeof tool.type === "string") {
      const serverTool = sanitizeServerTool(
        tool as { type: string; parameters?: Record<string, unknown> | null },
      );
      if (serverTool) tools.push(serverTool);
    }
  }

  const payload: Record<string, unknown> = {
    model: request.model,
    messages,
    stream: true,
    // The server needs real usage to bill accurately, so this is not optional.
    stream_options: { include_usage: true },
    usage: { include: true },
  };

  if (tools.length > 0) {
    payload.tools = tools;
    payload.tool_choice = request.tool_choice ?? "auto";
  }
  if (request.reasoning) {
    payload.reasoning = {
      ...(request.reasoning.effort ? { effort: request.reasoning.effort } : {}),
      ...(request.reasoning.exclude !== null &&
      request.reasoning.exclude !== undefined
        ? { exclude: request.reasoning.exclude }
        : {}),
    };
  }
  if (request.temperature !== null && request.temperature !== undefined) {
    payload.temperature = request.temperature;
  }
  if (request.max_tokens) {
    payload.max_tokens = Math.min(request.max_tokens, options.planMaxTokens);
  } else {
    payload.max_tokens = options.planMaxTokens;
  }
  if (request.provider) {
    payload.provider = {
      ...(request.provider.sort ? { sort: request.provider.sort } : {}),
      ...(request.provider.require_parameters !== null &&
      request.provider.require_parameters !== undefined
        ? { require_parameters: request.provider.require_parameters }
        : {}),
    };
  }

  return { payload, estimatedPromptChars: promptChars };
}

/** Pull token usage and USD cost out of an OpenRouter usage chunk. */
export function parseUsagePayload(
  value: unknown,
): { promptTokens: number; completionTokens: number; totalTokens: number; costUSD: number } | null {
  if (typeof value !== "object" || value === null) return null;
  const record = value as Record<string, unknown>;
  const usage = record.usage;
  if (typeof usage !== "object" || usage === null) return null;

  const usageRecord = usage as Record<string, unknown>;
  const promptTokens = Number(usageRecord.prompt_tokens ?? 0);
  const completionTokens = Number(usageRecord.completion_tokens ?? 0);
  const totalTokens = Number(
    usageRecord.total_tokens ?? promptTokens + completionTokens,
  );
  const costUSD = Number(usageRecord.cost ?? 0);

  if (!Number.isFinite(promptTokens) && !Number.isFinite(completionTokens)) {
    return null;
  }
  return {
    promptTokens: Number.isFinite(promptTokens) ? promptTokens : 0,
    completionTokens: Number.isFinite(completionTokens) ? completionTokens : 0,
    totalTokens: Number.isFinite(totalTokens) ? totalTokens : 0,
    costUSD: Number.isFinite(costUSD) ? costUSD : 0,
  };
}
