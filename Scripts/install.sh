#!/bin/bash
#
# Baut Velvet (Release) und installiert die App nach /Applications („Programme“).
# Danach startet man Velvet wie jede andere App: Launchpad, Spotlight, Dock oder Finder.
#
# Aufruf:  Scripts/install.sh          # bauen + installieren
#          Scripts/install.sh --open   # danach direkt öffnen

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Applications/Velvet.app"
BUILD="$ROOT/build"
BUILT_APP="$BUILD/Build/Products/Release/Velvet.app"

log() { echo "▸ $*"; }

log "Baue Velvet (Release) …"
xcodebuild -project "$ROOT/Velvet.xcodeproj" -scheme Velvet -configuration Release \
    -derivedDataPath "$BUILD" build -quiet

# Läuft die installierte App, wird sie zuerst beendet – sie fragt selbst nach, falls noch Downloads laufen.
# Nur Prozesse, deren Befehl mit dem App-Pfad beginnt – nicht etwa Shells, die den Pfad nur erwähnen.
is_running() { pgrep -f "^$DEST/Contents/MacOS/Velvet" >/dev/null; }
if is_running; then
    log "Velvet läuft – App wird beendet …"
    osascript -e 'tell application id "de.velvet.Velvet" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
        is_running || break
        sleep 1
    done
    if is_running; then
        echo "error: Velvet läuft noch (vermutlich laufen Downloads). Bitte Velvet beenden und das Skript erneut starten." >&2
        exit 1
    fi
fi

log "Installiere nach $DEST …"
rm -rf "$DEST"
ditto "$BUILT_APP" "$DEST"
log "Fertig: Velvet $(defaults read "$DEST/Contents/Info" CFBundleShortVersionString) ist installiert."

if [[ "${1:-}" == "--open" ]]; then
    open "$DEST"
fi
