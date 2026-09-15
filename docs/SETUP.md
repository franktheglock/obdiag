# Setup — Firebase and RevenueCat

Everything here is optional to *run* the app: with no `GoogleService-Info.plist`
it falls back to the demo assistant, and the OBD features work regardless. This
is what you need before the managed assistant and paid credits function.

Order matters. Apple is the gate — several Firebase and RevenueCat steps cannot
be completed without a paid Apple Developer account, and RevenueCat cannot see
your products until they exist in App Store Connect.

---

## Phase 0 — Prerequisites

- [ ] **Paid Apple Developer Program membership** ($99/yr).

  This is the hard gate. A personal team cannot use App Attest, In-App Purchase,
  TestFlight or push, which blocks Phases 2–3 entirely. The signing error you
  already hit (`Personal development teams ... do not support the App Attest
  capability`) is this.

- [ ] **Node 22+** and the Firebase CLI:

  ```sh
  npm i -g firebase-tools
  npx -y firebase-tools@latest login
  ```

- [ ] **A Firebase project on the Blaze plan.** Cloud Functions need Blaze to
  make outbound calls to OpenRouter. Set a budget alert — OpenRouter usage is
  the cost that can run away.

- [ ] Decide the **bundle ID**. Everything must match exactly:
  `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`), the Firebase iOS app, the App
  Store Connect app, and the RevenueCat app. The repo ships `com.obdiag.app`;
  change it in one place and re-run `xcodegen generate` if you want your own.

The purchase UI is built: the plans screen and onboarding upsell read
RevenueCat offerings, credit packs are one-time purchases, and there is a
restore button. Purchases are gated behind Sign in with Apple, because credits
are granted server-side against a Firebase uid — an anonymous purchase would
have nowhere to land. So the first thing to verify after this setup is that
sign-in works.


---

## Phase 1 — Firebase

### 1.1 Create the project and iOS app

All of this is scriptable, so you never have to open the Console for it. If you
already have a Firebase project you want to use instead, skip to step 3 and just
point the CLI and app at it.

1. Sign in and note the project id you want:

   ```sh
   npx -y firebase-tools@latest login          # add --no-localhost on a remote shell
   npx -y firebase-tools@latest projects:create obdiag-app --display-name "OBDiag"
   ```

   The id must be 6–30 characters, lowercase, and globally unique.

2. Register the iOS app and fetch its config. Use `npx -y firebase-tools@latest
   apps:list` to get the `<APP_ID>` if you need it:

   ```sh
   npx -y firebase-tools@latest apps:sdkconfig IOS <APP_ID> --project obdiag-app \
     > OBDiag/Resources/GoogleService-Info.plist
   ```

   That's it — a "Copy local config" build phase bundles the plist when it
   exists, so there is nothing to regenerate. (It is deliberately *not* a
   project file member: that would bake it into `project.pbxproj` and break
   the build on any clone without it.)

   `GoogleService-Info.plist` is **gitignored**, so it stays on your machine. It
   holds no secret, but it is per-project, and keeping it out means a clone never
   points at someone else's backend. It is also the single source of truth for
   the project id — `BackendConfig.projectID` reads `PROJECT_ID` from it, so
   there is no id to keep in sync in the source.

3. Point the app and CLI at your project:

   ```sh
   cp server/.firebaserc.example server/.firebaserc   # then set your project id
   npx -y firebase-tools@latest use <your-project-id>
   ```

   | File | Setting | Currently |
   | --- | --- | --- |
   | `OBDiag/Core/Backend/BackendConfig.swift` | `projectID` | `YOUR_FIREBASE_PROJECT_ID` |
   | `server/.firebaserc` | `projects.default` | `YOUR_FIREBASE_PROJECT_ID` |

   Both are already set. Change them if you use a different project.

   `region` in `BackendConfig.swift` must match `REGION` in
   `server/functions/src/config.ts` (default `us-central1`).

   `BackendConfig.isFirebaseConfigured` is simply "is the plist present", so the
   app switches providers as soon as it is.

### 1.2 Enable Authentication

The CLI can only enable Google, anonymous and email/password sign-in. **Apple
must be enabled in the Console.**

**Authentication → Sign-in method → Apple → Enable.**

You need an Apple **Services ID**, **Team ID** and **Key**. Firebase's guide:
<https://firebase.google.com/docs/auth/ios/apple>

Sign in with Apple also needs the capability on the app's bundle ID in the Apple
Developer portal. Xcode adds this automatically under **Signing & Capabilities →
+ Capability → Sign in with Apple**, or do it in the portal.

### 1.3 Enable App Check

**App Check → Apps → your iOS app → App Attest**, with DeviceCheck as fallback.

All four callables set `enforceAppCheck: true`, so **the assistant returns
unauthenticated until this is configured.**

