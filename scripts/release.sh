#!/bin/bash
# Builds, tags, pushes and publishes a GitHub release.
# Usage: scripts/release.sh <version> "<release notes>"
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> \"notes\"}"
NOTES="${2:-Marshmallow $VERSION}"

echo "$VERSION" > VERSION
git add -A
git diff --cached --quiet || git commit -q -m "Release v$VERSION"

scripts/build-app.sh "$VERSION"

git tag -a "v$VERSION" -m "Marshmallow v$VERSION"
git push -q origin HEAD
git push -q origin "v$VERSION"

INSTALL=$(cat <<EOF

---
### 安裝
1. 下載 \`Marshmallow-$VERSION.zip\`，解壓縮後把 **Marshmallow.app** 拖進「應用程式」。
2. App 沒有經過 Apple 公證，第一次開啟請在 App 上按右鍵 →「打開」，或執行：
   \`xattr -dr com.apple.quarantine /Applications/Marshmallow.app\`
3. 選用：\`brew install ffmpeg webp\` 可解鎖 WEBM / MP3 / FLAC / OGG 等格式。
EOF
)

gh release create "v$VERSION" "dist/Marshmallow-$VERSION.zip" \
  --title "Marshmallow v$VERSION" \
  --notes "$NOTES$INSTALL"
echo "✓ Released v$VERSION"
