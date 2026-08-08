#!/usr/bin/env bash
#
# bump-version.sh — move the version forward in the two places that hold it
#
# Usage: scripts/bump-version.sh X.Y.Z
#
# Rewrites the `# Version:` header in bin/claude-work and promotes the
# CHANGELOG's Unreleased section into a dated release section, then prints the
# commit and tag commands. It deliberately does not commit or tag: review the
# diff first. CI fails the build if these two drift apart, and the release
# workflow additionally requires the git tag to agree.

set -euo pipefail

REPO_URL="https://github.com/bjornjohansen/claude-work"

VERSION="${1:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $(basename "$0") X.Y.Z" >&2
  echo "  e.g. $(basename "$0") 0.2.0" >&2
  exit 1
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="${ROOT}/bin/claude-work"
CHANGELOG="${ROOT}/CHANGELOG.md"
TODAY=$(date +%Y-%m-%d)

for f in "$SCRIPT" "$CHANGELOG"; do
  [[ -f "$f" ]] || {
    echo "Error: ${f} not found." >&2
    exit 1
  }
done

CURRENT=$(sed -n 's/^# Version:[[:space:]]*//p' "$SCRIPT" | head -n 1)
PREVIOUS=$(sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' "$CHANGELOG" | head -n 1)

if [[ "$VERSION" == "$CURRENT" ]]; then
  echo "Error: already at ${VERSION}." >&2
  exit 1
fi

# Warn, but do not block: a release with no Unreleased notes is usually a
# mistake, occasionally deliberate.
if ! awk '/^## \[Unreleased\]/{f=1;next} f&&/^## \[/{exit} f&&NF{found=1} END{exit !found}' "$CHANGELOG"; then
  echo "Warning: the Unreleased section is empty." >&2
fi

# --- bin/claude-work ---
# -i.bak is the form both BSD and GNU sed accept.
sed -i.bak "s/^# Version:.*/# Version: ${VERSION}/" "$SCRIPT"
rm -f "${SCRIPT}.bak"

# --- CHANGELOG.md ---
awk \
  -v version="$VERSION" \
  -v today="$TODAY" \
  -v previous="$PREVIOUS" \
  -v repo="$REPO_URL" '
  /^## \[Unreleased\]/ {
    print
    print ""
    print "## [" version "] - " today
    next
  }
  /^\[Unreleased\]:/ {
    print "[Unreleased]: " repo "/compare/v" version "...HEAD"
    if (previous != "") {
      print "[" version "]: " repo "/compare/v" previous "...v" version
    } else {
      print "[" version "]: " repo "/releases/tag/v" version
    }
    next
  }
  { print }
' "$CHANGELOG" >"${CHANGELOG}.tmp"
mv "${CHANGELOG}.tmp" "$CHANGELOG"

echo "Bumped ${CURRENT} -> ${VERSION}"
echo
echo "Review the diff, then:"
echo
echo "  git add bin/claude-work CHANGELOG.md"
echo "  git commit -m \"chore: release ${VERSION}\""
echo "  git tag -a v${VERSION} -m \"v${VERSION}\""
echo "  git push origin main v${VERSION}"
