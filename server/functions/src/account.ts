/**
 * Account-facing callables: read the balance, and reconcile entitlements with
 * RevenueCat when the client asks (e.g. "Restore purchases" or app foreground).
 */

import { onCall, HttpsError, CallableRequest } from "firebase-functions/v2/https";
import { logger } from "firebase-functions/v2";
import { Timestamp } from "firebase-admin/firestore";
import { REGION, REVENUECAT_API_KEY } from "./config";
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
