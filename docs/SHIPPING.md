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

## 2. Credit economics — the formula is right, the allowances are not

Billing is token-pegged (`server/functions/src/plans.ts`, mirrored in
`CreditPricing` on the client):

```
credits = max(1, ceil( tokens ÷ 1,000 × MODEL_TIER_MULTIPLIER[tier] ))
                     flash 0.33 · plus 1 · max 5
```

The tier ladder is well calibrated. Max models cost roughly 5× a Plus model to
run and bill at 5×, so both land at nearly the same cost per credit
(~$0.0035–0.0037). Reference request throughout: 3,000 prompt + 800 completion
tokens (the app's own worked example).

| Model | Tier | Cost | Credits | $/credit |
| --- | --- | --- | --- | --- |
| deepseek-v4.1-flash | flash | $0.0009 | 2 | $0.00046 |
| gpt-5.6-luna | flash | $0.0016 | 2 | $0.00078 |
| gemini-3.8-flash | flash | $0.0053 | 2 | $0.00263 |
| grok-4.3 | plus | $0.0057 | 4 | $0.00144 |
| glm-5.3 | plus | $0.0077 | 4 | $0.00193 |
| grok-4.6 | plus | $0.0108 | 4 | $0.00270 |
| gemini-3.5-flash | plus | $0.0117 | 4 | $0.00293 |
| claude-sonnet-5 | plus | $0.0140 | 4 | $0.00350 |
| kimi-k3 | plus | $0.0161 | 4 | $0.00404 |
| **claude-opus-5** | **plus** | **$0.0350** | **4** | **$0.00875** |
| gpt-6-astra | max | $0.0700 | 19 | $0.00368 |

### Fix 1 — `claude-opus-5` is in the wrong tier (bug)

Its prompt price is exactly $5.00/M, and the rule is `perMillion <= 5 → plus`,
so it lands in Plus. But it costs **$0.00875 per credit — 2.4× more than the
Max-tier models**. That is an inversion: the cheaper plan's best model costs you
more per credit than the expensive plan's.

Because a Plus user can select it, it sets the price floor for the whole Plus
plan. One-line fix in `server/functions/src/models.ts` (the catalog already
supports it):

```ts
{ id: "anthropic/claude-opus-5", …, tierOverride: "max" },
```

### Fix 2 — the allowances are ~5× too generous

Priced against the **worst model each plan permits** (users will pick it), at
40% of net revenue after a 15% Apple cut:

| Plan | Price | Worst case $/credit | Affordable/mo | Current |
| --- | --- | --- | --- | --- |
| Plus | $4.99 | $0.00404 (kimi-k3, after Fix 1) | **~420** | 2,500 |
| Plus | $4.99 | $0.00875 (opus-5, unfixed) | ~193 | 2,500 |
| Pro | $9.99 | $0.00368 (gpt-6-astra) | **~920** | 8,000 |

Allow ~520 / 1,150 credits for a 50% cost ratio. At the current 2,500 / 8,000,
Plus and Pro cost roughly **$10 and $29 per month** in model usage respectively.

Either cut the allowances to ~500 / ~1,000, or raise prices to match the
allowances — you cannot keep both.

### Why margin now floats

Credits are no longer pegged to dollars, so gross margin depends on model mix,
and within-tier spread is large: Flash models range from $0.00046 to $0.00263
per credit (5.7×) because a 3-step ladder cannot track a 6× cost range. Ceiling
rounding and the 1-credit minimum work in your favour — cheap models subsidise
expensive ones — but you must price against the worst case, not the average.

Every settled request already records the provider's own `usage.costUSD` on the
ledger, so realised margin is measurable per model. Watch it: if the mix drifts
toward the top of each tier, margin compresses silently.

Also note the **free tier costs ~$0.10/user/month** (150 credits, worst-case
Flash). At 100k monthly actives that is ~$10k/month with no revenue.

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
- [ ] **App Attest needs a paid team.** The entitlement is Release-only because
  personal teams cannot sign for it; Debug uses the App Check debug provider
  instead. Before archiving, enable the App Attest capability for the bundle id
  and use a profile that includes it. See `server/README.md`.
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
