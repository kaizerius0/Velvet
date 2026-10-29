#!/bin/bash
#
# Lädt die Werkzeuge herunter, die Velvet ins App-Bundle packt:
#   yt-dlp  – offizielles macOS-Release von GitHub (yt-dlp_macos.zip: startet in
#             0,2 s statt ~7 s wie die Einzeldatei-Variante, die sich bei jedem Start entpackt)
#   ffmpeg  – statischer Build von ffmpeg.martin-riedl.de (auf ffmpeg.org verlinkt)
#   ffprobe – dito
#   deno    – JavaScript-Laufzeit, die yt-dlp für YouTube benötigt
#
# Alle Downloads werden per SHA-256 geprüft. Bereits vorhandene Werkzeuge
# werden übersprungen, außer das Skript wird mit --force aufgerufen.
#
# Aufruf:  Scripts/fetch-binaries.sh [--force]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Binaries"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

ARCH="${VELVET_ARCH:-$(uname -m)}"
case "$ARCH" in
    arm64)  FF_ARCH=arm64; DENO_ARCH=aarch64 ;;
    x86_64) FF_ARCH=amd64; DENO_ARCH=x86_64 ;;
    *) echo "error: Nicht unterstützte Architektur: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { echo "▸ $*"; }

fetch() {
    curl -fL --retry 3 --retry-delay 2 --silent --show-error -o "$2" "$1"
}

verify_sha256() {
    local expected="$1" file="$2" actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
        echo "error: Prüfsumme stimmt nicht für $(basename "$file") (erwartet '$expected', erhalten '$actual')" >&2
        exit 1
    fi
}

needs() {
    [[ $FORCE -eq 1 || ! -x "$DEST/$1" ]]
}

needs_file() {
    [[ $FORCE -eq 1 || ! -f "$DEST/$1" ]]
}

place() {
    install -m 755 "$1" "$DEST/$2"
    xattr -c "$DEST/$2" 2>/dev/null || true
}

# --- yt-dlp -----------------------------------------------------------------
if needs_file yt-dlp_macos.zip || needs_file yt-dlp.version; then
    tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/yt-dlp/yt-dlp/releases/latest | sed 's|.*/tag/||')"
    if [[ -z "$tag" || "$tag" == http* ]]; then
        echo "error: Aktuelle yt-dlp-Version konnte nicht ermittelt werden." >&2
        exit 1
    fi
    log "Lade yt-dlp $tag (yt-dlp_macos.zip) …"
    base="https://github.com/yt-dlp/yt-dlp/releases/download/$tag"
    fetch "$base/yt-dlp_macos.zip" "$TMP/yt-dlp_macos.zip"
    fetch "$base/SHA2-256SUMS" "$TMP/yt-dlp.sums"
    verify_sha256 "$(awk '$2 == "yt-dlp_macos.zip" {print $1}' "$TMP/yt-dlp.sums")" "$TMP/yt-dlp_macos.zip"
    install -m 644 "$TMP/yt-dlp_macos.zip" "$DEST/yt-dlp_macos.zip"
    xattr -c "$DEST/yt-dlp_macos.zip" 2>/dev/null || true
    echo "$tag" > "$DEST/yt-dlp.version"
    rm -f "$DEST/yt-dlp" # ältere Einzeldatei-Variante
fi
log "yt-dlp $(cat "$DEST/yt-dlp.version")"

# --- ffmpeg / ffprobe -------------------------------------------------------
if needs ffmpeg || needs ffprobe; then
    log "Suche aktuellen ffmpeg-Release-Build ($FF_ARCH) …"
    page="$(curl -fsSL https://ffmpeg.martin-riedl.de/)"
    # Release-Builds heißen <timestamp>_<version>, Snapshots <timestamp>_N-…
    dir="$(echo "$page" | grep -oE "/download/macos/$FF_ARCH/[0-9]+_[0-9][0-9.]*/ffmpeg\.zip" | head -1 | sed 's|/ffmpeg\.zip$||')"
    if [[ -z "$dir" ]]; then
        echo "error: Kein ffmpeg-Release-Build für $FF_ARCH gefunden." >&2
        exit 1
    fi
    for tool in ffmpeg ffprobe; do
        log "Lade $tool ($(basename "$dir" | cut -d_ -f2)) …"
        fetch "https://ffmpeg.martin-riedl.de$dir/$tool.zip" "$TMP/$tool.zip"
        fetch "https://ffmpeg.martin-riedl.de$dir/$tool.zip.sha256" "$TMP/$tool.zip.sha256"
        verify_sha256 "$(awk '{print $1}' "$TMP/$tool.zip.sha256")" "$TMP/$tool.zip"
        mkdir -p "$TMP/$tool"
        unzip -q -o "$TMP/$tool.zip" -d "$TMP/$tool"
        place "$TMP/$tool/$tool" "$tool"
    done
fi
log "$("$DEST/ffmpeg" -hide_banner -version | head -1)"

# --- deno -------------------------------------------------------------------
if needs deno; then
    log "Lade deno ($DENO_ARCH) …"
    asset="deno-$DENO_ARCH-apple-darwin.zip"
    base="https://github.com/denoland/deno/releases/latest/download"
    fetch "$base/$asset" "$TMP/$asset"
    fetch "$base/$asset.sha256sum" "$TMP/$asset.sha256sum"
    verify_sha256 "$(awk '{print $1}' "$TMP/$asset.sha256sum")" "$TMP/$asset"
    mkdir -p "$TMP/deno"
    unzip -q -o "$TMP/$asset" -d "$TMP/deno"
    place "$TMP/deno/deno" deno
fi
log "$("$DEST/deno" --version | head -1)"

log "Fertig. Werkzeuge liegen in $DEST"
