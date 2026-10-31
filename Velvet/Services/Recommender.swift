import Foundation

/// Ein Vorschlag aus „Entdecken“ oder dem Set-Builder.
struct Suggestion: Identifiable, Hashable, Sendable {
    let candidate: VideoCandidate
    let version: TrackVersion
    var score: Double
    /// In wie vielen Mixes/Listen der Titel vorkam – je öfter, desto sicherer passt er.
    var hits: Int

    var id: String { candidate.id }

    init(candidate: VideoCandidate, score: Double = 0, hits: Int = 1) {
        self.candidate = candidate
        version = candidate.version
        self.score = score
        self.hits = hits
    }
}

extension Suggestion: Codable {
    private enum CodingKeys: String, CodingKey {
        case candidate, score, hits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            candidate: try container.decode(VideoCandidate.self, forKey: .candidate),
            score: try container.decode(Double.self, forKey: .score),
            hits: try container.decode(Int.self, forKey: .hits)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(candidate, forKey: .candidate)
        try container.encode(score, forKey: .score)
        try container.encode(hits, forKey: .hits)
    }
}

extension TrackVersion {
    /// Lied ohne Version – „Breathe (Club Mix)“ und „Breathe (Radio Edit)“ sind dasselbe Lied.
    var baseKey: String {
        TitleMatcher.tokens([artist ?? "", song].joined(separator: " ")).sorted().joined(separator: " ")
    }
}

/// Macht aus mehreren Listen (YouTube-Mixe, Label-Uploads, Suchergebnisse) eine Rangliste.
///
/// Punkte gibt es dafür, wie oft und wie weit vorn ein Titel in den Listen auftaucht, für die bevorzugte
/// Version (Extended …), offizielle Tonspuren und Künstler, die du magst. Ganze DJ-Sets, Live-Mitschnitte,
/// Sped-up-Versionen, Ausgeblendetes und alles, was schon in deiner Bibliothek liegt, fliegt raus.
enum Recommender {
    struct Context {
        var preference: PreferredVersion = .any
        /// Videos, die nicht vorkommen sollen (ausgeblendet, Ausgangstitel …).
        var excludedIDs: Set<String> = []
        /// Lieder (`baseKey`), die schon da sind – in der Bibliothek oder als Ausgangstitel.
        var excludedSongs: Set<String> = []
        /// Vorliebe je Künstler (`artistKey`).
        var artistBias: [String: Double] = [:]
        /// Nur lange Versionen (Extended/Club/Original oder über 5 Minuten).
        var onlyLong = false
    }

    static func rank(_ pools: [[VideoCandidate]], context: Context, limit: Int) -> [Suggestion] {
        var bySong: [String: Suggestion] = [:]
        var poolsPerSong: [String: Set<Int>] = [:]
        var order: [String] = []

        for (poolIndex, pool) in pools.enumerated() {
            for (position, candidate) in pool.enumerated() {
                guard !context.excludedIDs.contains(candidate.id), isUsable(candidate) else { continue }
                let suggestion = Suggestion(candidate: candidate)
                let version = suggestion.version
                if version.isFullSet || version.badges.contains(.spedUp) || version.badges.contains(.slowed) { continue }
                if context.onlyLong, !version.isLong(duration: candidate.duration) { continue }
                let song = version.baseKey
                guard !song.isEmpty, !context.excludedSongs.contains(song) else { continue }

                // Weiter vorn in einer Liste zählt mehr.
                let positional = 1 / (1 + Double(position) / 8)
                let quality = context.preference.score(version, duration: candidate.duration)
                    + (version.isTopicChannel ? 0.3 : 0)
                    + (version.badges.contains(.lyrics) ? -0.2 : 0)
                let bias = (version.artistKey.flatMap { context.artistBias[$0] } ?? 0) * 0.4

                poolsPerSong[song, default: []].insert(poolIndex)
                if var existing = bySong[song] {
                    existing.score += positional
                    // Von mehreren Uploads desselben Lieds die bessere Version behalten.
                    let existingQuality = context.preference.score(existing.version, duration: existing.candidate.duration)
                    if quality > existingQuality + 0.01 {
                        existing = Suggestion(candidate: candidate, score: existing.score - existingQuality + quality, hits: existing.hits)
                    }
                    bySong[song] = existing
                } else {
                    bySong[song] = Suggestion(candidate: candidate, score: positional + quality + bias)
                    order.append(song)
                }
            }
        }

        var ranked: [Suggestion] = order.compactMap { song in
            guard var suggestion = bySong[song] else { return nil }
            let hits = poolsPerSong[song]?.count ?? 1
            suggestion.hits = hits
            suggestion.score += Double(hits - 1) * 2
            return suggestion
        }
        ranked.sort { $0.score != $1.score ? $0.score > $1.score : $0.candidate.id < $1.candidate.id }
        return Array(ranked.prefix(limit))
    }

    /// Kurze Clips, Shorts und Videos ohne Länge (meist Livestreams) taugen nicht.
    static func isUsable(_ candidate: VideoCandidate) -> Bool {
        guard let duration = candidate.duration else { return true }
        return duration >= 90 && duration <= 15 * 60
    }

    /// Die Lieder einer Bibliothek als `baseKey` – zum Ausblenden von schon Vorhandenem.
    static func songKeys(of titles: [String]) -> Set<String> {
        Set(titles.map { TrackVersion.parse($0).baseKey }.filter { !$0.isEmpty })
    }
}

// MARK: - Sets

/// Reihenfolge und Filter für DJ-Sets: Tempo und Tonart.
enum SetPlanner {
    /// Tempo-Abstand – halbes und doppeltes Tempo zählen als passend (87 ↔ 174 BPM).
    static func tempoDistance(_ a: Double, _ b: Double) -> Double {
        [b, b * 2, b / 2].map { abs(a - $0) }.min() ?? abs(a - b)
    }

    /// Harmonisch sortieren: Immer der Titel als Nächstes, der tonal und vom Tempo am besten anschließt.
    static func harmonicOrder<T>(_ items: [T], start: TrackAnalysis?, analysis: (T) -> TrackAnalysis?) -> [T] {
        var remaining = items
        var result: [T] = []
        var current = start
        while !remaining.isEmpty {
            let index = remaining.indices.min { lhs, rhs in
                cost(from: current, to: analysis(remaining[lhs])) < cost(from: current, to: analysis(remaining[rhs]))
            } ?? 0
            let next = remaining.remove(at: index)
            current = analysis(next) ?? current
            result.append(next)
        }
        return result
    }

    /// Nach Tempo aufsteigend; ohne bekanntes Tempo ans Ende.
    static func tempoOrder<T>(_ items: [T], analysis: (T) -> TrackAnalysis?) -> [T] {
        items.enumerated().sorted { lhs, rhs in
            switch (analysis(lhs.element)?.bpm, analysis(rhs.element)?.bpm) {
            case let (a?, b?): return a != b ? a < b : lhs.offset < rhs.offset
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private static func cost(from: TrackAnalysis?, to: TrackAnalysis?) -> Double {
        var cost = 0.0
        if let a = from?.key, let b = to?.key {
            cost += Double(a.distance(to: b)) * 3
        } else {
            cost += 4
        }
        if let a = from?.bpm, let b = to?.bpm {
            cost += tempoDistance(a, b) / 2
        } else {
            cost += 3
        }
        return cost
    }
}
