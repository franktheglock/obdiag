/**
 * RevenueCat REST API client.
 *
 * Used to reconcile entitlements when a webhook may have been missed. RevenueCat
 * recommends this "sync from the API" pattern because it normalises every event
 * into one canonical shape.
 *
 * API reference: GET /v1/subscribers/{app_user_id}
 */

import { REVENUECAT_API_KEY } from "./config";

const API_BASE = "https://api.revenuecat.com/v1";

export interface SubscriberEntitlement {
  expiresDate: string | null;
  productIdentifier: string | null;
  purchaseDate: string | null;
}

export interface Subscriber {
  originalAppUserId: string;
  entitlements: Record<string, SubscriberEntitlement>;
  subscriptions: Record<string, { expiresDate: string | null; store: string | null }>;
}

export async function fetchSubscriber(appUserId: string): Promise<Subscriber | null> {
  const apiKey = REVENUECAT_API_KEY.value();
  if (!apiKey) return null;

  const response = await fetch(
    `${API_BASE}/subscribers/${encodeURIComponent(appUserId)}`,
    {
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
    },
  );

  if (response.status === 404) return null;
  if (!response.ok) {
    throw new Error(`RevenueCat responded ${response.status}`);
  }

  const body = (await response.json()) as {
    subscriber?: Record<string, unknown>;
  };
  const subscriber = body.subscriber;
  if (!subscriber) return null;

  const entitlements: Record<string, SubscriberEntitlement> = {};
  const rawEntitlements = subscriber.entitlements;
  if (rawEntitlements && typeof rawEntitlements === "object") {
    for (const [key, value] of Object.entries(
      rawEntitlements as Record<string, Record<string, unknown>>,
    )) {
      entitlements[key] = {
        expiresDate: (value.expires_date as string) ?? null,
        productIdentifier: (value.product_identifier as string) ?? null,
        purchaseDate: (value.purchase_date as string) ?? null,
      };
    }
  }

  const subscriptions: Subscriber["subscriptions"] = {};
  const rawSubscriptions = subscriber.subscriptions;
  if (rawSubscriptions && typeof rawSubscriptions === "object") {
    for (const [key, value] of Object.entries(
      rawSubscriptions as Record<string, Record<string, unknown>>,
    )) {
      subscriptions[key] = {
        expiresDate: (value.expires_date as string) ?? null,
        store: (value.store as string) ?? null,
      };
    }
  }

  return {
    originalAppUserId: (subscriber.original_app_user_id as string) ?? appUserId,
    entitlements,
    subscriptions,
  };
}