For the simulator, the debug build uses the App Check debug provider and prints
a token to the console at launch. Register it under **App Check → Apps → Manage
debug tokens** or requests will be rejected.

The App Attest entitlement is applied to **Release only** in `project.yml`,
because personal teams cannot sign for it (see `server/README.md`).

### 1.4 Create Firestore

This project uses **Standard edition** with the `(default)` database.
`server/firebase.json` already matches that shape, the Cloud Functions call
`getFirestore(app)` which addresses `(default)`, and `--edition` defaults to
`standard` on the CLI. No code changes needed.

Pick a location colocated with your functions region (default `us-central1`):

```sh
npx -y firebase-tools@latest firestore:locations
npx -y firebase-tools@latest firestore:databases:create "(default)" \
  --location <location-id> --edition standard
```

Creating the database on the Console works equally well and is the easier route
if you are not sure of the location id — pick **Standard edition** when prompted.
The location is a create-time decision and cannot be changed afterwards.

The security rules in `server/firestore.rules` deny all client access, which is
correct here because no client can reach Firestore anyway (the app does not link
the Firestore SDK).

> **If you ever switch to Enterprise edition**, it must have a *named* id — it
> can never be `(default)`. That also means adding `edition`, `database` and
> `location` to the `firestore` block of `server/firebase.json` and setting
> `FIRESTORE_DATABASE_ID` for the functions, otherwise they will address a
> database that does not exist and fail at runtime rather than at deploy. The
> code supports either edition; nothing here needs Enterprise's features.

### 1.5 Upgrade to Blaze

**Project settings → Usage and billing → Modify plan.** Cloud Functions cannot
reach OpenRouter on the free Spark plan.

---

## Phase 2 — Apple and App Store Connect

### 2.1 Create the app record

