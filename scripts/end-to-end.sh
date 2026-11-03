#!/bin/bash
# Builds the demo app with its embedded service and runs its headless check: the service
# starts through launchd, answers, reports errors typed, and (unless --offline) produces a
# real pairing QR code from WhatsApp's servers. Exits non-zero if any step fails.
#
# Usage: scripts/end-to-end.sh [--offline]

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

scripts/build-xcframework.sh
xcodegen generate >/dev/null
mkdir -p build
if ! xcodebuild -project XPCWhatsMeowService.xcodeproj -scheme WhatsMeowDemo -configuration Debug \
        -derivedDataPath build/dd build > build/end-to-end-build.log 2>&1; then
    grep -E "error:" build/end-to-end-build.log | head -20
    echo "Build failed — see build/end-to-end-build.log"
    exit 1
fi

APP="build/dd/Build/Products/Debug/WhatsMeowDemo.app"

# The GPL boundary, checked on the binaries: whatsmeow only in the service.
APP_SYMBOLS=$(nm "$APP/Contents/MacOS/"* 2>/dev/null | grep -c 'go.mau.fi' || true)
XPC_SYMBOLS=$(nm "$APP/Contents/XPCServices/XPCWhatsMeowService.xpc/Contents/MacOS/XPCWhatsMeowService" | grep -c 'go.mau.fi/libsignal' || true)
if [[ "$APP_SYMBOLS" != "0" || "$XPC_SYMBOLS" == "0" ]]; then
    echo "✗ whatsmeow is in the wrong binary (app: $APP_SYMBOLS, service: $XPC_SYMBOLS)"
    exit 1
fi
echo "✓ whatsmeow only in the service ($XPC_SYMBOLS libsignal symbols there, none in the app)"

"$APP/Contents/MacOS/WhatsMeowDemo" --check "$@"
