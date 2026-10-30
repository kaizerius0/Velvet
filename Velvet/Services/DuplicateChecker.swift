import Foundation

/// Prüft, ob Titel schon vorhanden sind – in der gewählten Bibliothek, einer anderen oder laut Verlauf.
@MainActor
struct DuplicateChecker {
    let library: LibraryViewModel
    let history: HistoryStore
    /// Die Bibliothek, in die gerade geladen wird (`nil`: noch kein Ziel gewählt).
    let sourceID: String?

    private struct HistoryCandidate {
        let entry: HistoryEntry
        let titleTokens: Set<String>
        let queryTokens: Set<String>
    }

    // MARK: Einträge einer Liste

    func hits(for entries: [ParsedEntry]) -> [Int: DuplicateHit] {
        let historyIndex = makeHistoryIndex()
        var result: [Int: DuplicateHit] = [:]
        for entry in entries {
            if let hit = hit(for: entry, historyIndex: historyIndex) { result[entry.id] = hit }
        }
        return result
    }

    private func hit(for entry: ParsedEntry, historyIndex: [HistoryCandidate]) -> DuplicateHit? {
        if let url = entry.url, let videoID = YouTubeLink.videoID(in: url),
           let hit = bestHistoryHit(historyIndex.filter { $0.entry.videoID == videoID }, strength: .exact) {
            return hit
        }
        let text = entry.label ?? (entry.isLink ? nil : entry.displayText)
        guard let text else { return nil }
        return titleHit(for: TitleMatcher.tokens(text), historyIndex: historyIndex)
    }

    // MARK: Einzelne Suchergebnisse

    /// Liegt dieses Video (oder ein gleichnamiger Titel) schon in der gewählten Bibliothek?
    func existingLocation(of candidate: VideoCandidate) -> String? {
        for entry in history.entries where entry.videoID == candidate.id && entry.state == .downloaded {
            if case let .present(url) = history.availability(of: entry, volumes: library.volumes),
               library.source(containing: url)?.id == sourceID {
                return library.locationText(for: url)
            }
        }
        let tokens = TitleMatcher.tokens(candidate.title)
        let match = library.trackIndex.first { $0.sourceID == sourceID && TitleMatcher.compare(tokens, $0.tokens) == .exact }
        return match.map { library.locationText(for: $0.track.url) }
    }

    // MARK: Intern

    private func titleHit(for tokens: Set<String>, historyIndex: [HistoryCandidate]) -> DuplicateHit? {
        guard !tokens.isEmpty else { return nil }

        // Zuerst die Bibliothek, in die geladen wird, dann die übrigen.
        let ordered = library.trackIndex.filter { $0.sourceID == sourceID } + library.trackIndex.filter { $0.sourceID != sourceID }
        var similar: DuplicateHit?
        for indexed in ordered {
            guard let strength = TitleMatcher.compare(tokens, indexed.tokens) else { continue }
            let hit = DuplicateHit(strength: strength, title: indexed.track.title, location: library.locationText(for: indexed.track.url),
                                   url: indexed.track.url, inCurrentLibrary: indexed.sourceID == sourceID)
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

    private func makeHistoryIndex() -> [HistoryCandidate] {
        history.entries
            .filter { $0.state == .downloaded }
            .map { HistoryCandidate(entry: $0, titleTokens: TitleMatcher.tokens($0.title), queryTokens: TitleMatcher.tokens($0.query ?? "")) }
    }

    /// Bevorzugt Dateien, die es noch gibt; ein abgezogener Stick zählt auch.
    private func bestHistoryHit(_ candidates: [HistoryCandidate], strength: DuplicateHit.Strength) -> DuplicateHit? {
        var offline: DuplicateHit?
        for candidate in candidates {
            switch history.availability(of: candidate.entry, volumes: library.volumes) {
            case let .present(url):
                let source = library.source(containing: url)
                return DuplicateHit(strength: strength, title: candidate.entry.title,
                                    location: source == nil ? candidate.entry.locationText : library.locationText(for: url),
                                    url: url, inCurrentLibrary: source?.id == sourceID)
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