[App Store Connect](https://appstoreconnect.apple.com) → **My Apps → + → New
App**. Platform iOS, bundle ID `com.obdiag.app` (must already be registered in
the Developer portal).

### 2.2 Create the products

Seven products. IDs must match `server/functions/src/storeProducts.ts` and
`OBDiag/Core/Models/SubscriptionModels.swift` **exactly**.

**Subscriptions** — create them under the subscriptions section. Each needs a
reference name and a duration:

| Product ID | Tier | Price (repo default) |
| --- | --- | --- |
| `com.obdiag.plus.monthly` | plus | $4.99 / month |
| `com.obdiag.plus.yearly` | plus | $39.99 / year |
| `com.obdiag.pro.monthly` | pro | $9.99 / month |
| `com.obdiag.pro.yearly` | pro | $79.99 / year |

**Consumables:**

| Product ID | Credits | Price |
| --- | --- | --- |
| `com.obdiag.credits.500` | 500 | $4.99 |
| `com.obdiag.credits.1500` | 1,500 | $12.99 |
| `com.obdiag.credits.4000` | 4,000 | $29.99 |

Each IAP also needs a localised display name, description and a review
screenshot before it can be submitted.

> **Read `docs/SHIPPING.md` §2 before setting prices.** Using the repo's default
> prices with the current credit allowances loses money on Pro, and the yearly
> plans are negative at a 30% Apple commission. The tables there give corrected
> numbers.

**Subscription groups.** The bundled `.storekit` puts Plus and Pro in separate
groups. One group with levels gives you upgrade/downgrade with proration; two
groups lets a user hold both. Decide deliberately — it is awkward to change
later. One group with Plus at level 1 and Pro at level 2 is the usual choice.

### 2.3 Generate an In-App Purchase key

**Users and Access → Integrations → In-App Purchase keys → Generate.** Download
the `.p8` (one chance only) and note the **Key ID** and **Issuer ID**. RevenueCat
needs all three in the next phase.

---

## Phase 3 — RevenueCat

RevenueCat owns StoreKit: it validates receipts, computes entitlements, and
notifies your backend. **Webhooks require RevenueCat's Pro plan.**

### 3.1 Project and app

1. <https://app.revenuecat.com> → create a project.
2. **Add app → App Store**, bundle ID `com.obdiag.app`.
3. Upload the App Store Connect **In-App Purchase key** (`.p8` + Key ID +
   Issuer ID) so RevenueCat can talk to Apple, and the App Store
   **app-specific shared secret** if prompted.

### 3.2 Import products and create entitlements

1. **Products → Import** from App Store Connect. All seven should appear.
2. **Entitlements → create two**, named exactly:

   | Entitlement ID | Attach |
   | --- | --- |
   | `plus` | `com.obdiag.plus.monthly`, `com.obdiag.plus.yearly` |
   | `pro` | `com.obdiag.pro.monthly`, `com.obdiag.pro.yearly` |

   The names matter: the server infers the plan from the entitlement id by
   looking for `plus`/`pro` (`planForEntitlement` in `storeProducts.ts`).

   Consumables carry **no** entitlement — they grant credits directly via the
   webhook.

3. **Offerings → create a default offering** and add packages for the four
   subscriptions. This is what the purchase UI will display.

### 3.3 Copy the keys

| Key | Where | Goes to |
| --- | --- | --- |
| Public SDK key (`appl_…`) | Project → API keys | `OBDiag/Resources/Secrets.plist` |
| Secret API key (`sk_…`) | same page | `REVENUECAT_API_KEY` Firebase secret |

The public key goes in a **gitignored** file. An iOS app has no runtime `.env` —
a Swift `let` is compiled into the binary — so a bundled file is the equivalent:

```sh
cp OBDiag/Resources/Secrets.example.plist OBDiag/Resources/Secrets.plist
# fill in RevenueCatTestAPIKey (test_…) and/or RevenueCatAppStoreAPIKey (appl_…)
```

The "Copy local config" build phase bundles it on the next build; nothing to
regenerate.

Debug prefers the Test Store key and Release prefers the App Store key, falling
back to whichever is present, so supplying one is enough. The key is public by
design, but keeping it out of the repository means a clone never points at
someone else's RevenueCat project.

The secret key must never enter the app — it belongs in Secret Manager only.

The app configures RevenueCat with the Firebase uid as the `appUserID`, which is
what lets a purchase webhook be matched to the right account.

### 3.4 Configure the webhook

Do this **after** deploying the backend (Phase 4), because you need its URL.

**Integrations → Webhooks → Add new configuration:**

- **URL:** `https://<region>-<projectID>.cloudfunctions.net/revenuecatWebhook`
- **Authorization header:** the same random string you set as
  `REVENUECAT_WEBHOOK_AUTH`
- **HMAC signing:** optional but recommended — store the secret as
  `REVENUECAT_WEBHOOK_SIGNING_SECRET`
- **Events:** at minimum `Initial Purchase`, `Renewal`, `Cancellation`,
  `Expiration`, `Non-Renewing Purchase`, `Refund`, `Product Change`,
  `Uncancellation`
- **Environment:** both production and sandbox while testing

---

## Phase 4 — Deploy the backend

```sh
cd server/functions
npm install && npm run typecheck && npm test    # 81 tests, no emulator needed
```

Set the four secrets (each prompts for the value):

```sh
npx -y firebase-tools@latest functions:secrets:set OPENROUTER_API_KEY                # sk-or-v1-…
npx -y firebase-tools@latest functions:secrets:set REVENUECAT_WEBHOOK_AUTH           # long random string
npx -y firebase-tools@latest functions:secrets:set REVENUECAT_WEBHOOK_SIGNING_SECRET # from RevenueCat
npx -y firebase-tools@latest functions:secrets:set REVENUECAT_API_KEY                # sk_…
```

`OPENROUTER_API_KEY` is the one that actually pays for model usage. **Set a
spending limit on it in the OpenRouter dashboard** — it is the blast radius if a
bug lets requests through.

Then:

```sh
cd server
npx -y firebase-tools@latest deploy --only functions,firestore:rules,firestore:indexes
```

The deploy prints each function URL; use the `revenuecatWebhook` one for §3.4.

---

## Phase 5 — Verify

Local, no Apple or RevenueCat needed:

```sh
cd server/functions && npm run serve     # emulators for functions + firestore
```

Exercise the credit ledger by posting a synthetic webhook (see
`server/README.md` for the exact curl). Then, against the deployed backend:

1. Sign in with Apple in the app → the uid appears under Authentication →
   Users.
2. Ask a question → a row appears in `users/{uid}/ledger`.
3. Buy a credit pack in the sandbox → the consumable webhook fires and the
   balance increases.
4. Check **App Check → Metrics** shows verified requests. If they show as
   unverified, the debug token is not registered.

You can watch the cash flow directly, which is the fastest way to catch a
misconfigured webhook:

```
users/{uid}                     plan, credits, entitlements
users/{uid}/ledger/{key}        every grant and every charge
users/{uid}/processedEvents/*   webhook dedupe
```

---

## Common failure modes

| Symptom | Cause |
| --- | --- |
| `unauthenticated` on every assistant call | App Check not configured, or the debug token is unregistered |
| `resource-exhausted` immediately | Balance is zero and the monthly grant has not landed |
| Purchase succeeds but no credits | Webhook URL, auth header, or event filter wrong |
| Credits granted twice | Webhook `id` is not the idempotency key — check `processedEvents` |
| Works in sandbox, not production | Webhook set to sandbox-only, or a different RevenueCat project |
| Assistant works locally, fails deployed | `projectID`/`region` mismatch between `BackendConfig.swift` and the deploy |
