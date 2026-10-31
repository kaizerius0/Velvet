#!/bin/bash
#
# Veröffentlicht ein neues Velvet-Release auf GitHub:
#   1. baut die DMG aus dem aktuellen Commit (HEAD) – nicht aus dem Arbeitsordner,
#      damit halbfertige Änderungen nie in ein Release geraten
#   2. schreibt die Release-Notizen (Neuigkeiten + Installationsanleitung)
#   3. pusht main, setzt den Tag v<Version> und pusht ihn
#   4. legt das Release an – mit GitHub CLI (gh) automatisch, sonst öffnet sich die
#      vorausgefüllte Release-Seite im Browser und die DMG wird im Finder gezeigt
#
# Die Version kommt aus MARKETING_VERSION im Xcode-Projekt – vorher erhöhen und committen.
#
# Aufruf:  Scripts/release.sh --notes neu.md   # neu.md: Stichpunkte, was neu ist
#          Scripts/release.sh --dry-run        # nur DMG und Notizen bauen (dist/probelauf), nichts veröffentlichen

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="kaizerius0/Velvet"
NOTES_IN=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes) NOTES_IN="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "error: Unbekannte Option: $1" >&2; exit 1 ;;
    esac
done

log() { echo "▸ $*"; }
urlencode() { perl -0777 -pe 's/([^A-Za-z0-9\-._~])/sprintf("%%%02X", ord($1))/seg'; }

cd "$ROOT"
VERSION="$(git show HEAD:Velvet.xcodeproj/project.pbxproj | awk -F' = ' '/MARKETING_VERSION/ { sub(/;.*/, "", $2); print $2; exit }')"
TAG="v$VERSION"
DIST="$ROOT/dist"
[[ $DRY_RUN -eq 1 ]] && DIST="$ROOT/dist/probelauf"

if [[ $DRY_RUN -eq 0 ]]; then
    if [[ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]]; then
        echo "error: Releases nur von main." >&2; exit 1
    fi
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        echo "error: Tag $TAG gibt es schon. Bitte MARKETING_VERSION im Xcode-Projekt erhöhen und committen." >&2; exit 1
    fi
    if [[ -z "$NOTES_IN" || ! -f "$NOTES_IN" ]]; then
        echo "error: Bitte mit --notes <datei> angeben, was neu ist." >&2; exit 1
    fi
fi

[[ -x "$ROOT/Binaries/ffmpeg" ]] || "$ROOT/Scripts/fetch-binaries.sh"

# --- DMG aus HEAD bauen ---------------------------------------------------------
log "Baue Velvet $VERSION aus Commit $(git rev-parse --short HEAD) …"
CLEAN="$(mktemp -d)"
trap 'rm -rf "$CLEAN"' EXIT
git archive HEAD | tar -x -C "$CLEAN"
ln -s "$ROOT/Binaries" "$CLEAN/Binaries"
"$CLEAN/Scripts/make-release.sh"

mkdir -p "$DIST"
DMG="$DIST/Velvet-$VERSION.dmg"
cp "$CLEAN/dist/Velvet-$VERSION.dmg" "$DMG"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"

# --- Release-Notizen ------------------------------------------------------------
YTDLP="$(cat "$ROOT/Binaries/yt-dlp.version")"
FFMPEG="$("$ROOT/Binaries/ffmpeg" -hide_banner -version | head -1 | awk '{print $3}' | cut -d- -f1)"
DENO="$("$ROOT/Binaries/deno" --version | head -1 | awk '{print $2}')"
NOTES="$DIST/Release-Notes-$VERSION.md"
{
    echo "**Spotify für deinen Stick.** Velvet ist für DJs und alle, die ihre Musik auf einem USB-Stick brauchen: entdecken wie bei Spotify, kurz reinhören – und was gefällt, landet als MP3 auf dem Stick (Quelle: YouTube). yt-dlp, ffmpeg und deno sind schon enthalten – nichts muss extra installiert werden."
    echo
    if [[ -n "$NOTES_IN" ]]; then
        echo "## Neu in Version $VERSION"
        echo
        cat "$NOTES_IN"
        echo
    fi
    cat <<EOF
## Voraussetzungen

- Mac mit Apple-Chip (M1 oder neuer) – Intel-Macs werden nicht unterstützt
- macOS 13 Ventura oder neuer

## Installieren

1. **Velvet-$VERSION.dmg** unten unter „Assets“ herunterladen und öffnen.
2. **Velvet** auf **Programme** ziehen (eine ältere Version wird dabei ersetzt).
3. Velvet in Programme öffnen. macOS meldet beim ersten Mal „„Velvet“ wurde nicht geöffnet“ → auf **Fertig** klicken.
4. **Systemeinstellungen → Datenschutz & Sicherheit** öffnen, ganz nach unten scrollen und bei „„Velvet“ wurde blockiert …“ auf **Dennoch öffnen** klicken. Mit Passwort oder Touch ID bestätigen und im nächsten Fenster nochmal **Dennoch öffnen**.
5. Beim ersten Start richtet Velvet seine Werkzeuge ein (ca. 10 Sekunden). Oben rechts steht dann „Bereit“.

Schritt 3 und 4 sind nach jedem neuen Download einmal nötig. macOS warnt, weil Velvet nicht bei Apple notarisiert ist (dafür bräuchte es ein kostenpflichtiges Apple-Entwicklerkonto).

Alternativ statt Schritt 3 und 4 im Terminal:

\`\`\`
xattr -dr com.apple.quarantine /Applications/Velvet.app
\`\`\`

## Enthalten

- yt-dlp $YTDLP (lässt sich in den Einstellungen aktualisieren)
- ffmpeg / ffprobe $FFMPEG ([martin-riedl.de](https://ffmpeg.martin-riedl.de), GPL)
- deno $DENO (MIT)

Velvet ist für den privaten Gebrauch gedacht. Lade nur Inhalte herunter, an denen du die Rechte hast oder deren Download erlaubt ist.

SHA-256 der DMG: \`$SHA\`
EOF
} > "$NOTES"

if [[ $DRY_RUN -eq 1 ]]; then
    log "Probelauf fertig – nichts veröffentlicht."
    log "DMG:      $DMG"
    log "Notizen:  $NOTES"
    exit 0
fi

# --- Veröffentlichen ------------------------------------------------------------
log "Pushe main und Tag $TAG …"
git push origin main
git tag -a "$TAG" -m "Velvet $VERSION"
git push origin "$TAG"

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    log "Lege Release $TAG an und lade die DMG hoch …"
    gh release create "$TAG" "$DMG" --repo "$REPO" --title "Velvet $VERSION" --notes-file "$NOTES"
    log "Fertig: https://github.com/$REPO/releases/tag/$TAG"
else
    URL="https://github.com/$REPO/releases/new?tag=$TAG&title=$(printf 'Velvet %s' "$VERSION" | urlencode)&body=$(urlencode < "$NOTES")"
    printf '%s\n' "$URL" > "$DIST/release-link-$VERSION.txt"
    open "$URL"
    open -R "$DMG"
    cat <<EOF

Tag $TAG ist auf GitHub. GitHub CLI ist nicht angemeldet, darum geht der letzte Schritt im Browser:
  Die Release-Seite ist geöffnet (Titel und Text sind schon eingetragen), die DMG ist im Finder markiert.
  1. Velvet-$VERSION.dmg ins Feld „Attach binaries by dropping them here …“ ziehen
  2. warten, bis der Upload fertig ist
  3. „Publish release“ klicken
Link zum Wieder-Öffnen: $DIST/release-link-$VERSION.txt
EOF
fi
