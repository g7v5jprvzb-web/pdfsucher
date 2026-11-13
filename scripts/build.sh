#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
xcodegen generate
xcodebuild -project PDFSucher.xcodeproj -scheme PDFSucher -configuration Debug -derivedDataPath ./.build/xcode build
