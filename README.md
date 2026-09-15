# OBDiag

AI-powered vehicle diagnostics for iPhone and iPad. Connects to a Bluetooth
OBD-II (ELM327) adapter, reads live sensor data and diagnostic trouble codes,
and pairs them with an AI assistant that explains what's wrong, what to check,
and what parts or procedures are needed.

## Requirements

- Xcode 27 / iOS 26 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

The AI assistant is powered by a small Firebase backend (see
[`docs/BACKEND.md`](docs/BACKEND.md) and [`server/README.md`](server/README.md)).
**Setting up Firebase and RevenueCat from scratch:
[`docs/SETUP.md`](docs/SETUP.md).** The app builds and runs **without** any of it —
with no `GoogleService-Info.plist` it falls back to the built-in demo assistant.

## Build & run

```sh
xcodegen generate
xcodebuild -project OBDiag.xcodeproj -scheme OBDiag \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

On a fresh clone, Xcode must fetch the Swift packages before it can build (it
will report `Missing package product 'FirebaseCore'` until it has). Either open
the project and let Xcode resolve, or run:

```sh
xcodebuild -resolvePackageDependencies -project OBDiag.xcodeproj -scheme OBDiag
```

That pulls the Firebase iOS SDK, which is a large repo (~250 MB) and can take a
while on a slow connection. `Package.resolved` is committed, so the versions are
pinned once fetched.

The app runs without hardware: onboarding and the dashboard both offer a
built-in demo adapter that speaks the real ELM327 text protocol.

## Structure

```
OBDiag/
  App/            App entry, composition root, adaptive shell
  Core/           Models, storage, theming, settings
  Core/Backend/   Firebase Auth, App Check, callable client, server account
  OBD/            CoreBluetooth transport, ELM327 protocol, PID/DTC decoding
  AI/             Provider clients, agent loop, tools, search backends
  VehicleData/    NHTSA vPIC catalog + VIN decode
  Features/       Garage, dashboard, chat, onboarding, settings
  Resources/      Assets and the StoreKit configuration
server/           Firebase Functions: AI proxy, credit ledger, RevenueCat webhook
docs/             Backend architecture and the shipping checklist
```

Vehicle data, conversations and settings stay on-device in Application Support.
The managed assistant sends only the conversation to the backend; API keys are
never stored on the device for the default provider.

## AI providers

The assistant can run four ways, selectable in Settings:

| Provider | Key handling | Metering |
| --- | --- | --- |
| **OBDiag AI** (default) | Key held server-side | Credits, server-enforced |
| OpenRouter (your key) | Keychain, on-device | None — you pay OpenRouter |
| LM Studio (local) | None, LAN only | None |
| Demo | None, on-device | None |

## Evaluation

The AI eval harness is a dependency-free Python replica of the assistant (same
prompt, tools and agent loop) with deterministic graders for hallucinated specs,
citations, abstentions, safety advice and tool use. It runs in seconds with no
simulator:

```sh
python3 eval/run.py --self-test
python3 eval/check_drift.py
```

See [`eval/README.md`](eval/README.md). It is not part of any app target, so it
never ships in the binary.
