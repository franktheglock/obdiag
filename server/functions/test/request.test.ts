import { describe, expect, it } from "vitest";
import {
  chatRequestSchema,
  parseUsagePayload,
  RequestError,
  sanitizeRequest,
} from "../src/request";
import { planConfig } from "../src/plans";

const PLAN_MAX_OUTPUT = planConfig("pro").maxOutputTokens;

function parse(input: unknown) {
  const result = chatRequestSchema.safeParse(input);
  if (!result.success) throw new Error(`schema rejected: ${result.error.message}`);
  return result.data;
}

const baseMessage = { role: "user" as const, content: "Why is my car idling rough?" };

describe("chatRequestSchema", () => {
  it("accepts a minimal request", () => {
    expect(() => parse({ model: "m", messages: [baseMessage] })).not.toThrow();
  });

  it("strips unknown top-level fields rather than passing them through", () => {
    const parsed = parse({
      model: "m",
      messages: [baseMessage],
      models: ["expensive/model-a", "expensive/model-b"],
      route: "fallback",
      transforms: ["middle-out"],
      plugins: [{ id: "web" }],
      provider: { sort: "price", order: ["evil"] },
    });
    expect(parsed).not.toHaveProperty("models");
    expect(parsed).not.toHaveProperty("route");
    expect(parsed).not.toHaveProperty("transforms");
    expect(parsed).not.toHaveProperty("plugins");
    // Unknown nested provider keys are stripped too.
    expect(parsed.provider).toEqual({ sort: "price" });
  });

  it("rejects an empty message list", () => {
    expect(chatRequestSchema.safeParse({ model: "m", messages: [] }).success).toBe(false);
  });

  it("rejects an unknown message role", () => {
    const result = chatRequestSchema.safeParse({
      model: "m",
      messages: [{ role: "root", content: "hi" }],
    });
    expect(result.success).toBe(false);
  });

  it("rejects out-of-range sampling parameters", () => {
    expect(
      chatRequestSchema.safeParse({
        model: "m",
        messages: [baseMessage],
        temperature: 5,
      }).success,
    ).toBe(false);
  });

  it("rejects a server tool that isn't in the openrouter: namespace", () => {
    const result = chatRequestSchema.safeParse({
      model: "m",
      messages: [baseMessage],
      tools: [{ type: "plugin:shell" }],
    });
    expect(result.success).toBe(false);
  });
});

