#!/usr/bin/env bash
# Bildschirmfotos aller Bildschirme mit Beispieldateien (Debug-Build, vorher scripts/build.sh).
# Ablage: docs/screenshots/. Optional: Gerätename als erstes Argument, z. B. "iPhone 18 Pro".
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
APP=./.build/xcode/Build/Products/Debug-iphonesimulator/PDFSearch.app
[ -d "$APP" ] || { echo "Erst scripts/build.sh ausführen" >&2; exit 1; }
NAME="${1:-iPhone}"
DEVICE=$(xcrun simctl list devices available | grep -m1 -F "    $NAME" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$DEVICE" ] || { echo "Kein Simulator „$NAME“ gefunden" >&2; exit 1; }
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged --batteryLevel 100 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
mkdir -p docs/screenshots
shot() {
    local file="$1"; shift
    xcrun simctl terminate "$DEVICE" local.pdfsearch 2>/dev/null || true
    xcrun simctl launch "$DEVICE" local.pdfsearch -demoData YES "$@" >/dev/null
    sleep "${WAIT:-6}"
    xcrun simctl io "$DEVICE" screenshot "docs/screenshots/$file" >/dev/null
    echo "docs/screenshots/$file"
}
# Erster Start legt die Beispieldateien an und baut den Index (Texterkennung der Fotos braucht etwas länger).
WAIT=20 shot 01-bibliothek.png -demoScreen library
shot 02-suche.png -demoQuery Vertrag -demoScreen search
shot 03-seite.png -demoQuery Vertrag -demoScreen page
shot 04-foto.png -demoQuery Vertrag -demoScreen photo
shot 05-auswahl.png -demoQuery Vertrag -demoScreen selection
shot 06-alle-dateien.png -demoScreen search
