/**
 * Runtime configuration and secret declarations.
 *
 * Secrets are declared with `defineSecret` so they live in Cloud Secret Manager
 * and never appear in source, logs, or the client binary. Set them with:
 *
 *   firebase functions:secrets:set OPENROUTER_API_KEY
 *   firebase functions:secrets:set REVENUECAT_WEBHOOK_AUTH
 *   firebase functions:secrets:set REVENUECAT_WEBHOOK_SIGNING_SECRET
 *   firebase functions:secrets:set REVENUECAT_API_KEY
 */

import { defineSecret } from "firebase-functions/params";

/** The OpenRouter key that actually pays for model usage. Server-only. */
export const OPENROUTER_API_KEY = defineSecret("OPENROUTER_API_KEY");

/** Shared secret RevenueCat sends in the `Authorization` header. */
export const REVENUECAT_WEBHOOK_AUTH = defineSecret("REVENUECAT_WEBHOOK_AUTH");

/** Optional HMAC signing secret for `X-RevenueCat-Webhook-Signature`. */
export const REVENUECAT_WEBHOOK_SIGNING_SECRET = defineSecret(
  "REVENUECAT_WEBHOOK_SIGNING_SECRET",
);

/** RevenueCat secret API key (sk_…), used to reconcile entitlements. */
export const REVENUECAT_API_KEY = defineSecret("REVENUECAT_API_KEY");

export const ALL_SECRETS = [
  OPENROUTER_API_KEY,
  REVENUECAT_WEBHOOK_AUTH,
  REVENUECAT_WEBHOOK_SIGNING_SECRET,
  REVENUECAT_API_KEY,
];

export const REGION = "us-central1";
export const OPENROUTER_BASE = "https://openrouter.ai/api/v1";

/**
 * Firestore database id.
 *
 * Empty means the `(default)` database, which is what a Standard-edition
 * project has and is what this project is set up for.
 *
 * An **Enterprise-edition** database must have a *named* id — it can never be
 * `(default)` — so if you provision Enterprise you must also set
 * `FIRESTORE_DATABASE_ID`, and add `edition`, `database` and `location` to the
 * `firestore` block in `firebase.json`. Without this the functions would talk
 * to a database that does not exist, which fails at runtime rather than at
 * deploy.
 */
export const FIRESTORE_DATABASE_ID = process.env.FIRESTORE_DATABASE_ID?.trim() ?? "";

/** Sent to OpenRouter for attribution / dashboard analytics. */
export const APP_REFERER = "https://obdiag.app";
export const APP_TITLE = "OBDiag";

/** Hard request limits, independent of what the client asks for. */
export const LIMITS = {
  maxMessages: 80,
  maxMessageChars: 200_000,
  maxToolDefinitions: 24,
  maxImageBytes: 6_000_000,
  /** Ceiling on a single pre-flight reservation, to bound exposure. */
  maxReserveCredits: 2_000,
  streamTimeoutMs: 300_000,
} as const;

/** Firestore collection names, in one place. */
export const COLLECTIONS = {
  users: "users",
  ledger: "ledger",
  reservations: "reservations",
  processedEvents: "processedEvents",
  usage: "usage",
} as const;