describe("sanitizeRequest", () => {
  it("always forces streaming with usage reporting", () => {
    const { payload } = sanitizeRequest(parse({ model: "m", messages: [baseMessage] }), {
      planMaxTokens: PLAN_MAX_OUTPUT,
    });
    expect(payload.stream).toBe(true);
    expect(payload.stream_options).toEqual({ include_usage: true });
    expect(payload.usage).toEqual({ include: true });
  });

  it("clamps max_tokens down to the plan ceiling", () => {
    const { payload } = sanitizeRequest(
      parse({ model: "m", messages: [baseMessage], max_tokens: 65_536 }),
      { planMaxTokens: 2_048 },
    );
    expect(payload.max_tokens).toBe(2_048);
  });

  it("applies the plan ceiling when the client omits max_tokens", () => {
    const { payload } = sanitizeRequest(parse({ model: "m", messages: [baseMessage] }), {
      planMaxTokens: 4_096,
    });
    expect(payload.max_tokens).toBe(4_096);
  });

  it("preserves function tools", () => {
    const { payload } = sanitizeRequest(
      parse({
        model: "m",
        messages: [baseMessage],
        tools: [
          {
            type: "function",
            function: {
              name: "read_live_data",
              description: "Reads PIDs",
              parameters: { type: "object", properties: {} },
            },
          },
        ],
      }),
      { planMaxTokens: PLAN_MAX_OUTPUT },
    );
    const tools = payload.tools as Array<Record<string, unknown>>;
    expect(tools).toHaveLength(1);
    expect(tools[0]).toMatchObject({ type: "function" });
    expect(payload.tool_choice).toBe("auto");
  });

  it("clamps web search result counts so a client can't inflate cost", () => {
    const { payload } = sanitizeRequest(
      parse({
        model: "m",
        messages: [baseMessage],
        tools: [{ type: "openrouter:web_search", parameters: { max_results: 999 } }],
      }),
      { planMaxTokens: PLAN_MAX_OUTPUT },
    );
    const tools = payload.tools as Array<Record<string, unknown>>;
    expect(tools[0]).toMatchObject({
      type: "openrouter:web_search",
      parameters: { max_results: 5 },
    });
  });

  it("drops unknown server tools entirely", () => {
    const { payload } = sanitizeRequest(
      parse({
        model: "m",
        messages: [baseMessage],
        tools: [{ type: "openrouter:shell_exec", parameters: { cmd: "rm -rf /" } }],
      }),
      { planMaxTokens: PLAN_MAX_OUTPUT },
    );
    // No usable tools remain, so the field is omitted rather than sent empty.
    expect(payload.tools).toBeUndefined();
  });

  it("counts prompt characters for the pre-flight estimate", () => {
    const { estimatedPromptChars } = sanitizeRequest(
      parse({ model: "m", messages: [baseMessage] }),
      { planMaxTokens: PLAN_MAX_OUTPUT },
    );
    expect(estimatedPromptChars).toBe(baseMessage.content.length);
  });

  it("accepts a normal data-URL image", () => {
    const { payload } = sanitizeRequest(
      parse({
        model: "m",
        messages: [
          {
            role: "user",
            content: [
              { type: "text", text: "what is this warning light" },
              { type: "image_url", image_url: { url: "data:image/jpeg;base64,AAAA" } },
            ],
          },
        ],
      }),
      { planMaxTokens: PLAN_MAX_OUTPUT },
    );
    const messages = payload.messages as Array<{ content: unknown[] }>;
    expect(messages[0]!.content).toHaveLength(2);
  });

  it("rejects an oversized image attachment", () => {
    const huge = `data:image/jpeg;base64,${"A".repeat(7_000_000)}`;
    expect(() =>
      sanitizeRequest(
        parse({
          model: "m",
          messages: [{ role: "user", content: [{ type: "image_url", image_url: huge }] }],
        }),
        { planMaxTokens: PLAN_MAX_OUTPUT },
      ),
    ).toThrow(RequestError);
  });

  it("rejects a non-image URL scheme", () => {
    expect(() =>
      sanitizeRequest(
        parse({
          model: "m",
          messages: [
            {
              role: "user",
              content: [{ type: "image_url", image_url: "file:///etc/passwd" }],
            },
          ],
        }),
        { planMaxTokens: PLAN_MAX_OUTPUT },
      ),
    ).toThrow(RequestError);
  });

  it("rejects an oversized conversation", () => {
    const messages = Array.from({ length: 5 }, () => ({
      role: "user" as const,
      content: "x".repeat(60_000),
    }));
    expect(() =>
      sanitizeRequest(parse({ model: "m", messages }), {
        planMaxTokens: PLAN_MAX_OUTPUT,
      }),
    ).toThrow(RequestError);
  });
});

describe("parseUsagePayload", () => {
  it("extracts tokens and reported cost", () => {
    expect(
      parseUsagePayload({
        usage: {
          prompt_tokens: 1_200,
          completion_tokens: 340,
          total_tokens: 1_540,
          cost: 0.0084,
        },
      }),
    ).toEqual({
      promptTokens: 1_200,
      completionTokens: 340,
      totalTokens: 1_540,
      costUSD: 0.0084,
    });
  });

  it("returns null when there is no usage object", () => {
    expect(parseUsagePayload({ choices: [] })).toBeNull();
    expect(parseUsagePayload(null)).toBeNull();
    expect(parseUsagePayload("nope")).toBeNull();
  });

  it("tolerates a missing total and missing cost", () => {
    expect(
      parseUsagePayload({ usage: { prompt_tokens: 10, completion_tokens: 5 } }),
    ).toMatchObject({ totalTokens: 15, costUSD: 0 });
  });
});
