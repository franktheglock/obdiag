# OBDiag server

Firebase project: Cloud Functions (Node 22, TypeScript), Firestore, Auth, App Check.

## Prerequisites

- Node 22+
- Firebase CLI: `npm i -g firebase-tools`
- A Firebase project on the **Blaze** (pay-as-you-go) plan. Cloud Functions
  require Blaze to make outbound calls to OpenRouter.
- A [RevenueCat](https://www.revenuecat.com/) account on the **Pro** plan
  (webhooks are a Pro feature).

## 1. Point the project at your Firebase project

Edit `server/.firebaserc`:

```json
{ "projects": { "default": "your-firebase-project-id" } }
```

Then update the matching values in the app:

- `OBDiag/Core/Backend/BackendConfig.swift` → `projectID`, `region`
- `server/functions/src/config.ts` → `REGION`

## 2. Install and verify

```sh
cd server/functions
npm install
npm run typecheck     # tsc --noEmit
npm test              # 75 unit tests, no emulator needed
```

## 3. Set secrets

These live in Cloud Secret Manager and never enter the app binary or the repo.

```sh
npx -y firebase-tools@latest functions:secrets:set OPENROUTER_API_KEY              # sk-or-v1-…
npx -y firebase-tools@latest functions:secrets:set REVENUECAT_WEBHOOK_AUTH         # any long random string
npx -y firebase-tools@latest functions:secrets:set REVENUECAT_WEBHOOK_SIGNING_SECRET  # from RevenueCat (if using HMAC)
npx -y firebase-tools@latest functions:secrets:set REVENUECAT_API_KEY              # sk_… (for syncEntitlements)
```

`OPENROUTER_API_KEY` is the one that actually pays for model usage. Set a
spending limit on it in the OpenRouter dashboard — it is the blast radius if a
bug lets requests through.

## 4. Enable Auth and App Check

**Auth:** enable the **Apple** provider in Firebase console → Authentication.
You'll need an Apple Services ID, team ID and key. See
[Firebase docs](https://firebase.google.com/docs/auth/ios/apple).

**App Check:** register the iOS app with the **App Attest** provider
(with DeviceCheck as fallback). The `chat` callable has `enforceAppCheck: true`,
so requests fail until this is configured.

App Attest requires a **paid** Apple Developer Program membership. Personal
teams cannot sign for `com.apple.developer.devicecheck.appattest-environment`,
which is why the entitlement is applied to **Release only** in `project.yml`:

| Config | Entitlement | App Check provider |
| --- | --- | --- |
| Debug | none | debug provider (prints a token at launch) |
| Release | App Attest | App Attest, DeviceCheck fallback |

So local development and simulator work on a personal team with no setup. For
simulator debugging, register the debug token printed at launch under
App Check → Apps → Manage debug tokens.

Before archiving for TestFlight or the App Store you need a paid team, the
**App Attest** capability enabled for the bundle id in the Apple Developer
portal, and a distribution profile that includes it. Archiving without it fails
loudly at signing, which is intentional — a Release build without App Attest
would produce an app whose assistant requests the server rejects.

## 5. Create the products

Create these in App Store Connect and import them into RevenueCat. The ids must
match `server/functions/src/storeProducts.ts` **and**
`OBDiag/Core/Models/SubscriptionModels.swift` exactly.

Subscriptions (RevenueCat entitlement ids `plus` / `pro`):

| Product ID | Tier |
| --- | --- |
| `com.obdiag.plus.monthly` | plus |
| `com.obdiag.plus.yearly` | plus |
| `com.obdiag.pro.monthly` | pro |
| `com.obdiag.pro.yearly` | pro |

Consumables:

| Product ID | Credits |
| --- | --- |
| `com.obdiag.credits.500` | 500 |
| `com.obdiag.credits.1500` | 1,500 |
| `com.obdiag.credits.4000` | 4,000 |

> **Read [`../docs/SHIPPING.md`](../docs/SHIPPING.md) before setting prices.**
> The current Pro credit allowance loses money.

## 6. Configure the RevenueCat webhook

RevenueCat dashboard → Integrations → Webhooks → Add new configuration.

- **URL:** `https://<region>-<project>.cloudfunctions.net/revenuecatWebhook`
  (printed by `npx -y firebase-tools@latest deploy`)
- **Authorization header:** the same value you set as `REVENUECAT_WEBHOOK_AUTH`
- **HMAC signing:** optional but recommended; store the secret as
  `REVENUECAT_WEBHOOK_SIGNING_SECRET`
- **Events:** at minimum `Initial Purchase`, `Renewal`, `Cancellation`,
  `Expiration`, `Non-Renewing Purchase`, `Refund`, `Product Change`,
  `Uncancellation`

## 7. Deploy

```sh
cd server
npx -y firebase-tools@latest deploy --only functions,firestore:rules,firestore:indexes
```

## 8. Local development

```sh
cd server/functions
npm run serve          # emulators: functions + firestore, with a UI
```

The Firestore emulator is enough to exercise the credit ledger. To test against
the RevenueCat webhook, POST a sample payload:

```sh
curl -X POST "http://127.0.0.1:5001/<project>/us-central1/revenuecatWebhook" \
  -H "Authorization: $REVENUECAT_WEBHOOK_AUTH" \
  -H "Content-Type: application/json" \
  -d '{"api_version":"1.0","event":{"id":"evt_test_1","type":"NON_RENEWING_PURCHASE","app_user_id":"test-uid","product_id":"com.obdiag.credits.500"}}'
```

## Layout

```
functions/src/
  index.ts         entry point: callables + webhook
  config.ts        secrets, limits, collection names
  firebase.ts      shared Admin SDK initialisation
  plans.ts         plan tiers, credit math (pure)
  models.ts        server-side model catalog (pure)
  storeProducts.ts product id → plan/credits map (pure)
  signature.ts     webhook verification (pure, no Firebase)
  request.ts       request validation + sanitisation (pure)
  credits.ts       ledger: reserve/settle/grant/entitlements
  authorize.ts     plan-based model gating
  openrouter.ts    streaming OpenRouter client
  ai.ts            the chat callable
  account.ts       account + RevenueCat reconciliation callables
  revenuecat.ts    webhook event handling
  revenuecatApi.ts RevenueCat REST client
functions/test/    75 unit tests for the pure modules
```
