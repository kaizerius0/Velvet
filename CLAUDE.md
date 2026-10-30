# Velvet – Arbeitsweise

## Nach jeder Arbeit an der App – immer, ohne extra nachzufragen

Sobald eine Änderung an Velvet fertig ist (nicht nach jedem Zwischenschritt):

1. **Testen**: `xcodebuild test -project Velvet.xcodeproj -scheme Velvet -derivedDataPath <Scratchpad>/dd` – nur weitermachen, wenn alles grün ist.
2. **GitHub aktualisieren**: auf `main` committen und `git push origin main`. Nur die eigenen Dateien committen (`git commit -- <pfade>`), nie halbfertige Stände, die nicht bauen.
3. **Lokale App aktualisieren**: `Scripts/install.sh` – baut Release und ersetzt `/Applications/Velvet.app`. Läuft Velvet gerade, wird es beendet (bei laufenden Downloads fragt Velvet selbst nach).
4. **Bei großen Änderungen zusätzlich ein Release** – neue Funktionen, spürbare Fehlerbehebungen, alles, was ein Nutzer merkt. Kleinigkeiten (Tippfehler, interne Aufräumarbeiten) bekommen kein Release.
   1. Version erhöhen: `MARKETING_VERSION` in `Velvet.xcodeproj/project.pbxproj` (alle Vorkommen), z. B. 1.1 → 1.2, bei sehr großen Umbauten 2.0. Committen.
   2. In einer Datei im Scratchpad in 2–5 Stichpunkten auf Deutsch notieren, was für Nutzer neu ist.
   3. `Scripts/release.sh --notes <datei>` – baut die DMG aus HEAD (nicht aus dem Arbeitsordner), pusht `main` und den Tag `v<Version>` und legt das Release an.
   4. Ist GitHub CLI (`gh`) nicht angemeldet, öffnet das Skript die vorausgefüllte Release-Seite im Browser und zeigt die DMG im Finder. Dann dem Nutzer genau sagen: DMG ins Feld „Attach binaries by dropping them here …“ ziehen, Upload abwarten, „Publish release“ klicken. Den Link aus `dist/release-link-<Version>.txt` mitschicken.
   5. Danach prüfen, dass der Download von außen geht: `curl -sIL -o /dev/null -w '%{http_code}' https://github.com/kaizerius0/Velvet/releases/latest/download/Velvet-<Version>.dmg` muss `200` liefern.

Am Ende kurz melden, was davon passiert ist (gepusht, installiert, Release ja/nein mit Link).

Arbeiten mehrere Sessions gleichzeitig im Ordner: nur eigene Dateien committen, nicht gleichzeitig nach `build/` bauen, und ein Release erst, wenn alles zusammen baut und committet ist.

## Gut zu wissen

- Link für Freunde: https://github.com/kaizerius0/Velvet/releases/latest
- Release-DMGs sind nur für Apple Silicon (die gebündelten Werkzeuge in `Binaries/` sind arm64).
- Velvet ist nicht notarisiert (kein Apple-Entwicklerkonto). Nutzer müssen einmal „Dennoch öffnen“ in Systemeinstellungen → Datenschutz & Sicherheit.
- `YtDlpInstaller` entpackt yt-dlp mit `ditto --noqtn`. Nicht entfernen: Sonst erbt yt-dlp die Quarantäne einer geladenen App und macOS beendet es sofort.
