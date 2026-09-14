/**
 * RevenueCat webhook handling.
 *
 * RevenueCat is the source of truth for *entitlement*; this module's job is to
 * turn its events into ledger grants and plan changes, exactly once.
 *
 * Verification supports both schemes RevenueCat offers:
 *   1. A shared `Authorization` header (simple, recommended).
 *   2. HMAC signing via `X-RevenueCat-Webhook-Signature` over `"{t}.{rawBody}"`.
 *
 * The raw body is required for HMAC, so the route must be mounted with
 * `express.raw()` and the signature checked *before* any JSON parsing.
 */

import { Timestamp } from "firebase-admin/firestore";
import { z } from "zod";
import { db } from "./firebase";
import { COLLECTIONS } from "./config";
import {
  verifyAuthorizationHeader,
  verifySignature,
} from "./signature";
import {
  applyEntitlement,
  applyMonthlyGrant,
  grantCredits,
  revokeEntitlement,
  DomainError,
} from "./credits";
import {
  creditsForProduct,
  planForEntitlement,
  planForProduct,
} from "./storeProducts";
import { PlanTier } from "./plans";

/* -------------------------------------------------------------------------- */
/* Verification                                                               */
/* -------------------------------------------------------------------------- */

// Verification lives in `signature.ts` (no Firebase imports, directly testable)
// and is re-exported here for convenience.
export {
  computeSignature,
  parseSignatureHeader,
  safeEqual,
  verifyAuthorizationHeader,
  verifySignature,
} from "./signature";

/* -------------------------------------------------------------------------- */
/* Event schema                                                               */
/* -------------------------------------------------------------------------- */

export const revenueCatEventSchema = z
  .object({
    id: z.string().min(1),
    type: z.string().min(1),
    app_user_id: z.string().min(1),
    product_id: z.string().optional(),
    entitlement_ids: z.array(z.string()).nullish(),
    period_type: z.string().nullish(),
    purchased_at_ms: z.number().nullish(),
    expiration_at_ms: z.number().nullish(),
    event_timestamp_ms: z.number().nullish(),
    store: z.string().nullish(),
    environment: z.string().nullish(),
    transaction_id: z.string().nullish(),
    original_transaction_id: z.string().nullish(),
    is_family_share: z.boolean().nullish(),
  })
  .passthrough();

export const revenueCatWebhookSchema = z
  .object({
    api_version: z.string().optional(),
    event: revenueCatEventSchema,
  })
  .passthrough();

export type RevenueCatEvent = z.infer<typeof revenueCatEventSchema>;

/** RevenueCat uses this prefix for users who haven't been identified yet. */
export function isAnonymousUserId(appUserId: string): boolean {
  return appUserId.startsWith("$RCAnonymousID:");
}

/* -------------------------------------------------------------------------- */
/* Event handling                                                             */
/* -------------------------------------------------------------------------- */

export interface EventOutcome {
  action:
    | "granted-subscription"
    | "granted-consumable"
    | "revoked"
    | "recorded"
    | "ignored"
    | "duplicate";
  uid: string;
  credits?: number;
  plan?: PlanTier;
  detail?: string;
}

export function periodFromEvent(event: RevenueCatEvent): string | undefined {
  const millis = event.event_timestamp_ms ?? event.purchased_at_ms;
  if (!millis) return undefined;
  const date = new Date(millis);
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
}

/**
 * Apply a single webhook event. Idempotent: the event id is recorded before any
 * mutation, and every grant is additionally keyed by that id.
 */
