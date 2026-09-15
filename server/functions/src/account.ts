/**
 * Account-facing callables: read the balance, and reconcile entitlements with
 * RevenueCat when the client asks (e.g. "Restore purchases" or app foreground).
 */

import { onCall, HttpsError, CallableRequest } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";
import { Timestamp } from "firebase-admin/firestore";
import { COLLECTIONS, REGION, REVENUECAT_API_KEY } from "./config";
import { db } from "./firebase";
import {
  accountSummary,
  applyEntitlement,
  applyMonthlyGrant,
  ensureAccount,
  getAccount,
  revokeEntitlement,
  DomainError,
} from "./credits";
import { planForEntitlement } from "./storeProducts";
import { fetchSubscriber } from "./revenuecatApi";

/** Current balance, plan and entitlements. Cheap; safe to call on foreground. */
export const getAccountSummary = onCall(
  { region: REGION, cors: true, enforceAppCheck: true },
  async (request: CallableRequest<unknown>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
    await ensureAccount(uid);
    // Keep the free allowance current even if the app is never restarted.
    await applyMonthlyGrant(uid);
    return accountSummary(uid);
  },
);

/**
 * Reconcile plan and entitlements against RevenueCat's REST API.
 *
 * This is the recovery path when a webhook is lost, and the source of truth for
 * "Restore purchases". It never grants monthly credits directly — those stay
 * webhook/period driven so a sync loop can't farm allowances.
 */
export const syncEntitlements = onCall(
  {
    region: REGION,
    cors: true,
    enforceAppCheck: true,
    secrets: [REVENUECAT_API_KEY],
  },
  async (request: CallableRequest<unknown>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
    await ensureAccount(uid);

    let subscriber;
    try {
      subscriber = await fetchSubscriber(uid);
    } catch (error) {
      logger.error("revenuecat sync failed", { uid, error });
      throw new HttpsError(
        "unavailable",
        "Couldn't reach the store. Please try again.",
      );
    }

    if (!subscriber) {
      // No RevenueCat record: the account is genuinely free.
      await applyMonthlyGrant(uid);
      return accountSummary(uid);
    }

    const activeEntitlementIds = new Set<string>();
    for (const [entitlementId, entitlement] of Object.entries(subscriber.entitlements)) {
      const expiresAt = entitlement.expiresDate ? new Date(entitlement.expiresDate) : null;
      if (expiresAt && expiresAt.getTime() < Date.now()) continue; // lapsed
      activeEntitlementIds.add(entitlementId);
      const plan = planForEntitlement(entitlementId);
      await applyEntitlement(
        uid,
        entitlementId,
        {
          productId: entitlement.productIdentifier ?? "",
          store: "APP_STORE",
          expiresAt: expiresAt ? Timestamp.fromDate(expiresAt) : null,
          isConsumable: false,
        },
        plan,
      );
    }

    // Revoke anything we recorded that RevenueCat no longer considers active.
    const account = await getAccount(uid);
    for (const [entitlementId, entitlement] of Object.entries(account.entitlements)) {
      if (entitlement.isConsumable) continue;
      if (!activeEntitlementIds.has(entitlementId)) {
        await revokeEntitlement(uid, entitlementId);
      }
    }

    await applyMonthlyGrant(uid);
    return accountSummary(uid);
  },
);

export { DomainError };

/**
 * Recent credit activity for the subscribe screen.
 *
 * The balance itself comes from `getAccountSummary`; this exists because the
 * ledger is the only place the *history* lives, and the client has no direct
 * Firestore access. Without it the app would have to fall back to its local
 * ledger, which is never written on a managed account — so a customer would see
 * a purchase they had made but no record of it.
 *
 * The ledger is keyed by idempotency key rather than being ordered, so this
 * sorts by `createdAt` and caps the result. A single-field orderBy needs no
 * composite index.
 */
export const getLedger = onCall(
  { region: REGION, cors: true, enforceAppCheck: true },
  async (request: CallableRequest<{ limit?: number }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to continue.");
    await ensureAccount(uid);

    const requested = request.data?.limit ?? 25;
    const limit = Math.min(Math.max(Math.trunc(requested) || 25, 1), 100);

    const snapshot = await db
      .collection(COLLECTIONS.users)
      .doc(uid)
      .collection(COLLECTIONS.ledger)
      .orderBy("createdAt", "desc")
      .limit(limit)
      .get();

    return {
      entries: snapshot.docs.map((doc) => {
        const data = doc.data();
        const createdAt = data.createdAt as Timestamp | undefined;
        return {
          id: doc.id,
          amount: typeof data.amount === "number" ? data.amount : 0,
          reason: typeof data.reason === "string" ? data.reason : "adjustment",
          note: typeof data.note === "string" ? data.note : "",
          balanceAfter: typeof data.balanceAfter === "number" ? data.balanceAfter : 0,
          modelId: typeof data.modelId === "string" ? data.modelId : null,
          createdAt: createdAt ? createdAt.toMillis() : null,
        };
      }),
    };
  },
);
