import Foundation

/// Was ein Videotitel über das Lied verrät: Interpret, Titel und Version (Extended, Radio Edit, Remix …).
///
/// „CamelPhat, ARTBAT - For A Feeling (Extended Mix) [Audio] ft. RHODES“
/// → Interpret „CamelPhat, ARTBAT“, Titel „For A Feeling“, Version „Extended Mix“, mit RHODES, Abzeichen EXTENDED.
struct TrackVersion: Hashable, Sendable {
    /// Kleine Schildchen auf den Karten.
    enum Badge: String, CaseIterable, Sendable {
        case extended
        case club
        case original
        case radioEdit
        case remix
        case live
        case spedUp
        case slowed
        case lyrics
        case visualizer

        var title: String {
            switch self {
            case .extended: return "EXTENDED"
            case .club: return "CLUB MIX"
            case .original: return "ORIGINAL MIX"
            case .radioEdit: return "RADIO EDIT"
            case .remix: return "REMIX"
            case .live: return "LIVE"
            case .spedUp: return "SPED UP"
            case .slowed: return "SLOWED"
            case .lyrics: return "LYRICS"
            case .visualizer: return "VISUALIZER"
            }
        }

        /// Gut für DJs (lange Versionen) – oder eher ein Warnhinweis.
        var isDJVersion: Bool { self == .extended || self == .club || self == .original }
        var isWarning: Bool { self == .live || self == .spedUp || self == .slowed }
    }

    var artist: String?
    var song: String
    /// „Extended Mix“, „Vintage Culture Remix“ – gehört in den Dateinamen.
    var mix: String?
    var featuring: String?
    var badges: Set<Badge>
    /// Ganze DJ-Sets, Radioshows, Podcasts – keine einzelnen Titel.
    var isFullSet: Bool
    /// Offizielle Tonspur eines „Künstler - Topic“-Kanals (YouTube Music).
    var isTopicChannel: Bool

    /// Lang genug für DJs – Extended/Club/Original Mix oder über 5 Minuten.
    func isLong(duration: TimeInterval?) -> Bool {
        if badges.contains(where: \.isDJVersion) { return true }
        return (duration ?? 0) >= 300
    }

    // MARK: Erkennen

    static func parse(_ rawTitle: String, channel: String? = nil, duration: TimeInterval? = nil) -> TrackVersion {
        // Dateinamen und Verlauf werden oft ausgewertet (tausende Titel auf einem Stick) – Ergebnisse merken.
        guard channel == nil, duration == nil else { return analyze(rawTitle, channel: channel, duration: duration) }
        if let cached = Cache.shared.value(for: rawTitle) { return cached }
        let version = analyze(rawTitle, channel: nil, duration: nil)
        Cache.shared.store(version, for: rawTitle)
        return version
    }

    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private var values: [String: TrackVersion] = [:]

        func value(for title: String) -> TrackVersion? { lock.locked { values[title] } }

