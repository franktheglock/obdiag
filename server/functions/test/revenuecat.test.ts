import { describe, expect, it } from "vitest";
import {
  isAnonymousUserId,
  periodFromEvent,
  revenueCatEventSchema,
  revenueCatWebhookSchema,
} from "../src/revenuecat";

const validEvent = {
  id: "evt_abc123",
  type: "INITIAL_PURCHASE",
  app_user_id: "firebase-uid-1",
  product_id: "com.obdiag.plus.monthly",
  entitlement_ids: ["plus"],
  store: "APP_STORE",
  environment: "PRODUCTION",
  event_timestamp_ms: Date.UTC(2026, 8, 14, 12, 0, 0),
  expiration_at_ms: Date.UTC(2026, 9, 14, 12, 0, 0),
};

describe("revenueCatWebhookSchema", () => {
  it("accepts a realistic payload", () => {
    const result = revenueCatWebhookSchema.safeParse({
      api_version: "1.0",
      event: validEvent,
    });
    expect(result.success).toBe(true);
  });

  it("preserves unknown fields for forward compatibility", () => {
    const result = revenueCatWebhookSchema.safeParse({
      api_version: "1.0",
      event: { ...validEvent, some_future_field: "value" },
    });
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.event).toHaveProperty("some_future_field", "value");
    }
  });

  it("requires an id, type and app_user_id", () => {
    expect(
      revenueCatEventSchema.safeParse({ type: "RENEWAL", app_user_id: "u" }).success,
    ).toBe(false);
    expect(
      revenueCatEventSchema.safeParse({ id: "e", app_user_id: "u" }).success,
    ).toBe(false);
    expect(revenueCatEventSchema.safeParse({ id: "e", type: "RENEWAL" }).success).toBe(
      false,
    );
  });

  it("rejects a payload with no event object", () => {
    expect(revenueCatWebhookSchema.safeParse({ api_version: "1.0" }).success).toBe(false);
  });
});

describe("isAnonymousUserId", () => {
  it("detects RevenueCat anonymous ids", () => {
    expect(isAnonymousUserId("$RCAnonymousID:9f2c4a")).toBe(true);
  });

  it("treats a Firebase uid as identified", () => {
    expect(isAnonymousUserId("kJ3n8Xq2LmP")).toBe(false);
  });
});

describe("periodFromEvent", () => {
  it("derives a UTC billing period from the event timestamp", () => {
    expect(periodFromEvent({ ...validEvent, event_timestamp_ms: Date.UTC(2026, 8, 14) })).toBe(
      "2026-09",
    );
  });

  it("pads single-digit months", () => {
    expect(periodFromEvent({ ...validEvent, event_timestamp_ms: Date.UTC(2026, 0, 3) })).toBe(
      "2026-01",
    );
  });

  it("falls back to the purchase timestamp", () => {
    expect(
      periodFromEvent({
        ...validEvent,
        event_timestamp_ms: null,
        purchased_at_ms: Date.UTC(2026, 11, 31),
      }),
    ).toBe("2026-12");
  });

  it("returns undefined when no timestamp is present", () => {
    expect(
      periodFromEvent({ ...validEvent, event_timestamp_ms: null, purchased_at_ms: null }),
    ).toBeUndefined();
  });

  it("rolls over the month correctly at a year boundary", () => {
    expect(periodFromEvent({ ...validEvent, event_timestamp_ms: Date.UTC(2027, 0, 1) })).toBe(
      "2027-01",
    );
  });
});
