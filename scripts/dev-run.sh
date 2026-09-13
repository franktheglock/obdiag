#!/usr/bin/env bash
# Fast iteration loop: build, install and launch with console output.
# No Xcode, no LLDB, no waiting for the debugger to attach.
#
#   scripts/dev-run.sh                        # default device
#   scripts/dev-run.sh "iPad Pro 13-inch (M5)" -uiDemo -startSection=dashboard
#
# Any arguments after the device name are passed to the app.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-iPhone 17 Pro}"
shift || true
DERIVED="${DERIVED:-build}"

echo "▸ building for $DEVICE"
xcodebuild -project OBDiag.xcodeproj -scheme OBDiag -configuration Debug \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build 2>&1 | grep -E "error:|warning: .*deprecat|BUILD" | tail -5

UDID=$(xcrun simctl list devices available | awk -F '[()]' "/$DEVICE \\(/ {print \$2; exit}")
if [[ -z "${UDID:-}" ]]; then
  echo "Could not find a simulator named '$DEVICE'" >&2
  exit 1
fi

APP="$DERIVED/Build/Products/Debug-iphonesimulator/OBDiag.app"
xcrun simctl terminate "$UDID" com.obdiag.app 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

echo "▸ launching on $DEVICE ($UDID) — Ctrl-C to stop, logs stream below"
xcrun simctl launch --console-pty "$UDID" com.obdiag.app "$@"
