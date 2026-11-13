#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
swift test --package-path Packages/PDFSucherKit "$@"
