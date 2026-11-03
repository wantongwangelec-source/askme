#!/bin/bash
# Print GitHub release notes for the Askme tag passed as $1.
set -euo pipefail
VERSION="${1:?version required, e.g. 1.2.3}"
PREVIOUS="${2:-}"

cat <<NOTES
## Install

1. Download \`Askme-$VERSION-macOS.dmg\` and drag Askme into Applications.
2. This build is ad-hoc signed and not notarized by Apple. On first open, go to System Settings → Privacy & Security and choose Open Anyway, or run
   \`xattr -dr com.apple.quarantine /Applications/Askme.app\`.
3. After launch, open Askme → Settings & Permissions in the menu bar, grant Accessibility, and fill in the model endpoint.
4. In any article, hold \`⌃\` and point at a word.

Universal binary (Apple silicon and Intel). Requires macOS 14 or later. Checksums are in \`SHA256SUMS.txt\`.

## Changes
NOTES

if [[ -n "$PREVIOUS" ]]; then
    echo "Since $PREVIOUS:"
    git log --pretty='- %s' "$PREVIOUS..v$VERSION" 2>/dev/null || git log --pretty='- %s' "$PREVIOUS..HEAD" 2>/dev/null || true
else
    echo "- Initial public release."
fi
