import Foundation

/// Vergleicht Liedtitel unscharf: „toto africa“ = „Toto - Africa (Official HD Video).mp3“.
enum TitleMatcher {
    /// Wörter, die nichts über das Lied selbst sagen.
    private static let noise: Set<String> = [
        "official", "offizielles", "offiziell", "video", "videoclip", "clip", "audio", "lyrics", "lyric", "songtext",
        "hd", "hq", "uhd", "4k", "8k", "1080p", "720p", "remastered", "remaster", "visualizer", "visualiser", "mv",
        "musikvideo", "music", "the", "feat", "ft", "featuring", "prod", "and", "und", "with", "vs", "version",
        "original", "topic", "full", "new", "der", "die", "das",
    ]

    static func tokens(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
        let words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(words.filter { word in
            word.count > 1 && !noise.contains(word) && !isYear(word)
        })
    }

    /// Gleich: dieselben Wörter. Ähnlich: eines enthält alle Wörter des anderen
    /// (z. B. „Africa“ vorhanden, gesucht „Africa Extended“).
    static func compare(_ query: Set<String>, _ candidate: Set<String>) -> DuplicateHit.Strength? {
        guard !query.isEmpty, !candidate.isEmpty else { return nil }
        if query == candidate { return .exact }
        guard query.count >= 2, candidate.count >= 2 else { return nil }
        if query.isSubset(of: candidate) || candidate.isSubset(of: query) { return .similar }
        return nil
    }

    private static func isYear(_ word: String) -> Bool {
        guard word.count == 4, let year = Int(word) else { return false }
        return (1900...2099).contains(year)
    }
}
