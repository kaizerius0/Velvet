import Foundation

/// Maschinenlesbare Zeilen, die Velvet per `--print` und `--progress-template` von yt-dlp anfordert.
enum YTDLPEvent: Equatable, Sendable {
    case info(videoID: String, formatID: String, title: String)
    case progress(formatID: String, status: String, downloaded: Double?, total: Double?, speed: Double?, eta: Double?)
    case postprocess(status: String, name: String)
    case file(String)
}

/// Alles rund ums Lesen der yt-dlp-Ausgabe: Fortschritt, Suchergebnisse, Fehlermeldungen.
enum YTDLPOutput {
    enum Marker {
        static let prefix = "VELVET|"
        static let info = "VELVET|INFO"
        static let download = "VELVET|DL"
        static let postprocess = "VELVET|PP"
        static let file = "VELVET|FILE"
    }

    static let progressTemplate = "download:\(Marker.download)|%(info.format_id)s|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s"
    static let postprocessTemplate = "postprocess:\(Marker.postprocess)|%(progress.status)s|%(progress.postprocessor)s"
    static let infoTemplate = "before_dl:\(Marker.info)|%(id)s|%(format_id)s|%(title)s"
    static let fileTemplate = "after_move:\(Marker.file)|%(filepath)s"

    /// Anteil des eigentlichen Downloads am Gesamtfortschritt; der Rest ist Nachbearbeitung.
    static let downloadShare = 0.95

    // MARK: Zeilen

    static func parse(_ line: String) -> YTDLPEvent? {
        guard line.hasPrefix(Marker.prefix) else { return nil }
        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3 else { return nil }

        switch fields[1] {
        case "INFO" where fields.count >= 5:
            return .info(videoID: fields[2], formatID: fields[3], title: fields[4...].joined(separator: "|"))
        case "DL" where fields.count >= 9:
            return .progress(
                formatID: fields[2],
                status: fields[3],
                downloaded: number(fields[4]),
                total: number(fields[5]) ?? number(fields[6]),
                speed: number(fields[7]),
                eta: number(fields[8])
            )
        case "PP" where fields.count >= 4:
            return .postprocess(status: fields[2], name: fields[3])
        case "FILE":
            return .file(fields[2...].joined(separator: "|"))
        default:
            return nil
        }
    }

    private static func number(_ text: String) -> Double? {
        guard text != "NA", text != "None" else { return nil }
        return Double(text)
    }

    /// Bei getrennten Video- und Tonspuren (z. B. "136+140") zählt das Video 85 %, der Ton 15 %.
    static func downloadFraction(formatParts: [String], formatID: String, downloaded: Double?, total: Double?) -> Double? {
        guard let downloaded, let total, total > 0 else { return nil }
        let part = min(max(downloaded / total, 0), 1)
        let count = max(formatParts.count, 1)
        let weights: [Double] = count == 2 ? [0.85, 0.15] : Array(repeating: 1 / Double(count), count: count)
        let index = min(formatParts.firstIndex(of: formatID) ?? 0, weights.count - 1)
        let before = weights.prefix(index).reduce(0, +)
        return (before + weights[index] * part) * downloadShare
    }

    /// Deutsche Beschreibung des Nachbearbeitungsschritts – `nil` für Schritte, die man nicht anzeigen muss.
    static func postprocessorLabel(_ name: String) -> String? {
        switch name {
        case "Merger": return "Video und Ton werden zusammengeführt …"
        case "ExtractAudio": return "Tonspur wird erstellt …"
        case "VideoRemuxer", "VideoConvertor": return "Wird ins MP4-Format gebracht …"
        case "Metadata", "FFmpegMetadata": return "Metadaten werden geschrieben …"
        case "EmbedThumbnail": return "Cover wird eingebettet …"
        case "MoveFiles": return "Datei wird abgelegt …"
        case "MetadataParser", "ThumbnailsConvertor", "FixupM3u8", "FixupM4a", "FixupDuplicateMoov", "FixupTimestamp", "FixupDuration", "FixupStretched":
            return nil
        default: return "Nachbearbeitung …"
        }
    }

    static func skipReason(in line: String) -> SkipReason? {
        if line.contains("has already been recorded in the archive") { return .archived }
        if line.contains("has already been downloaded") { return .alreadyExists }
        if line.contains("does not pass filter") { return .livestream }
        return nil
    }

