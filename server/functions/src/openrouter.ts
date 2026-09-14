/**
 * Minimal streaming client for OpenRouter's OpenAI-compatible API.
 *
 * Lives on the server so the OpenRouter key never reaches the device. Yields
 * raw SSE `data:` payloads, which the callable forwards to the client verbatim
 * — that keeps the client's existing chunk parser working unchanged and keeps
 * this layer free of provider-specific modelling.
 */

import { APP_REFERER, APP_TITLE, LIMITS, OPENROUTER_BASE } from "./config";

export interface OpenRouterStreamOptions {
  apiKey: string;
  payload: unknown;
  signal?: AbortSignal;
}

/**
 * Async generator over SSE payload strings (the part after `data: `).
 * The final `[DONE]` sentinel is not yielded.
 */
export async function* streamChatCompletion(
  options: OpenRouterStreamOptions,
): AsyncGenerator<string, void, unknown> {
  const { apiKey, payload, signal } = options;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), LIMITS.streamTimeoutMs);
  const onAbort = () => controller.abort();
  signal?.addEventListener("abort", onAbort, { once: true });

  try {
    const response = await fetch(`${OPENROUTER_BASE}/chat/completions`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        Accept: "text/event-stream",
        "HTTP-Referer": APP_REFERER,
        "X-Title": APP_TITLE,
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });

    if (!response.ok || !response.body) {
      const text = await safeText(response);
      throw new OpenRouterError(response.status, text);
    }

    const decoder = new TextDecoder();
    let buffer = "";

    // `response.body` is a web ReadableStream in Node 18+.
    for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
      buffer += decoder.decode(chunk, { stream: true });

      // SSE frames are separated by a blank line; tolerate bare newlines too.
      let newlineIndex: number;
      while ((newlineIndex = buffer.indexOf("\n")) !== -1) {
        const line = buffer.slice(0, newlineIndex).replace(/\r$/, "");
        buffer = buffer.slice(newlineIndex + 1);

        if (!line.startsWith("data:")) continue;
        const data = line.slice(5).trim();
        if (!data) continue;
        if (data === "[DONE]") return;
        yield data;
      }
    }

    // Flush a trailing frame that had no terminating newline.
    const trailing = buffer.trim();
    if (trailing.startsWith("data:")) {
      const data = trailing.slice(5).trim();
      if (data && data !== "[DONE]") yield data;
    }
  } finally {
    clearTimeout(timeout);
    signal?.removeEventListener("abort", onAbort);
  }
}

async function safeText(response: Response): Promise<string> {
  try {
    const text = await response.text();
    return text.slice(0, 2_000);
  } catch {
    return "";
  }
}

export class OpenRouterError extends Error {
  constructor(
    readonly status: number,
    readonly body: string,
  ) {
    super(`OpenRouter responded ${status}`);
    this.name = "OpenRouterError";
  }

  /** A message safe to show a user. */
  get userMessage(): string {
    if (this.status === 401 || this.status === 403) {
      return "The AI service rejected the request. Please try again later.";
    }
    if (this.status === 402) {
      return "The AI service is temporarily unavailable. Please try again later.";
    }
    if (this.status === 429) {
      return "Too many requests right now. Please wait a moment and try again.";
    }
    try {
      const parsed = JSON.parse(this.body) as {
        error?: { message?: string } | string;
      };
      if (typeof parsed.error === "string") return parsed.error;
      if (parsed.error?.message) return parsed.error.message;
    } catch {
      // fall through
    }
    return "The AI provider returned an unexpected response.";
  }
}
