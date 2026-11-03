#!/bin/bash
# Packages dist/Askme.app into dist/release: a drag-to-install DMG, a ZIP and SHA-256 checksums.
#   ./scripts/package-release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/package-release.sh <version>}"
APP="dist/Askme.app"
OUT="dist/release"
NAME="Askme-$VERSION-macOS"
[[ -d "$APP" ]] || { echo "Missing $APP; run scripts/build-app.sh first." >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

# ditto keeps the code signature and extended attributes intact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME.zip"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
# hdiutil occasionally reports a busy resource on CI runners; retry a few times.
for attempt in 1 2 3; do
    if hdiutil create -volname "Askme $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$OUT/$NAME.dmg" >/dev/null; then
        break
    fi
    [[ $attempt -lt 3 ]] || { echo "hdiutil failed" >&2; exit 1; }
    sleep 3
done

(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
ls -lh "$OUT"
