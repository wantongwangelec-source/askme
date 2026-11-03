#!/bin/bash
# Cuts a release: sets the version in Resources/Info.plist, runs the tests, tags vX.Y.Z and pushes.
# Pushing the tag triggers .github/workflows/release.yml, which builds and publishes the release.
#   ./scripts/release.sh 0.3.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>, e.g. 0.3.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
    || { echo "Version must look like 1.2.3 or 1.2.3-beta.1" >&2; exit 1; }
TAG="v$VERSION"
BRANCH="$(git branch --show-current)"

[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "Tag $TAG already exists." >&2
    exit 1
fi

PLIST=Resources/Info.plist
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" != "$VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
    git commit -qm "Release $TAG" -- "$PLIST"
fi

swift test
git tag -a "$TAG" -m "Askme $TAG"
git push origin "$BRANCH"
git push origin "$TAG"

REPO="$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
echo "Pushed $TAG. Release build: https://github.com/$REPO/actions"