        func store(_ version: TrackVersion, for title: String) {
            lock.locked {
                if values.count > 20_000 { values.removeAll() }
                values[title] = version
            }
        }
    }

    private static func analyze(_ rawTitle: String, channel: String?, duration: TimeInterval?) -> TrackVersion {
        var text = normalizeSeparators(rawTitle)
        var badges = Set<Badge>()
        var mixParts: [String] = []
        var songExtras: [String] = []
        var featuring: String?

        // Klammern: Version, Störwörter oder Teil des Titels („Marea (We've Lost Dancing)“).
        for group in bracketGroups(in: text).reversed() {
            text.removeSubrange(group.range)
            let inner = group.inner.trimmingCharacters(in: .whitespaces)
            guard !inner.isEmpty else { continue }
            if let feat = featuringName(in: inner) {
                featuring = featuring ?? feat
                continue
            }
            let found = classify(inner)
            badges.formUnion(found.badges)
            switch found.role {
            case .version: mixParts.insert(tidyVersion(inner), at: 0)
            case .noise: break
            case .title: songExtras.insert(group.original, at: 0)
            }
        }

        // „Titel | Label“ und andere Anhängsel
        text = splitOffLabel(text)

        // „ft. X“ außerhalb von Klammern
        if let range = text.range(of: #"\s+(?:ft\.?|feat\.?|featuring)\s+(.+)$"#, options: [.regularExpression, .caseInsensitive]) {
            let tail = String(text[range])
            if let name = featuringName(in: tail.trimmingCharacters(in: .whitespaces)) { featuring = featuring ?? name }
            text.removeSubrange(range)
        }

        var artist: String?
        var song = text
        if let separator = text.range(of: " - ") {
            artist = String(text[..<separator.lowerBound])
            song = String(text[separator.upperBound...])
            // Spotify-Stil: „Titel - Extended Mix“ / „Titel - 2004 Remaster“
            if let second = song.range(of: " - ", options: .backwards) {
                let tail = String(song[second.upperBound...])
                let found = classify(tail)
                if found.role != .title {
                    badges.formUnion(found.badges)
                    if found.role == .version { mixParts.append(tidyVersion(tail)) }
                    song = String(song[..<second.lowerBound])
                }
            }
        }

        // Version ohne Klammern am Ende: „Marea Extended Progressive Edit“
        if mixParts.isEmpty, let range = song.range(of: trailingVersionPattern, options: [.regularExpression, .caseInsensitive]) {
            let tail = song[range].trimmingCharacters(in: .whitespaces)
            let found = classify(tail)
            if found.role == .version, song.distance(from: song.startIndex, to: range.lowerBound) > 1 {
                badges.formUnion(found.badges)
                mixParts.append(tidyVersion(tail))
                song.removeSubrange(range)
            }
        }

        // Ein „Interpret - Topic“-Kanal: der Titel ist nur das Lied.
        let isTopic = channel?.hasSuffix(" - Topic") == true
        if artist == nil, isTopic, let channel {
            artist = String(channel.dropLast(" - Topic".count))
        }

        song = ([song.trimmingCharacters(in: .whitespaces)] + songExtras).joined(separator: " ")
        song = collapseSpaces(song)
        if let current = artist {
            artist = collapseSpaces(current).trimmingCharacters(in: CharacterSet(charactersIn: " -–|"))
            if artist?.isEmpty == true { artist = nil }
        }

        // Einzelne Wörter im Titel („Song Lyrics“, „live at …“)
        let lower = rawTitle.lowercased()
        if lower.range(of: #"\blyrics?\b"#, options: .regularExpression) != nil { badges.insert(.lyrics) }
        if lower.range(of: #"\bvisuali[sz]er\b"#, options: .regularExpression) != nil { badges.insert(.visualizer) }
        if lower.range(of: #"\blive (?:at|from|in|@|on)\b|\bfan footage\b"#, options: .regularExpression) != nil { badges.insert(.live) }
        if lower.range(of: #"\b(?:sped up|speed up|nightcore)\b"#, options: .regularExpression) != nil { badges.insert(.spedUp) }
        if lower.range(of: #"\bslowed\b"#, options: .regularExpression) != nil { badges.insert(.slowed) }
        if lower.range(of: #"\bextended\b"#, options: .regularExpression) != nil { badges.insert(.extended) }
        if lower.range(of: #"\bradio (?:edit|mix|version)\b"#, options: .regularExpression) != nil { badges.insert(.radioEdit) }
        if lower.range(of: #"\bclub (?:mix|edit)\b"#, options: .regularExpression) != nil { badges.insert(.club) }
        if lower.range(of: #"\boriginal mix\b"#, options: .regularExpression) != nil { badges.insert(.original) }

        let isFullSet = (duration ?? 0) > 13.5 * 60
            || lower.range(of: fullSetPattern, options: .regularExpression) != nil

        return TrackVersion(
            artist: artist,
            song: song.isEmpty ? collapseSpaces(rawTitle) : song,
            mix: mixParts.isEmpty ? nil : mixParts.joined(separator: " "),
            featuring: featuring.map(collapseSpaces),
            badges: badges,
            isFullSet: isFullSet,
            isTopicChannel: isTopic
        )
    }

    // MARK: Namen und Schlüssel

    /// „CamelPhat, ARTBAT feat. RHODES - For A Feeling (Extended Mix)“ – ohne „Official Video“ & Co.
    var fileName: String {
        var name = song
        if let mix { name += " (\(mix))" }
        if let artist {
            let fullArtist = featuring.map { "\(artist) feat. \($0)" } ?? artist
            name = "\(fullArtist) - \(name)"
        }
        return LibraryFiles.sanitizedName(name)
    }

    /// Hauptinterpret in Kleinbuchstaben – „CamelPhat, ARTBAT“ → „camelphat“. Für den Geschmack.
    var artistKey: String? {
        guard let artist else { return nil }
        return Self.primaryArtistKey(artist)
    }

    static func primaryArtistKey(_ artist: String) -> String? {
        let first = artist
            .replacingOccurrences(of: #"\s+(?:x|&|and|und|vs\.?|feat\.?|ft\.?|with|meets)\s+|[,&+/]"#, with: "|",
                                  options: [.regularExpression, .caseInsensitive])
            .components(separatedBy: "|").first ?? artist
        let key = first
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
            .filter { $0.isLetter || $0.isNumber }
        return key.isEmpty ? nil : key
    }

    /// Gleiches Lied in derselben Version – egal, welcher Kanal es hochgeladen hat.
    var songKey: String {
        let words = TitleMatcher.tokens([artist ?? "", song, mix ?? ""].joined(separator: " "))
        return words.sorted().joined(separator: " ")
    }

    /// Suchbegriff für YouTube: „Interpret - Titel“ (ohne Version).
    var searchText: String {
        artist.map { "\($0) - \(song)" } ?? song
    }

    // MARK: Intern

    private enum Role {
        case version
        case noise
        case title
    }

    private static let trailingVersionPattern =
        #"\s+(?:extended(?:\s+\p{L}+)?(?:\s+(?:mix|version|edit|remix))?|radio\s+(?:edit|mix|version)|club\s+(?:mix|edit)|original\s+mix)\s*$"#

    private static let fullSetPattern =
        #"\b(?:dj set|live set|full set|boiler room|radio show|podcast|essential mix|guest mix|takeover|hour mix|mixtape|b2b|continuous mix|year mix|mixed by)\b"#

    private static func classify(_ inner: String) -> (role: Role, badges: Set<Badge>) {
        let lower = inner.lowercased()
        var badges = Set<Badge>()
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }

        if has(#"\bextended\b"#) { badges.insert(.extended) }
        if has(#"\bclub (?:mix|edit|version)\b"#) { badges.insert(.club) }
        if has(#"\boriginal mix\b"#) { badges.insert(.original) }
        if has(#"\bradio (?:edit|mix|version|cut)\b"#) { badges.insert(.radioEdit) }
        if has(#"\b(?:remix|rmx|rework|bootleg|re-?edit|vip|dub|flip|remode|refix)\b"#)
            || (has(#"\bedit\b"#) && !badges.contains(.radioEdit) && !badges.contains(.club) && !badges.contains(.extended)) {
            badges.insert(.remix)
        }
        if has(#"\b(?:sped up|speed up|nightcore)\b"#) { badges.insert(.spedUp) }
        if has(#"\bslowed\b"#) { badges.insert(.slowed) }
        if has(#"\blive\b|\bfan footage\b|\bunplugged\b"#) || looksLikeDateOrVenue(lower) { badges.insert(.live) }

        let isVersion = !badges.isEmpty
            || has(#"\b(?:mix|version|instrumental|acapella|a cappella|acoustic|dub)\b"#)
        if isVersion {
            // „Official Video“ hinter der Version („Extended Mix [Official Video]“) bleibt Störwort.
            return (.version, badges)
        }
        if has(#"\blyrics?\b|\bsongtext\b"#) { return (.noise, [.lyrics]) }
        if has(#"\bvisuali[sz]er\b"#) { return (.noise, [.visualizer]) }
        if has(noisePattern) { return (.noise, []) }
        return (.title, [])
    }

    private static let noisePattern =
        #"^(?:(?:the\s+)?official(?:\s+(?:music|lyric|hd|4k))?(?:\s+(?:video|audio|clip|videoclip|visual))?|official|audio|video|music video|hd|hq|4k|8k|uhd|1080p|720p|explicit|clean|out now|free download|premiere|full song|full track|video oficial|clip officiel|offizielles musikvideo|musikvideo|official video hd|lyric video|visual|teaser|preview|\d{4}\s*remaster(?:ed)?|remaster(?:ed)?(?:\s+\d{4})?|[\p{L}\p{N}' .]+ records?|[\p{L}\p{N}' .]+ music|from .+|as heard on .+|tiktok.*|.*\bvevo\b.*|\#(genres))$"#

    private static let genres =
        "(?:tech |deep |afro |bass |organic |progressive |future |melodic |soulful |funky |jackin'? |acid |minimal |hard |big room |electro |tropical |nu |uk )?(?:house|techno|trance|disco|garage|dubstep|hardstyle|edm|dance|electronic|minimal|indie dance|drum (?:&|and|n) bass|dnb|breaks|breakbeat|downtempo|electronica)"

    /// „Dublin, 30th October 2025“, „Live @ Tomorrowland 2024“
    private static func looksLikeDateOrVenue(_ lower: String) -> Bool {
        let months = "january|february|march|april|may|june|july|august|september|october|november|december|januar|februar|märz|mai|juni|juli|oktober|dezember"
        if lower.range(of: #"\b\d{1,2}(?:st|nd|rd|th|\.)?\s+(?:\#(months))\b"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"\b(?:\#(months))\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4}\b"#, options: .regularExpression) != nil { return true }
        return lower.range(of: #"\b\d{1,2}[./]\d{1,2}[./]\d{2,4}\b"#, options: .regularExpression) != nil
    }

    private static func featuringName(in text: String) -> String? {
        guard let range = text.range(of: #"^(?:ft\.?|feat\.?|featuring)\s+"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let name = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// „extended mix“ → „Extended Mix“; Eigennamen bleiben, wie sie sind.
    private static func tidyVersion(_ text: String) -> String {
        let trimmed = collapseSpaces(text.trimmingCharacters(in: CharacterSet(charactersIn: " -–")))
        guard trimmed == trimmed.lowercased() else { return trimmed }
        return trimmed.capitalized(with: Locale(identifier: "en_US"))
    }

    private struct BracketGroup {
        let range: Range<String.Index>
        let inner: String
        let original: String
    }

    private static func bracketGroups(in text: String) -> [BracketGroup] {
        guard let regex = try? NSRegularExpression(pattern: #"[\(\[【]([^\(\)\[\]【】]*)[\)\]】]"#) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text), let innerRange = Range(match.range(at: 1), in: text) else { return nil }
            return BracketGroup(range: range, inner: String(text[innerRange]), original: String(text[range]))
        }
    }

    /// Gedankenstriche vereinheitlichen; „Künstler ●● Titel“ und „KÜNSTLER | TITEL“ wie „ - “ behandeln.
    private static func normalizeSeparators(_ title: String) -> String {
        var text = title
        for dash in [" – ", " — ", " ‒ ", " ― ", " -- ", " ~ ", " ●● ", " ● ", " // "] {
            text = text.replacingOccurrences(of: dash, with: " - ")
        }
        return collapseSpaces(text)
    }

    /// „Weska - No Escape | Truesoul“ → „Weska - No Escape“; „BICEP | GLUE“ → „BICEP - GLUE“.
    private static func splitOffLabel(_ text: String) -> String {
        let parts = text.components(separatedBy: " | ")
        guard parts.count > 1 else { return text }
        if parts[0].contains(" - ") { return parts[0] }
        return parts[0] + " - " + parts[1]
    }

    private static func collapseSpaces(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Welche Version Velvet bevorzugt, wenn es ein Lied sucht oder vorschlägt.
enum PreferredVersion: String, CaseIterable, Identifiable, Sendable {
    case any
    case extended
    case short

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "Egal"
        case .extended: return "Extended"
        case .short: return "Radio Edit"
        }
    }

    var explanation: String {
        switch self {
        case .any: return "Velvet nimmt die Reihenfolge von YouTube."
        case .extended: return "Lange Versionen (Extended, Club, Original Mix) kommen nach vorn – ideal zum Mixen."
        case .short: return "Kurze Versionen (Radio Edit) kommen nach vorn."
        }
    }

    /// Suchbegriff ergänzen – nur, wenn er noch keine Version nennt.
    func searchQuery(for query: String) -> String {
        guard self == .extended else { return query }
        let lower = query.lowercased()
        let mentionsVersion = ["extended", "radio", "edit", "mix", "remix", "live", "version", "acoustic", "instrumental"]
            .contains { lower.contains($0) }
        return mentionsVersion ? query : "\(query) extended mix"
    }

    /// Punkte für die Reihenfolge – höher ist besser.
    func score(_ version: TrackVersion, duration: TimeInterval?) -> Double {
        var score = 0.0
        let badges = version.badges
        switch self {
        case .any:
            break
        case .extended:
            if badges.contains(.extended) { score += 2 }
            if badges.contains(.club) || badges.contains(.original) { score += 1.5 }
            if badges.contains(.radioEdit) { score -= 1.5 }
            if let duration, duration >= 300 { score += 0.5 }
        case .short:
            if badges.contains(.radioEdit) { score += 2 }
            if badges.contains(.extended) || badges.contains(.club) { score -= 1.5 }
        }
        if badges.contains(.spedUp) || badges.contains(.slowed) { score -= 2 }
        if badges.contains(.live) { score -= 1 }
        if badges.contains(.lyrics) { score -= 0.3 }
        if version.isFullSet { score -= 3 }
        return score
    }
}
