/**
 * Cloud Functions entry point.
 *
 * Deployed surface:
 *   - chat               (callable, streaming)  AI proxy, the only OpenRouter caller
 *   - listModels         (callable)             plan-filtered model catalog
 *   - getAccountSummary  (callable)             balance, plan, entitlements
 *   - syncEntitlements   (callable)             RevenueCat reconciliation
 *   - revenuecatWebhook  (HTTPS)                store events → credits
 */

import { onRequest } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";
import {
  REGION,
  REVENUECAT_WEBHOOK_AUTH,
  REVENUECAT_WEBHOOK_SIGNING_SECRET,
} from "./config";
import { handleWebhookBody, verifyAuthorizationHeader, verifySignature } from "./revenuecat";
import { DomainError } from "./credits";

export { chat, listModels } from "./ai";
export { getAccountSummary, syncEntitlements } from "./account";

/**
 * RevenueCat webhook receiver.
 *
 * Deliberately an HTTP function rather than a callable: RevenueCat is a server,
 * not a signed-in client, so it can't present a Firebase ID token. Access is
 * controlled by the shared authorization header and/or an HMAC signature, both
 * configured in the RevenueCat dashboard.
 *
 * Returns 200 for success and duplicates (so RevenueCat stops retrying), 401 for
 * bad credentials, and 500 for transient processing failures (so it retries).
 */
export const revenuecatWebhook = onRequest(
  {
    region: REGION,
    cors: false,
    secrets: [REVENUECAT_WEBHOOK_AUTH, REVENUECAT_WEBHOOK_SIGNING_SECRET],
  },
  async (request, response) => {
    if (request.method !== "POST") {
      response.status(405).send("Method Not Allowed");
      return;
    }

    // `rawBody` is required for HMAC verification — re-serialising parsed JSON
    // changes the bytes and would fail the signature check.
    const rawBody =
      request.rawBody?.toString("utf8") ?? JSON.stringify(request.body ?? {});

    const authorized =
      verifyAuthorizationHeader(
        request.get("authorization") ?? undefined,
        REVENUECAT_WEBHOOK_AUTH.value(),
      ) ||
      verifySignature(
        rawBody,
        request.get("x-revenuecat-webhook-signature") ?? undefined,
        REVENUECAT_WEBHOOK_SIGNING_SECRET.value(),
      );

    if (!authorized) {
      logger.warn("revenuecat webhook rejected", {
        hasAuthHeader: Boolean(request.get("authorization")),
        hasSignature: Boolean(request.get("x-revenuecat-webhook-signature")),
      });
      response.status(401).send("unauthorized");
      return;
    }

    let body: unknown;
    try {
      body = JSON.parse(rawBody);
    } catch {
      response.status(400).send("invalid json");
      return;
    }

    try {
      const outcome = await handleWebhookBody(body);
      logger.info("revenuecat webhook handled", outcome);
      response.status(200).json({ ok: true, ...outcome });
    } catch (error) {
      if (error instanceof DomainError && error.code === "invalid-argument") {
        // A payload we can't understand will never succeed on retry.
        logger.error("revenuecat webhook payload rejected", { error: error.message });
        response.status(200).json({ ok: false, reason: "unrecognised payload" });
        return;
      }
      logger.error("revenuecat webhook failed", { error });
      // 500 tells RevenueCat to retry with backoff. Handlers are idempotent.
      response.status(500).send("processing failed");
    }
  },
);