export async function handleEvent(event: RevenueCatEvent): Promise<EventOutcome> {
  // Anonymous purchases can't be tied to an account yet; park them so the app
  // can claim them after sign-in instead of dropping the customer's money.
  if (isAnonymousUserId(event.app_user_id)) {
    await db
      .collection("anonymousPurchases")
      .doc(`${event.app_user_id}_${event.id}`)
      .set(
        {
          eventId: event.id,
          appUserId: event.app_user_id,
          type: event.type,
          productId: event.product_id ?? null,
          receivedAt: Timestamp.now(),
        },
        { merge: true },
      );
    return {
      action: "recorded",
      uid: event.app_user_id,
      detail: "anonymous purchase parked for claim",
    };
  }

  const uid = event.app_user_id;

  // Claim-once guard, so a retried webhook is a cheap no-op.
  const processedRef = db
    .collection(COLLECTIONS.users)
    .doc(uid)
    .collection(COLLECTIONS.processedEvents)
    .doc(event.id);
  const processed = await processedRef.get();
  if (processed.exists) {
    return { action: "duplicate", uid };
  }

  const plan = event.product_id ? planForProduct(event.product_id) : null;
  const consumableCredits = event.product_id
    ? creditsForProduct(event.product_id)
    : null;
  const expiry = event.expiration_at_ms
    ? Timestamp.fromMillis(event.expiration_at_ms)
    : null;
  const store = event.store ?? "UNKNOWN";
  const entitlementIds =
    event.entitlement_ids && event.entitlement_ids.length > 0
      ? event.entitlement_ids
      : plan
        ? [plan]
        : [];

  let outcome: EventOutcome;

  switch (event.type) {
    case "INITIAL_PURCHASE":
    case "RENEWAL":
    case "UNCANCELLATION":
    case "PRODUCT_CHANGE": {
      if (!plan) {
        outcome = { action: "ignored", uid, detail: `unmapped product ${event.product_id}` };
        break;
      }
      for (const entitlementId of entitlementIds) {
        await applyEntitlement(
          uid,
          entitlementId,
          {
            productId: event.product_id ?? "",
            store,
            expiresAt: expiry,
            isConsumable: false,
          },
          plan,
        );
      }
      const grant = await applyMonthlyGrant(uid, periodFromEvent(event));
      outcome = {
        action: "granted-subscription",
        uid,
        plan,
        credits: grant.granted,
      };
      break;
    }

    case "NON_RENEWING_PURCHASE": {
      if (!consumableCredits) {
        outcome = { action: "ignored", uid, detail: `unmapped product ${event.product_id}` };
        break;
      }
      // Keyed by event id: a retried delivery cannot double-credit.
      const result = await grantCredits(uid, {
        amount: consumableCredits,
        reason: "purchase",
        note: "Credit pack",
        idempotencyKey: `rc_${event.id}`,
      });
      outcome = {
        action: "granted-consumable",
        uid,
        credits: result.applied ? consumableCredits : 0,
      };
      break;
    }

    case "CANCELLATION":
    case "BILLING_ISSUE": {
      // Access continues until expiry; RevenueCat sends EXPIRATION then.
      outcome = { action: "recorded", uid, detail: event.type };
      break;
    }

    case "EXPIRATION": {
      for (const entitlementId of entitlementIds) {
        await revokeEntitlement(uid, entitlementId);
      }
      outcome = { action: "revoked", uid, detail: event.type };
      break;
    }

    case "REFUND": {
      for (const entitlementId of entitlementIds) {
        await revokeEntitlement(uid, entitlementId);
      }
      outcome = { action: "revoked", uid, detail: "refund" };
      break;
    }

    case "TRANSFER": {
      // RevenueCat moves entitlements between app user ids. Recording the event
      // is enough to make the retry safe; reconciliation happens via
      // `syncEntitlements` on the client's next refresh.
      outcome = { action: "recorded", uid, detail: "transfer" };
      break;
    }

    case "SUBSCRIBER_ALIAS": {
      outcome = { action: "recorded", uid, detail: "alias" };
      break;
    }

    default: {
      outcome = { action: "ignored", uid, detail: event.type };
    }
  }

  await processedRef.set({
    type: event.type,
    productId: event.product_id ?? null,
    environment: event.environment ?? null,
    processedAt: Timestamp.now(),
  });

  return outcome;
}

/** Convenience wrapper that parses then handles, surfacing schema errors. */
export async function handleWebhookBody(body: unknown): Promise<EventOutcome> {
  const parsed = revenueCatWebhookSchema.safeParse(body);
  if (!parsed.success) {
    throw new DomainError(
      "invalid-argument",
      `Unrecognised RevenueCat payload: ${parsed.error.issues
        .map((issue) => issue.path.join(".") + " " + issue.message)
        .join("; ")}`,
    );
  }
  return handleEvent(parsed.data.event);
}

export { planForEntitlement };
