#!/bin/bash
# Packages build/Marshmallow.app into a drag-to-install DMG:
#   dist/Marshmallow-<version>.dmg
# Usage: scripts/make-dmg.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(cat VERSION)}"
APP="build/Marshmallow.app"
VOL="Marshmallow"
OUT="dist/Marshmallow-$VERSION.dmg"

[ -d "$APP" ] || { echo "missing $APP — run scripts/build-app.sh first"; exit 1; }

echo "▸ Building DMG"
swift scripts/make-dmg-background.swift build/dmgbg >/dev/null 2>&1
# dmgbuild writes the Finder layout (.DS_Store) directly — no Finder scripting.
if [ ! -x build/venv/bin/dmgbuild ]; then
  python3 -m venv build/venv
  build/venv/bin/pip install -q dmgbuild
fi
mkdir -p dist
rm -f "$OUT"
build/venv/bin/dmgbuild -s scripts/dmg-settings.py \
  -D app="$APP" -D background=build/dmgbg/background.png \
  "$VOL" "$OUT" >/dev/null
echo "✓ $OUT"
