/**
 * The credit ledger — the authoritative record of what a user has paid for and
 * spent. Everything here is server-side; the client's copy is display-only.
 *
 * Design notes:
 *
 *  - **Atomic.** Balances move inside Firestore transactions, so concurrent
 *    requests from two devices can't both spend the same credits.
 *
 *  - **Idempotent.** Ledger documents are keyed by an idempotency key, so a
 *    retried RevenueCat webhook or a replayed settle can't double-grant or
 *    double-charge. Document-ID keying means no query is needed to detect the
 *    duplicate.
 *
 *  - **Reserve then settle.** We don't know a completion's real cost until the
 *    stream ends, so we reserve a pessimistic estimate, then reconcile against
 *    actual usage. The difference is refunded. A reservation that is never
 *    settled is still a real debit, which is the safe failure direction.
 */

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { db } from "./firebase";
import { COLLECTIONS, LIMITS } from "./config";
import { PlanTier, isPlanTier, planConfig, MODEL_TIER_MULTIPLIER } from "./plans";

export type CreditReason =
  | "welcome"
  | "monthlyGrant"
  | "purchase"
  | "subscription"
  | "chat"
  | "adjustment"
  | "refund";

export interface LedgerEntry {
  amount: number;
  reason: CreditReason;
  note: string;
  balanceAfter: number;
  modelId?: string;
  createdAt: Timestamp | FieldValue;
}

export interface Entitlement {
  productId: string;
  /** Store the entitlement came from, e.g. "APP_STORE". */
  store: string;
  expiresAt: Timestamp | null;
  /** True for consumable credit packs, which carry no recurring entitlement. */
  isConsumable: boolean;
}

export interface Account {
  uid: string;
  plan: PlanTier;
  credits: number;
  lifetimeGranted: number;
  lifetimeSpent: number;
  /** Billing period of the last monthly grant, as `YYYY-MM`. */
  lastGrantPeriod: string | null;
  entitlements: Record<string, Entitlement>;
  createdAt: Timestamp | FieldValue;
  updatedAt: Timestamp | FieldValue;
}

/** Thrown for expected, user-facing failures that map to HttpsError codes. */
export class DomainError extends Error {
  constructor(
    readonly code:
      | "unauthenticated"
      | "permission-denied"
      | "not-found"
      | "failed-precondition"
      | "resource-exhausted"
      | "invalid-argument"
      | "internal",
    message: string,
  ) {
    super(message);
    this.name = "DomainError";
  }
}

function userRef(uid: string) {
  return db.collection(COLLECTIONS.users).doc(uid);
}

function periodKey(date = new Date()): string {
  // UTC so the billing month is stable regardless of device timezone.
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
}

/* -------------------------------------------------------------------------- */
/* Account lifecycle                                                          */
/* -------------------------------------------------------------------------- */

/**
 * Create the user document on first sighting. Safe to call repeatedly.
 * Also applies the free-plan welcome bonus exactly once.
 */
export async function ensureAccount(uid: string): Promise<void> {
  const ref = userRef(uid);
  const snapshot = await ref.get();
  if (snapshot.exists) return;

  await db.runTransaction(async (tx) => {
    const fresh = await tx.get(ref);
    if (fresh.exists) return;

    const now = FieldValue.serverTimestamp();
    const account: Account = {
      uid,
      plan: "free",
      // The welcome bonus is written directly, keeping creation single-write.
      credits: 0,
      lifetimeGranted: 0,
      lifetimeSpent: 0,
      lastGrantPeriod: null,
      entitlements: {},
      createdAt: now,
      updatedAt: now,
    };
    tx.set(ref, account);

    const bonus = 100;
    tx.set(ref, {
      credits: bonus,
      lifetimeGranted: bonus,
      updatedAt: now,
    }, { merge: true });

    tx.set(ref.collection(COLLECTIONS.ledger).doc("welcome"), {
      amount: bonus,
      reason: "welcome" satisfies CreditReason,
      note: "Welcome to OBDiag",
      balanceAfter: bonus,
      createdAt: now,
    });
  });

  const logRef = db.collection(COLLECTIONS.usage).doc(uid);
  await logRef.set(
    { firstSeenAt: FieldValue.serverTimestamp() },
    { merge: true },
  );
}

