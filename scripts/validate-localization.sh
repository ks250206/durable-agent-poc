#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PYTHONDONTWRITEBYTECODE=1
# With an app argument, validate its actual copied/compiled bundle; otherwise validate sources.
python3 scripts/localization/validate-source.py
python3 -m unittest discover -s scripts/localization -p 'test_*.py'
resources="$ROOT/Sources/AppLocalization/Resources"
if [ "$#" -gt 1 ]; then
    echo 'Usage: scripts/validate-localization.sh [DurableChat.app]' >&2
    exit 2
fi
if [ "$#" -eq 1 ]; then
    resources="$1/Contents/Resources/DurableChat_AppLocalization.bundle"
    test -d "$resources"
fi
swift run --build-system swiftbuild LocalizationAudit scripts/localization/inventory.json "$resources"
