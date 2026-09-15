# OBDiag backend

Server-side component that makes the subscription model coherent: the
OpenRouter key lives here, usage is metered here, and purchases are verified
here. Without it, the app sold credits that the user could only spend by also
paying OpenRouter themselves.

```
 iOS app                          Firebase                        OpenRouter
┌─────────────────────┐    ┌──────────────────────────┐    ┌──────────────────┐
│ Sign in with Apple  │───▶│ Firebase Auth            │    │                  │
│ (ASAuthorization)   │    │  + App Check (App Attest)│    │                  │
├─────────────────────┤    ├──────────────────────────┤    │                  │
│ RevenueCat SDK      │───▶│ RevenueCat (entitlements)│    │                  │
│  purchase/restore   │    │        │ webhook          │    │                  │
├─────────────────────┤    │        ▼                  │    │                  │
│ CallableClient      │───▶│ revenuecatWebhook ──┐     │    │                  │
│  .stream("chat")    │    │                     ▼     │    │                  │
│                     │    │  Firestore: users/{uid}   │    │                  │
│                     │    │    credits, plan, ledger  │    │                  │
│                     │    │        ▲                  │    │                  │
│                     │    │        │ reserve/settle   │    │                  │
│                     │    │  chat (callable, streaming)───▶│ chat/completions │
└─────────────────────┘    └──────────────────────────┘    └──────────────────┘
```

## Why the agent loop stays on the device

Tools read live OBD-II data and fault codes, which only exist on the phone.
So the client keeps running the agent loop and calls the backend once per model
turn. The backend is a **stateless completion proxy**: it authorises, meters,
and forwards. That keeps it simple and keeps vehicle data on-device.

## Trust boundaries

| Concern | Who decides |
| --- | --- |
| Which models exist and their tier | **Server** (`models.ts`), served via `listModels` |
| Which models a plan may call | **Server** (`authorize.ts`) |
| Credit balance and charges | **Server** (`credits.ts`) |
| Entitlements and expiry | **RevenueCat**, mirrored into Firestore by webhook |
| Tool execution (live data) | **Device** — never the server |
| Request shape | **Server** re-validates and rebuilds (`request.ts`) |

The client is treated as hostile. `sanitizeRequest` rebuilds the OpenRouter
payload from an allow-list, so unknown fields (routing directives, fallback
model lists, provider plugins) are dropped rather than passed through; tool
definitions are capped (`web_search.max_results` ≤ 5); `max_tokens` is clamped
to the plan ceiling; and oversized image attachments are rejected. Firestore
rules deny all client access, so there is no client-side path to a balance.

## Credit lifecycle: reserve, then settle

The real cost of a completion isn't known until the stream ends, so:

1. **Estimate** pessimistically from prompt size and the plan's max output.
2. **Reserve** atomically in a Firestore transaction. Fails with
   `resource-exhausted` if the balance can't cover it.
3. **Stream** OpenRouter's SSE frames through to the device, verbatim.
4. **Settle** against the provider-reported `usage.cost`, refunding any
   over-reserve. A stream that fails before producing usage is refunded in full.

If the client disconnects mid-stream, `response.signal` fires and the upstream
request is aborted, so you stop paying for tokens nobody will read.

## Idempotency

Money must not move twice on a retry.

- **Ledger documents are keyed by idempotency key**, so a duplicate grant is
  detected by document id rather than a query.
- **RevenueCat events** are recorded under `users/{uid}/processedEvents/{eventId}`
  before any mutation, and grants additionally use `rc_{eventId}` as the ledger key.
- **Settling a reservation twice** is a no-op.
- **Monthly grants** are stamped with a `lastGrantPeriod` (`YYYY-MM`), so the
  webhook path and the lazy on-read safety net converge on one grant per month.

## Webhook verification

`revenuecatWebhook` is an HTTP function (RevenueCat is a server, not a signed-in
client). It accepts either the shared `Authorization` header or HMAC signing via
`X-RevenueCat-Webhook-Signature`, compared in constant time, with a ±5 minute
tolerance. HMAC is computed over `"{t}.{rawBody}"` using the raw bytes, so the
route reads `request.rawBody` rather than re-serialising parsed JSON.

Returns `200` for success **and duplicates** (so RevenueCat stops retrying),
`401` for bad credentials, and `500` for transient failures (so it retries).
Webhooks require RevenueCat's Pro plan.

## Data model

```
users/{uid}
  plan: "free" | "plus" | "pro"
  credits: number                     # authoritative balance
  lifetimeGranted, lifetimeSpent: number
  lastGrantPeriod: "YYYY-MM" | null
  entitlements: { plus|pro: { productId, store, expiresAt, isConsumable } }
  createdAt, updatedAt

users/{uid}/ledger/{idempotencyKey}   # append-only record of every movement
  amount, reason, note, balanceAfter, modelId?, usage?, createdAt

users/{uid}/reservations/{id}         # in-flight holds
  amount, settled, actualCredits?, createdAt, settledAt?

users/{uid}/processedEvents/{eventId} # webhook dedupe
anonymousPurchases/{appUserId}_{eventId}  # purchases made before sign-in
```

## Functions

| Name | Type | Auth | Purpose |
| --- | --- | --- | --- |
| `chat` | callable (streaming) | Auth + App Check | AI proxy, metering, model gating |
| `listModels` | callable | Auth + App Check | Plan-filtered model catalog |
| `getAccountSummary` | callable | Auth + App Check | Balance, plan, entitlements |
| `syncEntitlements` | callable | Auth + App Check | Reconcile with RevenueCat REST |
| `revenuecatWebhook` | HTTPS | Shared secret / HMAC | Store events → credits |

## Cost model

Credits are token-pegged, not dollar-pegged:

```
credits = max(1, ceil( total_tokens ÷ 1,000 × MODEL_TIER_MULTIPLIER[tier] ))
                   flash 0.33 · plus 1 · max 5
```

So a credit is a predictable unit of model work — 1,000 tokens at the base
rate — and the tier multiplier encodes what the model costs to run rather than
exposing provider pricing to the user. The provider's own USD cost is still
recorded on each ledger entry for margin reporting, but it never determines the
charge.

The plan decides the monthly allowance and the highest model tier, not the burn
rate. See [`SHIPPING.md`](SHIPPING.md) for the margin analysis — **the current
allowances are ~5× too generous, and one model is in the wrong tier.**
