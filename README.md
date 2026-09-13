# OBDiag

AI-powered vehicle diagnostics for iPhone and iPad. Connects to a Bluetooth
OBD-II (ELM327) adapter, reads live sensor data and diagnostic trouble codes,
and pairs them with an AI assistant that explains what's wrong, what to check,
and what parts or procedures are needed.

## Requirements

- Xcode 27 / iOS 26 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build & run

```sh
xcodegen generate
xcodebuild -project OBDiag.xcodeproj -scheme OBDiag \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

The app runs without hardware: onboarding and the dashboard both offer a
built-in demo adapter that speaks the real ELM327 text protocol.

## Structure

```
OBDiag/
  App/            App entry, composition root, adaptive shell
  Core/           Models, storage, theming, settings
  OBD/            CoreBluetooth transport, ELM327 protocol, PID/DTC decoding
  AI/             Provider clients, agent loop, tools, search backends
  VehicleData/    NHTSA vPIC catalog + VIN decode
  Features/       Garage, dashboard, chat, onboarding, settings
  Resources/      Assets and the StoreKit configuration
```

Diagnostics are on-device by default: vehicles, conversations and settings live
in Application Support, API keys in the Keychain.

## Branches

- `main` — the shipping app.
- `eval` — the AI evaluation harness: a dependency-free Python replica of the
  assistant (same prompt, tools and agent loop) with deterministic graders for
  hallucinated specs, citations, abstentions, safety advice and tool use.
  Runs in seconds with no simulator: `python3 eval/run.py --self-test`.
  See `eval/README.md`. Kept off `main` so it never ships in the app binary.