    static func errorMessage(in line: String) -> String? {
        guard line.hasPrefix("ERROR:") else { return nil }
        return String(line.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Suchergebnisse & Playlists

    enum ParseError: LocalizedError {
        case invalidJSON

        var errorDescription: String? { "Die Antwort von yt-dlp konnte nicht gelesen werden." }
    }

    /// Liest die Einträge aus `--flat-playlist --dump-single-json` (Suche oder Playlist).
    static func parseEntries(_ data: Data) throws -> [VideoCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        let entries = root["entries"] as? [Any] ?? []
        return entries.compactMap { ($0 as? [String: Any]).flatMap(candidate(from:)) }
    }

    static func candidate(from entry: [String: Any]) -> VideoCandidate? {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if title.isEmpty || title == "[Deleted video]" || title == "[Private video]" { return nil }

        let liveStatus = entry["live_status"] as? String
        if liveStatus == "is_live" || liveStatus == "is_upcoming" || (entry["is_live"] as? Bool) == true {
            return nil
        }

        let url = ((entry["url"] as? String) ?? (entry["webpage_url"] as? String)).flatMap(URL.init(string:))
            ?? YouTubeLink.watchURL(id)
        let channel = (entry["channel"] as? String) ?? (entry["uploader"] as? String)
        let isYouTube = YouTubeLink.isYouTube(url) || (entry["ie_key"] as? String) == "Youtube"

        return VideoCandidate(
            id: id,
            title: title,
            channel: channel,
            duration: (entry["duration"] as? NSNumber)?.doubleValue,
            viewCount: (entry["view_count"] as? NSNumber)?.intValue,
            thumbnailURL: bestThumbnail(entry["thumbnails"]) ?? (isYouTube ? YouTubeLink.thumbnailURL(id) : nil),
            url: url,
            channelID: entry["channel_id"] as? String
        )
    }

    /// Wählt ein Vorschaubild mit etwa 480 px Breite.
    private static func bestThumbnail(_ value: Any?) -> URL? {
        guard let thumbnails = value as? [[String: Any]], !thumbnails.isEmpty else { return nil }
        let scored = thumbnails.compactMap { thumb -> (URL, Double)? in
            guard let string = thumb["url"] as? String, let url = URL(string: string) else { return nil }
            let width = (thumb["width"] as? NSNumber)?.doubleValue ?? 0
            return (url, width == 0 ? 10_000 : abs(width - 480))
        }
        return scored.min { $0.1 < $1.1 }?.0
    }

    // MARK: Fehlermeldungen

    /// Übersetzt typische yt-dlp-Fehler in verständliches Deutsch.
    static func friendlyError(_ raw: String) -> String {
        var message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.hasPrefix("ERROR:") { message = String(message.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        // "[youtube] dQw4w9WgXcQ: …" → "…"
        if let range = message.range(of: #"^\[[^\]]+\]\s*([A-Za-z0-9_-]+:\s+)?"#, options: .regularExpression) {
            message.removeSubrange(range)
        }
        let lower = message.lowercased()

        func has(_ needles: String...) -> Bool { needles.contains { lower.contains($0) } }

        if has("not a bot", "confirm you’re not", "confirm you're not") {
            return "YouTube verlangt eine Bot-Prüfung. Aktiviere in den Einstellungen „Cookies aus Browser“ oder versuche es später erneut."
        }
        if has("confirm your age", "age-restricted", "age restricted", "inappropriate for some users") {
            return "Altersbeschränktes Video – dafür werden Browser-Cookies benötigt (Einstellungen → Cookies aus Browser)."
        }
        if has("private video") { return "Das Video ist privat." }
        if has("members-only", "join this channel", "available to this channel's members") {
            return "Das Video ist nur für Kanalmitglieder verfügbar."
        }
        if has("not available in your country", "geo restrict", "blocked it in your country") {
            return "Das Video ist in deinem Land nicht verfügbar."
        }
        if has("premieres in", "live event will begin", "this live event") {
            return "Das Video ist noch nicht veröffentlicht (Premiere oder Livestream)."
        }
        if has("video unavailable", "no longer available", "has been removed", "this video is unavailable", "does not exist") {
            return "Das Video ist nicht (mehr) verfügbar."
        }
        if has("requested format is not available", "no video formats found") {
            return "Das gewünschte Format ist nicht verfügbar. Tipp: yt-dlp in den Einstellungen aktualisieren."
        }
        if has("http error 403", "forbidden") {
            return "YouTube hat den Download blockiert (HTTP 403). Tipp: yt-dlp in den Einstellungen aktualisieren."
        }
        if has("http error 429", "too many requests", "rate-limit", "rate limit") {
            return "Zu viele Anfragen – YouTube bremst gerade. Bitte später erneut versuchen."
        }
        if has("challenge", "signature", "nsig") {
            return "YouTube-Schutz konnte nicht gelöst werden. Tipp: yt-dlp in den Einstellungen aktualisieren."
        }
        if has("no space left") { return "Nicht genug Speicherplatz im Zielordner." }
        if has("permission denied", "operation not permitted", "read-only file system") {
            return "Keine Schreibrechte im Zielordner."
        }
        if has("unsupported url") { return "Dieser Link wird nicht unterstützt." }
        if has("is not a valid url") { return "Das ist kein gültiger Link." }
        if has("ffmpeg not found", "ffprobe not found", "ffmpeg is not installed") {
            return "ffmpeg wurde nicht gefunden – bitte „Werkzeuge erneut prüfen“."
        }
        if has("interrupted by user") { return "Abgebrochen." }
        if has("urlopen error", "timed out", "connection reset", "connection refused", "network is unreachable",
               "nodename nor servname", "name or service not known", "failed to resolve", "unable to download webpage",
               "ssl", "temporary failure in name resolution") {
            return "Netzwerkfehler – bitte Internetverbindung prüfen und erneut versuchen."
        }
        if has("postprocessing", "conversion failed") {
            return "Nachbearbeitung fehlgeschlagen: \(truncated(message))"
        }
        return message.isEmpty ? "Unbekannter Fehler." : truncated(message)
    }

    private static func truncated(_ text: String, limit: Int = 240) -> String {
        text.count > limit ? String(text.prefix(limit)) + " …" : text
    }
}
