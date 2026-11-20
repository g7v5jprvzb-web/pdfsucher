#!/usr/bin/env bash
# Startet die zuletzt gebaute App im ersten verfügbaren iPhone-Simulator (vorher scripts/build.sh).
# Zusätzliche Argumente gehen an die App, z. B. -demoData YES -demoQuery Vertrag -demoScreen search
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
APP=./.build/xcode/Build/Products/Debug-iphonesimulator/PDFSearch.app
[ -d "$APP" ] || { echo "Erst scripts/build.sh ausführen" >&2; exit 1; }
DEVICE=$(xcrun simctl list devices available | grep -m1 -E '^\s+iPhone' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$DEVICE" ] || { echo "Kein iPhone-Simulator gefunden (Xcode > Settings > Components)" >&2; exit 1; }
xcrun simctl boot "$DEVICE" 2>/dev/null || true
open -a Simulator 2>/dev/null || echo "Simulator.app nicht gefunden – App läuft trotzdem im Hintergrund-Simulator $DEVICE"
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" local.pdfsearch "$@"
