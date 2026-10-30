#!/bin/bash
#
# Baut Velvet (Release, Apple Silicon) und verpackt die App als DMG zum Weitergeben,
# z. B. als Anhang eines GitHub-Releases. Die DMG enthält Velvet.app und eine
# Verknüpfung zu /Programme – man zieht die App einfach hinüber.
#
# Aufruf:  Scripts/make-release.sh
# Ergebnis: dist/Velvet-<Version>.dmg

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
BUILT_APP="$BUILD/Build/Products/Release/Velvet.app"

log() { echo "▸ $*"; }

# Die gebündelten Werkzeuge (ffmpeg, ffprobe, deno) gibt es nur für eine Architektur –
# die App wird deshalb passend dazu gebaut.
if [[ -x "$ROOT/Binaries/ffmpeg" && "$(lipo -archs "$ROOT/Binaries/ffmpeg")" != "arm64" ]]; then
    echo "error: Binaries/ enthält keine Apple-Silicon-Werkzeuge. Bitte Scripts/fetch-binaries.sh --force ausführen." >&2
    exit 1
fi

log "Baue Velvet (Release, arm64) …"
xcodebuild -project "$ROOT/Velvet.xcodeproj" -scheme Velvet -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$BUILD" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build -quiet

VERSION="$(defaults read "$BUILT_APP/Contents/Info" CFBundleShortVersionString)"
DMG="$DIST/Velvet-$VERSION.dmg"

log "Prüfe Signatur …"
codesign --verify --deep --strict "$BUILT_APP"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$BUILT_APP" "$STAGING/Velvet.app"
ln -s /Applications "$STAGING/Programme"

log "Erstelle $(basename "$DMG") …"
mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create -volname "Velvet $VERSION" -srcfolder "$STAGING" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "$DMG" -quiet

log "Fertig: $DMG ($(du -h "$DMG" | awk '{print $1}'))"
log "SHA-256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
