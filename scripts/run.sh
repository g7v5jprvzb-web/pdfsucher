#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
open ./.build/xcode/Build/Products/Debug/PDFSucher.app
