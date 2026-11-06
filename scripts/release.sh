#!/bin/bash
# Starts a release. GitHub Actions (.github/workflows/release.yml) then builds
# the DMG/ZIP on GitHub's machines, adds SHA-256 checksums and a build
# provenance attestation, and publishes the GitHub Release.
#
# Usage: scripts/release.sh <version> "<release notes in Markdown>"
# Fallback (build + publish from this Mac): scripts/release-local.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> \"notes\"}"
NOTES="${2:-## Marshmallow v$VERSION}"
TAG="v$VERSION"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "tag $TAG already exists"; exit 1
fi

mkdir -p .github/release-notes
printf '%s\n' "$NOTES" > ".github/release-notes/$TAG.md"
echo "$VERSION" > VERSION

git add VERSION ".github/release-notes/$TAG.md"
git commit -q -m "Release $TAG"
git tag -a "$TAG" -m "Marshmallow $TAG"
git push -q origin HEAD
git push -q origin "$TAG"

echo "✓ Pushed $TAG — GitHub Actions is building and publishing the release:"
echo "  https://github.com/polarbear0827/Marshmallow/actions/workflows/release.yml"
echo "  Watch it with: gh run watch \$(gh run list --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
