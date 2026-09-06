#!/bin/zsh
# Veröffentlicht die Version aus VERSION: DMG bauen, Tag setzen, pushen und
# ein GitHub-Release mit dem DMG anlegen. Der Update-Check in der App liest
# genau dieses Release (Tag "v<version>", Asset "floosh-<version>.dmg").
#
#   ./Tools/release.sh              # Notizen aus docs/releases/<version>.md,
#                                   # sonst von GitHub generiert
#   ./Tools/release.sh --notes "…"  # Notizen direkt angeben
#   ./Tools/release.sh --dry-run    # nur bauen, nichts pushen/anlegen
set -e
cd "$(dirname "$0")/.."

VERSION=$(tr -d '[:space:]' < VERSION)
TAG="v$VERSION"
DMG="build/floosh-$VERSION.dmg"
NOTES_FILE="docs/releases/$VERSION.md"
DRY_RUN=0
NOTES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "✗ Unbekanntes Argument: $1"; exit 1 ;;
  esac
done

[[ -z "$(git status --porcelain)" ]] || { echo "✗ Working Tree nicht sauber — erst committen."; exit 1 }
if (( ! DRY_RUN )); then
  gh auth status >/dev/null 2>&1 || { echo "✗ gh ist nicht eingeloggt (gh auth login)."; exit 1 }
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "✗ Release $TAG existiert bereits — VERSION erhöhen."; exit 1
  fi
fi

echo "→ floosh $VERSION"
./Tools/make-dmg.sh
[[ -f "$DMG" ]] || { echo "✗ $DMG fehlt"; exit 1 }

if (( DRY_RUN )); then
  echo "✓ Dry-Run: $DMG gebaut, kein Tag/Release angelegt."
  exit 0
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "→ Tag $TAG existiert bereits"
else
  git tag -a "$TAG" -m "floosh $VERSION"
fi
git push origin HEAD "$TAG"

if [[ -n "$NOTES" ]]; then
  gh release create "$TAG" "$DMG" --title "floosh $VERSION" --notes "$NOTES"
elif [[ -f "$NOTES_FILE" ]]; then
  gh release create "$TAG" "$DMG" --title "floosh $VERSION" --notes-file "$NOTES_FILE"
else
  gh release create "$TAG" "$DMG" --title "floosh $VERSION" --generate-notes
fi
echo "✓ Release $TAG veröffentlicht: $(gh release view "$TAG" --json url --jq .url)"
