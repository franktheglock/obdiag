/**
 * Webhook signature and header verification.
 *
 * Deliberately free of Firebase imports so it can be unit-tested directly — this
 * is security-critical code and shouldn't need an emulator to exercise.
 */

import { createHmac, timingSafeEqual } from "node:crypto";

/** ±5 minutes, per RevenueCat's guidance (covers clock skew, not retries). */
export const SIGNATURE_TOLERANCE_SECONDS = 300;

/** Constant-time string comparison that doesn't short-circuit on length. */
export function safeEqual(a: string, b: string): boolean {
  const bufferA = Buffer.from(a, "utf8");
  const bufferB = Buffer.from(b, "utf8");
  if (bufferA.length !== bufferB.length) {
    // Do a comparison anyway so the timing doesn't leak the length difference.
    timingSafeEqual(bufferA, bufferA);
    return false;
  }
  return timingSafeEqual(bufferA, bufferB);
}

export function verifyAuthorizationHeader(
  header: string | undefined,
  expected: string,
): boolean {
  if (!header || !expected) return false;
  return safeEqual(header, expected);
}

/** Parses `t=<unix>,v1=<hex>` into its parts. */
export function parseSignatureHeader(
  header: string,
): { timestamp: number; signature: string } | null {
  const parts = new Map<string, string>();
  for (const segment of header.split(",")) {
    const index = segment.indexOf("=");
    if (index === -1) continue;
    parts.set(segment.slice(0, index).trim(), segment.slice(index + 1).trim());
  }
  const rawTimestamp = parts.get("t");
  const signature = parts.get("v1");
  if (!rawTimestamp || !signature) return null;
  const timestamp = Number.parseInt(rawTimestamp, 10);
  if (!Number.isFinite(timestamp)) return null;
  return { timestamp, signature };
}

export function computeSignature(
  rawBody: string,
  timestamp: number,
  secret: string,
): string {
  return createHmac("sha256", secret).update(`${timestamp}.${rawBody}`).digest("hex");
}

export function verifySignature(
  rawBody: string,
  header: string | undefined,
  secret: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): boolean {
  if (!header || !secret) return false;
  const parsed = parseSignatureHeader(header);
  if (!parsed) return false;
  if (Math.abs(nowSeconds - parsed.timestamp) > SIGNATURE_TOLERANCE_SECONDS) {
    return false;
  }
  const expected = computeSignature(rawBody, parsed.timestamp, secret);
  return safeEqual(expected, parsed.signature);
}
