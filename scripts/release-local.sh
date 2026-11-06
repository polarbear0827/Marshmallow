#!/bin/bash
# FALLBACK ONLY: builds locally and publishes a release (normally CI does this, see release.sh).
# Usage: scripts/release.sh <version> "<release notes>"
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> \"notes\"}"
NOTES="${2:-Marshmallow $VERSION}"

echo "$VERSION" > VERSION
git add -A
git diff --cached --quiet || git commit -q -m "Release v$VERSION"

scripts/build-app.sh "$VERSION"
scripts/make-dmg.sh "$VERSION"

git tag -a "v$VERSION" -m "Marshmallow v$VERSION"
git push -q origin HEAD
git push -q origin "v$VERSION"

INSTALL=$(cat <<EOF

---
### 📥 安裝
1. 下載下面的 **\`Marshmallow-$VERSION.dmg\`**，打開後把 **Marshmallow** 拖進「應用程式」資料夾。
2. 第一次打開如果出現「無法確認開發者」，到「**系統設定 → 隱私權與安全性**」最下面按「**仍要打開**」。
3. 打開後跟著新手教學練習一次就會了。

使用說明請看 [README](https://github.com/polarbear0827/Marshmallow#readme)。
EOF
)

gh release create "v$VERSION" "dist/Marshmallow-$VERSION.dmg" "dist/Marshmallow-$VERSION.zip" \
  --title "Marshmallow v$VERSION" \
  --notes "$NOTES$INSTALL"
echo "✓ Released v$VERSION"
