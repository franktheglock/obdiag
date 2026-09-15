/**
 * The AI proxy: the only place that talks to OpenRouter with the real key.
 *
 * Flow for one assistant turn:
 *   1. Authenticate (Firebase Auth) and re-check the caller's account.
 *   2. Validate and sanitise the request against a strict allow-list.
 *   3. Authorise the requested model against the caller's plan.
 *   4. Reserve a pessimistic credit estimate (atomic, may fail on low balance).
 *   5. Stream OpenRouter's SSE frames straight through to the device.
 *   6. Settle the reservation against real usage — refunding any over-reserve,
 *      and refunding entirely if the stream failed before producing usage.
 *
 * The agent loop stays on the device, because tool execution (live OBD data,
 * fault codes) can only happen there. This function is a stateless completion
 * proxy, which is also why it can stay simple.
 */

import { onCall, HttpsError, CallableRequest, CallableResponse } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";
import { LIMITS, OPENROUTER_API_KEY, REGION } from "./config";
import {
  DomainError,
  applyMonthlyGrant,
  ensureAccount,
  getAccount,
  reserveCredits,
  settleReservation,
} from "./credits";
import { authorizeModel } from "./authorize";
import {
  chatRequestSchema,
  parseUsagePayload,
  sanitizeRequest,
  RequestError,
} from "./request";
import { OpenRouterError, streamChatCompletion } from "./openrouter";
import { creditsForTokens, estimateCredits, estimateTokens, planConfig } from "./plans";
import { publicCatalog } from "./models";

/** One streamed frame: a raw OpenRouter SSE payload, forwarded verbatim. */
interface ChatChunk {
  chunk: string;
}

function toHttpsError(error: unknown): HttpsError {
  if (error instanceof HttpsError) return error;
  if (error instanceof DomainError) {
    return new HttpsError(error.code, error.message);
  }
  if (error instanceof RequestError) {
    return new HttpsError("invalid-argument", error.message);
  }
  if (error instanceof OpenRouterError) {
    logger.error("openrouter error", { status: error.status, body: error.body });
    return new HttpsError(
      error.status === 429 ? "resource-exhausted" : "unavailable",
      error.userMessage,
    );
  }
  return new HttpsError("internal", "Something went wrong. Please try again.");
}

export const chat = onCall(
  {
    region: REGION,
    secrets: [OPENROUTER_API_KEY],
    timeoutSeconds: 540,
    memory: "512MiB",
    cors: true,
    // Requires App Check registration (App Attest / DeviceCheck). This is what
    // stops a repackaged client from spending your OpenRouter balance.
    enforceAppCheck: true,
  },
  async (
    request: CallableRequest<unknown>,
    response?: CallableResponse<ChatChunk>,
  ) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in to use the assistant.");
    }

    await ensureAccount(uid);

    let account = await getAccount(uid);
    // Safety net: if a renewal webhook was missed, the free/paid allowance for
    // this month is still applied here. Idempotent by period.
    const grant = await applyMonthlyGrant(uid);
    if (grant.granted > 0) account = await getAccount(uid);

    const parsed = chatRequestSchema.safeParse(request.data);
    if (!parsed.success) {
      throw new HttpsError(
        "invalid-argument",
        `Invalid request: ${parsed.error.issues
          .map((issue) => `${issue.path.join(".")} ${issue.message}`)
          .join("; ")}`,
      );
    }

    const plan = account.plan;
    const config = planConfig(plan);
    const model = authorizeModel(parsed.data.model, plan);

    if (account.credits <= 0) {
      throw new HttpsError(
        "resource-exhausted",
        "You're out of AI credits. Top up in Settings → Subscription.",
      );
    }

    let sanitized;
    try {
      sanitized = sanitizeRequest(parsed.data, {
        planMaxTokens: config.maxOutputTokens,
      });
    } catch (error) {
      throw toHttpsError(error);
    }

    const promptTokens = estimateTokens(String(sanitized.estimatedPromptChars));
    const estimate = estimateCredits({
      tier: model.tier,
      promptTokens,
      maxOutputTokens: config.maxOutputTokens,
    });

    const reservationId = await reserveCredits(
      uid,
      Math.min(estimate, LIMITS.maxReserveCredits),
      `${model.name} · ${parsed.data.messages.length} messages`,
    );

    const apiKey = OPENROUTER_API_KEY.value();
    // Aborting on disconnect stops us paying for tokens nobody will read.
    const abortController = new AbortController();
    const onClientGone = () => abortController.abort();
    response?.signal.addEventListener("abort", onClientGone, { once: true });

    let usage: ReturnType<typeof parseUsagePayload> = null;
    let streamed = false;
    let clientGone = false;
    const buffered: string[] = [];

    try {
      for await (const data of streamChatCompletion({
        apiKey,
        payload: sanitized.payload,
        signal: abortController.signal,
      })) {
        const parsedChunk = safeParse(data);
        const chunkUsage = parseUsagePayload(parsedChunk);
        if (chunkUsage) usage = chunkUsage;

        streamed = true;
        if (response) {
          // `sendChunk` is a no-op when the client didn't ask to stream, so this
          // is safe either way. `false` means the client is gone.
          const delivered = await response.sendChunk({ chunk: data });
          if (!delivered) {
            clientGone = true;
            abortController.abort();
            break;
          }
        } else {
          buffered.push(data);
        }
      }

      // Billing is token-based: tokens × the model tier's multiplier. The
      // provider's own USD cost is kept on the ledger for margin reporting but
      // never used to compute the charge.
      const actualCredits = usage
        ? creditsForTokens(usage.totalTokens, model.tier)
        : 0;

      const settled = await settleReservation(uid, {
        reservationId,
        actualCredits,
        modelId: model.id,
        note: `${model.name} · ${usage?.totalTokens ?? 0} tokens`,
        usage: usage ?? undefined,
      });

      logger.info("chat settled", {
        uid,
        model: model.id,
        plan,
        reserved: estimate,
        charged: settled.charged,
        streamed,
        clientGone,
      });

      return {
        chunks: buffered,
        model: model.id,
        creditsCharged: settled.charged,
        balance: settled.balance,
        usage: usage ?? null,
      };
    } catch (error) {
      // Refund in full when the stream failed before producing any usage.
      try {
        await settleReservation(uid, {
          reservationId,
          actualCredits: usage ? creditsForTokens(usage.totalTokens, model.tier) : 0,
          modelId: model.id,
          note: streamed
            ? `${model.name} · interrupted`
            : `${model.name} · failed`,
          usage: usage ?? undefined,
        });
      } catch (settleError) {
        logger.error("failed to settle after stream error", { uid, settleError });
      }
      throw toHttpsError(error);
    } finally {
      response?.signal.removeEventListener("abort", onClientGone);
    }
  },
);

function safeParse(data: string): unknown {
  try {
    return JSON.parse(data);
  } catch {
    return null;
  }
}

/** Model catalog for the picker, filtered to what this caller may actually use. */
export const listModels = onCall(
  { region: REGION, cors: true, enforceAppCheck: true },
  async (request: CallableRequest<unknown>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to load models.");
    await ensureAccount(uid);
    const account = await getAccount(uid);
    const allowed = planConfig(account.plan).maxModelTier;
    const rank = { flash: 0, plus: 1, max: 2 } as const;
    return {
      models: publicCatalog().filter(
        (model) => rank[model.tier as keyof typeof rank] <= rank[allowed],
      ),
    };
  },
);
