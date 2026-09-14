import { describe, expect, it } from "vitest";
import {
  computeSignature,
  parseSignatureHeader,
  safeEqual,
  verifyAuthorizationHeader,
  verifySignature,
} from "../src/signature";

const SECRET = "rc_webhook_signing_secret_value";
const BODY = JSON.stringify({ event: { id: "evt_1", type: "INITIAL_PURCHASE" } });

describe("safeEqual", () => {
  it("matches identical strings and rejects different ones", () => {
    expect(safeEqual("abc", "abc")).toBe(true);
    expect(safeEqual("abc", "abd")).toBe(false);
  });

  it("rejects different lengths without throwing", () => {
    expect(safeEqual("abc", "abcd")).toBe(false);
  });

  it("handles empty strings", () => {
    expect(safeEqual("", "")).toBe(true);
  });
});

describe("verifyAuthorizationHeader", () => {
  it("accepts the exact shared secret", () => {
    expect(verifyAuthorizationHeader("s3cret", "s3cret")).toBe(true);
  });

  it("rejects missing or wrong credentials", () => {
    expect(verifyAuthorizationHeader(undefined, "s3cret")).toBe(false);
    expect(verifyAuthorizationHeader("", "s3cret")).toBe(false);
    expect(verifyAuthorizationHeader("nope", "s3cret")).toBe(false);
  });

  it("fails closed when no secret is configured", () => {
    // An unset secret must never authenticate a caller.
    expect(verifyAuthorizationHeader("anything", "")).toBe(false);
  });
});

describe("parseSignatureHeader", () => {
  it("parses t and v1", () => {
    expect(parseSignatureHeader("t=1700000000,v1=deadbeef")).toEqual({
      timestamp: 1_700_000_000,
      signature: "deadbeef",
    });
  });

  it("tolerates extra segments and whitespace", () => {
    expect(parseSignatureHeader(" t=1700000000 , v1=abc , v2=zzz ")).toEqual({
      timestamp: 1_700_000_000,
      signature: "abc",
    });
  });

  it("returns null for malformed input", () => {
    expect(parseSignatureHeader("")).toBeNull();
    expect(parseSignatureHeader("v1=abc")).toBeNull();
    expect(parseSignatureHeader("t=notanumber,v1=abc")).toBeNull();
  });
});

describe("verifySignature", () => {
  it("accepts a correctly signed body within tolerance", () => {
    const now = 1_700_000_000;
    const signature = computeSignature(BODY, now, SECRET);
    expect(
      verifySignature(BODY, `t=${now},v1=${signature}`, SECRET, now),
    ).toBe(true);
  });

  it("rejects a tampered body", () => {
    const now = 1_700_000_000;
    const signature = computeSignature(BODY, now, SECRET);
    const tampered = BODY.replace("evt_1", "evt_2");
    expect(
      verifySignature(tampered, `t=${now},v1=${signature}`, SECRET, now),
    ).toBe(false);
  });

  it("rejects the wrong secret", () => {
    const now = 1_700_000_000;
    const signature = computeSignature(BODY, now, SECRET);
    expect(
      verifySignature(BODY, `t=${now},v1=${signature}`, "other_secret", now),
    ).toBe(false);
  });

  it("rejects stale timestamps to prevent replay", () => {
    const signedAt = 1_700_000_000;
    const signature = computeSignature(BODY, signedAt, SECRET);
    const muchLater = signedAt + 3600; // an hour later
    expect(
      verifySignature(BODY, `t=${signedAt},v1=${signature}`, SECRET, muchLater),
    ).toBe(false);
  });

  it("accepts clock skew inside the tolerance window", () => {
    const signedAt = 1_700_000_000;
    const signature = computeSignature(BODY, signedAt, SECRET);
    expect(
      verifySignature(BODY, `t=${signedAt},v1=${signature}`, SECRET, signedAt + 60),
    ).toBe(true);
  });

  it("fails closed on a missing header or secret", () => {
    expect(verifySignature(BODY, undefined, SECRET)).toBe(false);
    expect(verifySignature(BODY, "t=1700000000,v1=abc", "")).toBe(false);
  });

  it("rejects a well-formed header with no signature", () => {
    expect(verifySignature(BODY, "t=1700000000", SECRET, 1_700_000_000)).toBe(false);
  });
});