export async function getAccount(uid: string): Promise<Account> {
  const snapshot = await userRef(uid).get();
  if (!snapshot.exists) {
    throw new DomainError("not-found", "Account not found. Sign in again.");
  }
  return snapshot.data() as Account;
}

export async function getBalance(uid: string): Promise<number> {
  return (await getAccount(uid)).credits;
}

/* -------------------------------------------------------------------------- */
/* Grants and spends                                                          */
/* -------------------------------------------------------------------------- */

export interface GrantOptions {
  amount: number;
  reason: CreditReason;
  note: string;
  modelId?: string;
  /**
   * Stable key making this grant idempotent. Use the RevenueCat event id for
   * webhook-driven grants so retries can't double-credit.
   */
  idempotencyKey?: string;
}

/**
 * Add credits. Returns the new balance, or the existing balance if this key was
 * already applied.
 */
export async function grantCredits(
  uid: string,
  options: GrantOptions,
): Promise<{ balance: number; applied: boolean }> {
  const { amount, reason, note, modelId, idempotencyKey } = options;
  if (!Number.isInteger(amount) || amount === 0) {
    throw new DomainError("invalid-argument", "Grant amount must be a non-zero integer.");
  }

  const ref = userRef(uid);

  return db.runTransaction(async (tx) => {
    // Every read has to happen before any write: Firestore throws
    // "transactions require all reads to be executed before all writes".
    const snapshot = await tx.get(ref);

    const entryId = idempotencyKey ?? ref.collection(COLLECTIONS.ledger).doc().id;
    const entryRef = ref.collection(COLLECTIONS.ledger).doc(entryId);
    const existing = await tx.get(entryRef);

    // A grant can legitimately arrive before the app has ever called in: a
    // consumable bought straight after install, before the first
    // getAccountSummary, or a webhook that simply beats the app to it. Treat the
    // account as new rather than throwing — the customer has already paid, and
    // RevenueCat gives up after five retries, so a failure loses their money.
    const isNewAccount = !snapshot.exists;
    const account: Account = isNewAccount
      ? {
          uid,
          plan: "free",
          credits: 0,
          lifetimeGranted: 0,
          lifetimeSpent: 0,
          lastGrantPeriod: null,
          entitlements: {},
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        }
      : (snapshot.data() as Account);

    if (existing.exists) {
      return { balance: account.credits, applied: false };
    }

    const balance = account.credits + amount;
    const entry: LedgerEntry = {
      amount,
      reason,
      note,
      balanceAfter: balance,
      modelId,
      createdAt: FieldValue.serverTimestamp(),
    };
    tx.set(entryRef, entry);
    tx.set(
      ref,
      {
        // A merge-set against a missing document only writes the fields given
        // here, so seed the base fields explicitly when creating the account.
        ...(isNewAccount
          ? {
              uid,
              plan: "free" as PlanTier,
              lifetimeSpent: 0,
              lastGrantPeriod: null,
              entitlements: {},
              createdAt: FieldValue.serverTimestamp(),
            }
          : {}),
        credits: balance,
        lifetimeGranted:
          amount > 0 ? account.lifetimeGranted + amount : account.lifetimeGranted,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    return { balance, applied: true };
  });
}

/* -------------------------------------------------------------------------- */
/* Reserve / settle                                                           */
/* -------------------------------------------------------------------------- */

export interface Reservation {
  id: string;
  amount: number;
  settled: boolean;
  createdAt: Timestamp | FieldValue;
}

/**
 * Hold credits for an in-flight request. Throws `resource-exhausted` when the
 * balance can't cover the estimate.
 */
export async function reserveCredits(
  uid: string,
  amount: number,
  note: string,
): Promise<string> {
  const capped = Math.min(Math.max(amount, 0), LIMITS.maxReserveCredits);
  if (capped <= 0) return "";

  const ref = userRef(uid);

  return db.runTransaction(async (tx) => {
    const snapshot = await tx.get(ref);
    if (!snapshot.exists) {
      throw new DomainError("not-found", "Account not found.");
    }
    const account = snapshot.data() as Account;
    if (account.credits < capped) {
      throw new DomainError(
        "resource-exhausted",
        "You're out of AI credits. Top up in Settings → Subscription.",
      );
    }

    const reservationRef = ref.collection(COLLECTIONS.reservations).doc();
    const balance = account.credits - capped;

    tx.set(reservationRef, {
      id: reservationRef.id,
      amount: capped,
      settled: false,
      note,
      createdAt: FieldValue.serverTimestamp(),
    });
    tx.set(
      ref,
      {
        credits: balance,
        lifetimeSpent: account.lifetimeSpent + capped,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    return reservationRef.id;
  });
}

export interface SettleOptions {
  reservationId: string;
  /** The real charge, derived from provider-reported usage. */
  actualCredits: number;
  modelId: string;
  note: string;
  usage?: { promptTokens: number; completionTokens: number; totalTokens: number; costUSD: number };
}

/**
 * Reconcile a reservation with actual usage. Refunds the unused portion, or
 * charges the overage. Idempotent: a second settle for the same reservation is
 * a no-op.
 */
export async function settleReservation(
  uid: string,
  options: SettleOptions,
): Promise<{ balance: number; charged: number }> {
  const { reservationId, actualCredits, modelId, note, usage } = options;

  // No reservation (free/routed-through-none) — nothing to reconcile.
  if (!reservationId) return { balance: await getBalance(uid), charged: 0 };

  const ref = userRef(uid);

  return db.runTransaction(async (tx) => {
    const snapshot = await tx.get(ref);
    if (!snapshot.exists) {
      throw new DomainError("not-found", "Account not found.");
    }
    const account = snapshot.data() as Account;

    const reservationRef = ref.collection(COLLECTIONS.reservations).doc(reservationId);
    const reservationSnapshot = await tx.get(reservationRef);
    if (!reservationSnapshot.exists) {
      // Reservation vanished; treat the already-taken debit as final.
      return { balance: account.credits, charged: 0 };
    }
    const reservation = reservationSnapshot.data() as Reservation;
    if (reservation.settled) {
      return { balance: account.credits, charged: reservation.amount };
    }

    const reserved = reservation.amount;
    const delta = actualCredits - reserved; // >0 means we under-reserved
    const balance = account.credits - delta;

    tx.set(
      reservationRef,
      {
        settled: true,
        actualCredits,
        settledAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    if (delta !== 0) {
      tx.set(
        ref,
        {
          credits: balance,
          lifetimeSpent:
            delta > 0 ? account.lifetimeSpent + delta : account.lifetimeSpent,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    }

    // One ledger row per settled request, recording the true charge.
    tx.set(ref.collection(COLLECTIONS.ledger).doc(`chat_${reservationId}`), {
      amount: -actualCredits,
      reason: "chat" satisfies CreditReason,
      note,
      balanceAfter: balance,
      modelId,
      usage: usage ?? null,
      createdAt: FieldValue.serverTimestamp(),
    });

    return { balance, charged: actualCredits };
  });
}

/* -------------------------------------------------------------------------- */
/* Entitlements and monthly grants                                            */
/* -------------------------------------------------------------------------- */

/**
 * Record a store entitlement and raise the plan if it outranks the current one.
 * Called from the RevenueCat webhook.
 */
export async function applyEntitlement(
  uid: string,
  entitlementId: string,
  entitlement: Entitlement,
  plan: PlanTier | null,
): Promise<void> {
  const ref = userRef(uid);
  await db.runTransaction(async (tx) => {
    const snapshot = await tx.get(ref);
    if (!snapshot.exists) {
      // Webhook may arrive before the app has ever signed in. Create a stub so
      // the credits aren't lost, and let the app claim it on first sign-in.
      tx.set(
        ref,
        {
          uid,
          plan: plan ?? "free",
          credits: 0,
          lifetimeGranted: 0,
          lifetimeSpent: 0,
          lastGrantPeriod: null,
          entitlements: { [entitlementId]: entitlement },
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      return;
    }

    const account = snapshot.data() as Account;
    const nextPlan =
      plan && planConfig(plan).rank > planConfig(account.plan).rank ? plan : account.plan;

    tx.set(
      ref,
      {
        plan: nextPlan,
        entitlements: { ...account.entitlements, [entitlementId]: entitlement },
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });
}

/**
 * Downgrade after an entitlement lapses. Recomputes the plan from whatever
 * entitlements remain active so a lapsed "plus" can't clobber an active "pro".
 */
export async function revokeEntitlement(
  uid: string,
  entitlementId: string,
): Promise<PlanTier> {
  const ref = userRef(uid);
  return db.runTransaction(async (tx) => {
    const snapshot = await tx.get(ref);
    if (!snapshot.exists) return "free";
    const account = snapshot.data() as Account;

    const entitlements = { ...account.entitlements };
    delete entitlements[entitlementId];

    let plan: PlanTier = "free";
    for (const [key, value] of Object.entries(entitlements)) {
      if (value.isConsumable) continue;
      const candidate = key.includes("pro")
        ? "pro"
        : key.includes("plus")
          ? "plus"
          : null;
      if (candidate && planConfig(candidate).rank > planConfig(plan).rank) {
        plan = candidate;
      }
    }

    tx.set(
      ref,
      { plan, entitlements, updatedAt: FieldValue.serverTimestamp() },
      { merge: true },
    );
    return plan;
  });
}

/**
 * Grant a plan's monthly allowance once per billing month.
 *
 * Both the RevenueCat webhook and the lazy on-read path call this with the same
 * period, and the period stamp makes it idempotent — so a renewal webhook and a
 * safety-net check can never both credit the same month.
 *
 * @param periodOverride Billing period (`YYYY-MM`) derived from the store event.
 *   Defaults to the current UTC month.
 */
export async function applyMonthlyGrant(
  uid: string,
  periodOverride?: string,
): Promise<{ granted: number; balance: number }> {
  const ref = userRef(uid);
  const period = periodOverride ?? periodKey();

  return db.runTransaction(async (tx) => {
    const snapshot = await tx.get(ref);
    if (!snapshot.exists) {
      throw new DomainError("not-found", "Account not found.");
    }
    const account = snapshot.data() as Account;
    if (account.lastGrantPeriod === period) {
      return { granted: 0, balance: account.credits };
    }

    const amount = planConfig(account.plan).monthlyCredits;
    const balance = account.credits + amount;
    const entryId = `grant_${period}_${account.plan}`;
    const entryRef = ref.collection(COLLECTIONS.ledger).doc(entryId);
    const existing = await tx.get(entryRef);
    if (existing.exists) {
      // Already granted for this period under this plan; just stamp the period.
      tx.set(ref, { lastGrantPeriod: period }, { merge: true });
      return { granted: 0, balance: account.credits };
    }

    tx.set(entryRef, {
      amount,
      reason: "monthlyGrant" satisfies CreditReason,
      note: `Monthly allowance · ${account.plan}`,
      balanceAfter: balance,
      createdAt: FieldValue.serverTimestamp(),
    });
    tx.set(
      ref,
      {
        credits: balance,
        lifetimeGranted: account.lifetimeGranted + amount,
        lastGrantPeriod: period,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    return { granted: amount, balance };
  });
}

/** Read-only view for the client. */
export async function accountSummary(uid: string) {
  const account = await getAccount(uid);
  return {
    plan: account.plan,
    credits: account.credits,
    lifetimeGranted: account.lifetimeGranted,
    lifetimeSpent: account.lifetimeSpent,
    lastGrantPeriod: account.lastGrantPeriod,
    entitlements: Object.fromEntries(
      Object.entries(account.entitlements).map(([key, value]) => [
        key,
        {
          productId: value.productId,
          store: value.store,
          isConsumable: value.isConsumable,
          expiresAt: value.expiresAt ? value.expiresAt.toMillis() : null,
        },
      ]),
    ),
    monthlyCredits: planConfig(account.plan).monthlyCredits,
    modelTierMultipliers: MODEL_TIER_MULTIPLIER,
  };
}

export { periodKey, isPlanTier };
