# Shipping checklist

Status of the work to turn OBDiag into a shippable product, on branch
`feat/server-backed-credits`.

---

## 1. The monetization fix (this branch)

The original app sold subscriptions and credits while requiring the user to
supply their own OpenRouter key — so a subscriber paid twice, and the credits
they bought couldn't be spent without a separate paid account. That is now
addressed by a backend that holds the key, meters usage, and verifies purchases.

**Done, tested:**

- `server/` — Firebase Functions (TypeScript), 75 unit tests, `tsc` clean.
  Streaming AI proxy, plan-based model gating, request sanitisation, atomic
  reserve/settle ledger, RevenueCat webhook with timing-safe + HMAC verification,
  idempotent grants, Firestore rules denying all client access.
- `OBDiag/Core/Backend/` — Sign in with Apple via Firebase Auth, App Check
  (App Attest), a callable client implementing the streaming protocol directly
  (the Swift SDK's `stream` is internal-only), and a server-authoritative
  account store.
- `OBDiag/AI/BackendChatClient.swift` — managed provider that reuses the
  existing chunk parser.
- New `AIProviderKind.obdiag`, now the default. BYOK, LM Studio and demo remain
  as alternatives — BYOK is a legitimate choice for power users, and it no longer
  conflicts with the paid tier now that credits are actually spendable.

**Not yet done (see §4):** the RevenueCat *purchase UI* still uses the old
StoreKit 2 path. RevenueCat must own StoreKit before shipping, or transactions
will be handled twice.

---

## 2. The margin problem — decide before setting prices

1 credit ≈ $0.001 of model usage, scaled by the plan multiplier (Free ×1.5,
Plus ×1.2, Pro ×1.0). So a plan granting *N* credits costs
`N ÷ multiplier × $0.001` per month. Compare that to revenue **after Apple's
cut** (15% Small Business Program, 30% standard).

| Plan | Price | Credits | Model cost/mo | Margin @15% | Margin @30% |
| --- | --- | --- | --- | --- | --- |
| Free | $0 | 150 | $0.100 | — | — |
| Plus monthly | $4.99 | 2,500 | $2.083 | $2.16 (51%) | $1.41 (40%) |
| Plus yearly | $39.99/yr ($3.33/mo) | 2,500 | $2.083 | $0.75 (26%) | $0.25 (11%) |
| Pro monthly | $9.99 | 8,000 | **$8.00** | $0.49 (6%) | **−$1.01** ❌ |
| Pro yearly | $79.99/yr ($6.67/mo) | 8,000 | **$8.00** | **−$2.33** ❌ | **−$3.33** ❌ |
| 500 credits | $4.99 | 500 | $0.50 | $3.74 (88%) | — |
| 1,500 credits | $12.99 | 1,500 | $1.50 | $9.54 (86%) | — |
| 4,000 credits | $29.99 | 4,000 | $4.00 | $21.49 (84%) | — |

**Consumables are healthy. Pro subscriptions lose money, and both yearly plans
are thin-to-negative.** The credit allowances are roughly 2–3× too generous
relative to price.

### Recommended fix

Target model cost ≤ 40% of net revenue. Adjust in **one place** —
`server/functions/src/plans.ts` — and mirror in
`OBDiag/Core/Models/UserProfile.swift` for display.

| Plan | Price | Credits | Cost/mo | Cost ratio |
| --- | --- | --- | --- | --- |
| Plus monthly | $6.99 | 2,000 | $1.67 | 28% |
| Pro monthly | $14.99 | 4,000 | $4.00 | 31% |
| Plus yearly | $59.99/yr | 2,000/mo | $1.67 | ~34% |
| Pro yearly | $129.99/yr | 4,000/mo | $4.00 | ~35% |

Also note the **free tier costs $0.10/user/month** — at 100k monthly actives
that's $10k/month with no revenue. Consider lowering the free grant or gating it
behind a one-time purchase.

The server is the enforcement point, so allowances can be tuned without an app
release — but the client displays them, so keep the two in sync.

---

## 3. Store compliance (required before submission)

- [ ] **`PrivacyInfo.xcprivacy`** — still missing, and now more necessary: the
  app uses UserDefaults and file timestamps (required-reason APIs) and sends
  data to a backend. Submission is flagged without it.
- [ ] **Privacy policy URL** and **Terms/EULA** — required App Store Connect
  metadata, and mandatory for a subscription app. They must describe what the
  backend stores (Firebase uid, purchase history, usage) — the current About
  screen's "OBDiag runs no server" copy is **now false and must be rewritten**.
- [ ] **Account deletion** — required in-app once you have accounts. RevenueCat
  must also be told (`Purchases.shared.logOut()`), and server data purged.
- [ ] `DEVELOPMENT_TEAM` is empty in `project.yml`; set a real team and a
  distribution profile.
- [ ] Set `REVENUECAT_API_KEY` at build time (see `server/README.md`).
- [ ] App Store Connect: create the 7 products; RevenueCat entitlements named
  `plus` and `pro`; webhook configured.
- [ ] Safety disclaimer exists in About but isn't acknowledged at first launch.
  For an app advising repairs, add explicit acceptance in onboarding.

---

## 4. Remaining engineering

- [ ] **RevenueCat purchase UI** (highest priority). Replace `SubscriptionStore`
  (StoreKit 2 direct) with a RevenueCat-backed store:
  `Purchases.configure(withAPIKey:appUserID: uid)` on sign-in,
  `offerings()` for display, `purchase(package:)`, `restorePurchases()`,
  `logIn`/`logOut`. Then delete the local `CreditLedger` spend path for the
  managed provider. Shipping both would double-handle transactions.
- [ ] **Sign-in UI**: an onboarding/settings gate calling
  `env.auth.signInWithApple()`, plus `await env.syncBackend()` on launch and
  foreground (wired but not yet called from any view).
- [ ] **Account deletion** callable (Firestore purge + RevenueCat logout).
- [ ] **Per-request rate limiting** beyond credit balance (e.g. per-uid quota),
  so a compromised token can't drain a balance in seconds.
- [ ] **Unit test target** for the iOS app. DTC/VIN/ELM327 parsing lives in
  ad-hoc scripts under `scripts/Tests/` that `xcodebuild` never runs; a real
  bug (P0456 reported as P0104) shipped because of this.
- [ ] **CI**: `xcodegen` → build → test, plus `npm test`/`tsc` for the server
  and `eval/run.py --self-test` + `check_drift.py`.
- [ ] Replace DuckDuckGo HTML scraping with the paid search backend before
  shipping — it's fragile and ToS-risky.

---

## 5. Build and verify

```sh
# Server
cd server/functions && npm install && npm run typecheck && npm test

# App
cd .. && xcodegen generate
xcodebuild -project OBDiag.xcodeproj -scheme OBDiag \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# End-to-end without hardware
cd server/functions && npm run serve
# then run the app against the emulator with -uiDemo
```

The app builds and runs **without** `GoogleService-Info.plist` or RevenueCat
credentials: it falls back to the demo assistant, so a fresh checkout is usable.
Adding the plist and the API key enables the managed path.
