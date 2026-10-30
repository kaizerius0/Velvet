import Foundation

/// Prüft, ob Einträge einer Liste schon vorhanden sind – in der gewählten Bibliothek oder laut Verlauf woanders.
@MainActor
struct DuplicateChecker {
    let library: LibraryViewModel
    let history: HistoryStore

    private struct HistoryCandidate {
        let entry: HistoryEntry
        let titleTokens: Set<String>
        let queryTokens: Set<String>
    }

    func hits(for entries: [ParsedEntry]) -> [Int: DuplicateHit] {
        let historyIndex = history.entries
            .filter { $0.state == .downloaded }
            .map { HistoryCandidate(entry: $0, titleTokens: TitleMatcher.tokens($0.title), queryTokens: TitleMatcher.tokens($0.query ?? "")) }
        var result: [Int: DuplicateHit] = [:]
        for entry in entries {
            if let hit = hit(for: entry, historyIndex: historyIndex) { result[entry.id] = hit }
        }
        return result
    }

    private func hit(for entry: ParsedEntry, historyIndex: [HistoryCandidate]) -> DuplicateHit? {
        // 1. Dasselbe Video wurde schon einmal geladen.
        if let url = entry.url, let videoID = YouTubeLink.videoID(in: url) {
            let sameVideo = historyIndex.filter { $0.entry.videoID == videoID }
            if let hit = bestHistoryHit(sameVideo, strength: .exact) { return hit }
        }

        // 2. Titel vergleichen – zuerst mit den Dateien in der Bibliothek, dann mit dem Verlauf.
        let text = entry.label ?? (entry.isLink ? nil : entry.displayText)
        guard let text else { return nil }
        let tokens = TitleMatcher.tokens(text)
        guard !tokens.isEmpty else { return nil }

        var similar: DuplicateHit?
        for (track, trackTokens) in library.trackIndex {
            guard let strength = TitleMatcher.compare(tokens, trackTokens) else { continue }
            let hit = DuplicateHit(strength: strength, title: track.title, location: library.locationText(for: track.url), url: track.url, inCurrentLibrary: true)
            if strength == .exact { return hit }
            if similar == nil { similar = hit }
        }

        var exactElsewhere: [HistoryCandidate] = []
        var similarElsewhere: [HistoryCandidate] = []
        for candidate in historyIndex {
            let strengths = [TitleMatcher.compare(tokens, candidate.titleTokens), TitleMatcher.compare(tokens, candidate.queryTokens)]
            if strengths.contains(.exact) {
                exactElsewhere.append(candidate)
            } else if strengths.contains(.similar) {
                similarElsewhere.append(candidate)
            }
        }
        if let hit = bestHistoryHit(exactElsewhere, strength: .exact) { return hit }
        return similar ?? bestHistoryHit(similarElsewhere, strength: .similar)
    }

    /// Bevorzugt Dateien, die es noch gibt; ein abgezogener Stick zählt auch.
    private func bestHistoryHit(_ candidates: [HistoryCandidate], strength: DuplicateHit.Strength) -> DuplicateHit? {
        var offline: DuplicateHit?
        for candidate in candidates {
            switch history.availability(of: candidate.entry, volumes: library.volumes) {
            case let .present(url):
                let location = library.contains(url) ? library.locationText(for: url) : candidate.entry.locationText
                return DuplicateHit(strength: strength, title: candidate.entry.title, location: location, url: url, inCurrentLibrary: library.contains(url))
            case let .offline(volume):
                if offline == nil {
                    offline = DuplicateHit(strength: strength, title: candidate.entry.title,
                                           location: "\(volume) › \(candidate.entry.folderName) (nicht verbunden)", url: nil, inCurrentLibrary: false)
                }
            default:
                continue
            }
        }
        return offline
    }
}
