#!/usr/bin/env bash
# Tests des Kerns (Index, Suche, Texterkennung, PDF-Ausgabe). Laufen auf dem Mac, kein Simulator nötig.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
swift test --package-path Core "$@"
