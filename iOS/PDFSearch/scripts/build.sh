#!/usr/bin/env bash
# Baut die App für den iOS-Simulator (ohne Signatur).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
xcodegen generate
xcodebuild -project PDFSearch.xcodeproj -scheme PDFSearch -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath ./.build/xcode \
    CODE_SIGNING_ALLOWED=NO build
