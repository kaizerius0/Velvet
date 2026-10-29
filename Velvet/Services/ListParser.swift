import Foundation

/// Ein erkannter Eintrag aus der eingefügten Liste – entweder ein Link oder ein Suchbegriff.
struct ParsedEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case url(URL)
        case search(String)
    }

    let id: Int
    let kind: Kind
    /// Begleittext zu einem Link, z. B. „Queen – Bohemian Rhapsody“ in „Queen – Bohemian Rhapsody: https://…“.
    let label: String?

    var isLink: Bool {
        if case .url = kind { return true }
        return false
    }

    var url: URL? {
        if case let .url(url) = kind { return url }
        return nil
    }

    var isPlaylist: Bool { url.map(YouTubeLink.isPlaylist) ?? false }

    var displayText: String {
        switch kind {
        case let .search(query): return query
        case let .url(url): return label ?? DownloadItem.shortLink(url)
        }
    }
}

struct ListParseResult: Equatable, Sendable {
    var entries: [ParsedEntry] = []
    var duplicateCount = 0
    var ignoredLineCount = 0

    static let empty = ListParseResult()

    var linkCount: Int { entries.filter(\.isLink).count }
    var searchCount: Int { entries.count - linkCount }
}

/// Macht aus beliebig formatiertem Text eine saubere Liste: eine Zeile = ein Video/Lied.
///
/// Erkennt u. a. Nummerierungen („1.“, „2)“, „#3“, „01 -“), Aufzählungszeichen, Checkboxen, Markdown,
/// Zeitstempel aus Tracklisten, Dauerangaben, Anführungszeichen, Emojis, Überschriften, Fließtext,
/// Tabellen (Tabs, CSV mit `;` oder `,`, Markdown-Tabellen, Spotify-/Apple-Music-Exporte), M3U-Playlists
/// und Listen in einer einzigen Zeile („1. A 2. B“, „A; B; C“).
enum ListParser {
    enum RawEntry: Equatable {
        case link(URL, label: String?)
        case title(String)
    }

    static func parse(_ text: String) -> ListParseResult {
        let lines = normalizedLines(text)
        guard !lines.isEmpty else { return .empty }

        let raw: [RawEntry]
        let ignored: Int
        if let table = TableReader.read(lines) {
            (raw, ignored) = (table.entries, table.ignored)
        } else {
            (raw, ignored) = readPlainLines(lines)
        }
        return finalize(raw, ignored: ignored)
    }

    /// Erkennt einen einzelnen Link, z. B. aus dem „Eigenen Link eingeben“-Feld.
    static func link(from text: String) -> URL? {
        extractLinks(text).urls.first
    }

    // MARK: - Normalisieren

    static func normalizedLines(_ text: String) -> [String] {
        var text = decodeHTMLEntities(text)
        for (search, replacement) in [
            ("\r\n", "\n"), ("\r", "\n"), ("\u{2028}", "\n"), ("\u{2029}", "\n"), ("\u{0085}", "\n"),
            ("\u{00A0}", " "), ("\u{2009}", " "), ("\u{202F}", " "),
            ("\u{200B}", ""), ("\u{FEFF}", ""),
        ] {
            text = text.replacingOccurrences(of: search, with: replacement)
        }
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in [
            ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&#x27;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&ndash;", "–"), ("&mdash;", "—"),
        ] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return Patterns.numericEntity.replace(in: result) { match in
            guard let code = UInt32(match, radix: 10), let scalar = Unicode.Scalar(code) else { return nil }
            return String(Character(scalar))
        }
    }

    // MARK: - Freitext-Listen

    private static func readPlainLines(_ input: [String]) -> ([RawEntry], Int) {
        var lines = input
        if lines.count == 1 { lines = splitSingleLine(lines[0]) }
        lines = lines.flatMap(splitSemicolons)

        let style = ListStyle.detect(in: lines)
        var entries: [RawEntry] = []
        var ignored = 0
        var skipNextFilePath = false

        for line in lines {
            // M3U: "#EXTINF:215,Queen - Bohemian Rhapsody" gefolgt vom Dateipfad
            if let title = Patterns.extinf.firstCapture(in: line) {
                if let cleaned = cleanTitle(title, style: .plain) {
                    entries.append(.title(cleaned))
                    skipNextFilePath = true
                } else {
                    ignored += 1
                }
                continue
            }
            if Patterns.filePath.matches(line) {
                if skipNextFilePath {
                    skipNextFilePath = false
                } else if let name = fileTitle(line), let cleaned = cleanTitle(name, style: .plain) {
                    entries.append(.title(cleaned))
                } else {
                    ignored += 1
                }
                continue
            }
            skipNextFilePath = false

            if Patterns.comment.matches(line) {
                ignored += 1
                continue
            }

            let links = extractLinks(line)
            if !links.urls.isEmpty {
                let label = links.urls.count == 1 ? cleanLabel(links.remainder, style: style) : nil
                entries += links.urls.map { .link($0, label: label) }
                continue
            }

            if let title = cleanTitle(line, style: style) {
                entries.append(.title(title))
            } else {
                ignored += 1
            }
        }
        return (entries, ignored)
    }

    /// Eine einzige Zeile kann eine ganze Liste sein: „1. A 2. B 3. C“, „A; B; C“ oder „A, B, C“.
    static func splitSingleLine(_ line: String) -> [String] {
        if let numbered = splitInlineNumbering(line) { return numbered }
        if line.contains(";") { return [line] } // wird von splitSemicolons erledigt

        let links = extractLinks(line).urls
        if links.count >= 2 { return [line] } // mehrere Links werden einzeln erkannt

        let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count >= 3 { return parts }
        if parts.count == 2, parts.allSatisfy({ Patterns.artistTitleSeparator.matches($0) }) { return parts }
        return [line]
    }

    private static func splitInlineNumbering(_ line: String) -> [String]? {
        let matches = Patterns.inlineNumber.allMatches(in: line)
        guard matches.count >= 2 else { return nil }
        let numbers = matches.compactMap { Int($0.capture) }
        guard numbers.count == matches.count,
              matches[0].range.lowerBound == line.startIndex || line[..<matches[0].range.lowerBound].allSatisfy(\.isWhitespace) else {
            return nil
        }
        for (previous, next) in zip(numbers, numbers.dropFirst()) where next != previous + 1 {
            return nil
        }
        var parts: [String] = []
        for (index, match) in matches.enumerated() {
            let end = index + 1 < matches.count ? matches[index + 1].range.lowerBound : line.endIndex
            let part = line[match.range.lowerBound..<end].trimmingCharacters(in: .whitespaces)
            if !part.isEmpty { parts.append(part) }
        }
        return parts
    }

    private static func splitSemicolons(_ line: String) -> [String] {
        guard line.contains(";") else { return [line] }
        let parts = line.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count >= 2, parts.allSatisfy({ alphanumericCount($0) >= 2 }) else { return [line] }
        return parts
    }

    // MARK: - Links

    struct ExtractedLinks {
        var urls: [URL]
        var remainder: String
    }

    static func extractLinks(_ line: String) -> ExtractedLinks {
        var urls: [URL] = []
        var remainder = line
        for match in Patterns.link.allMatches(in: line).reversed() {
            if let url = normalizeLink(String(line[match.range])) {
                urls.insert(url, at: 0)
                remainder.replaceSubrange(match.range, with: " ")
            }
        }
        return ExtractedLinks(urls: urls, remainder: remainder)
    }

    static func normalizeLink(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Satzzeichen am Ende gehören nicht zum Link – Klammern nur, wenn sie nicht geöffnet wurden.
        while let last = text.last {
            if ".,;:!?'\"»“”’>".contains(last) {
                text.removeLast()
            } else if last == ")" && text.filter({ $0 == "(" }).count < text.filter({ $0 == ")" }).count {
                text.removeLast()
            } else {
                break
            }
        }
        let lower = text.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            text = "https://" + text
        }
        guard let url = URL(string: text)
                ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)),
              let host = url.host, host.contains(".") else {
            return nil
        }
        return YouTubeLink.normalized(url)
    }

    private static func cleanLabel(_ text: String, style: ListStyle) -> String? {
        let stripped = text
            .replacingOccurrences(of: "[]", with: " ")
            .replacingOccurrences(of: "()", with: " ")
            .replacingOccurrences(of: "<>", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " :|-–—•·[]()<>\"'"))
        return cleanTitle(stripped, style: style)
    }

    // MARK: - Titel säubern

    /// Wie konsequent eine Liste nummeriert ist – nur dann werden mehrdeutige Muster entfernt.
    struct ListStyle: Equatable {
        var stripNumberDash = false
        var stripBareNumber = false
        var stripLeadingTimestamps = false
        var stripTrailingDurations = false

        static let plain = ListStyle()

        static func detect(in lines: [String]) -> ListStyle {
            guard lines.count >= 2 else { return .plain }
            let total = Double(lines.count)
            func share(_ pattern: Pattern) -> Double {
                Double(lines.filter(pattern.matches).count) / total
            }

            var style = ListStyle()
            style.stripNumberDash = share(Patterns.numberDash) >= 0.5
            style.stripLeadingTimestamps = share(Patterns.leadingTimestamp) >= 0.5
            style.stripTrailingDurations = share(Patterns.trailingDuration) >= 0.5

            // „1 Song“, „2 Song“ … nur bei fortlaufenden Nummern – „99 Luftballons“ bleibt erhalten.
            let numbers = lines.compactMap { Patterns.bareNumber.firstCapture(in: $0).flatMap { Int($0) } }
            if numbers.count >= 2, Double(numbers.count) / total >= 0.6 {
                let ascending = zip(numbers, numbers.dropFirst()).filter { $1 == $0 + 1 }.count
                style.stripBareNumber = Double(ascending) >= Double(numbers.count - 1) * 0.7
            }
            return style
        }
    }

    static func cleanTitle(_ line: String, style: ListStyle) -> String? {
        var text = stripMarkdown(line)
        text = stripDecorations(text)

        if style.stripLeadingTimestamps { text = Patterns.leadingTimestamp.strip(text) }

        // Genau eine Nummerierung entfernen – sonst würde aus „1. 99 Luftballons“ „Luftballons“.
        let numberingPatterns = [Patterns.enumerator, Patterns.hashNumber, Patterns.germanNumber]
            + (style.stripNumberDash ? [Patterns.numberDash] : [])
            + (style.stripBareNumber ? [Patterns.bareNumber] : [])
        for pattern in numberingPatterns {
            let stripped = pattern.strip(text)
            if stripped != text {
                text = stripped
                break
            }
        }

        text = stripDecorations(text)
        text = Patterns.titlePrefix.strip(text)

        if style.stripTrailingDurations {
            text = Patterns.trailingDuration.strip(text)
        } else {
            text = Patterns.bracketedDuration.strip(text)
        }
        text = stripTrailingSymbols(text)
        text = Patterns.trailingPunctuation.strip(text)
        text = unwrapQuotes(text)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        guard alphanumericCount(text) >= 2 else { return nil }
        guard !looksLikeHeading(text), !looksLikeProse(text) else { return nil }
        return text
    }

    /// Aufzählungszeichen, Checkboxen und Symbole am Anfang – so oft wie nötig („- [ ] 🎵 Song“).
    private static func stripDecorations(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespaces)
        var previous = ""
        while text != previous {
            previous = text
            text = stripLeadingSymbols(text)
            text = Patterns.checkbox.strip(text)
            text = Patterns.bullet.strip(text)
            text = text.trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private static func stripMarkdown(_ text: String) -> String {
        var result = text
        result = Patterns.markdownLink.replace(in: result) { $0 }
        for pattern in [Patterns.boldStars, Patterns.boldUnderscores, Patterns.italicStars, Patterns.inlineCode, Patterns.strikethrough] {
            result = pattern.replace(in: result) { $0 }
        }
        return result
    }

    private static func isDecorativeSymbol(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isEmojiPresentation { return true }
        switch scalar.properties.generalCategory {
        case .otherSymbol, .mathSymbol, .modifierSymbol:
            return true
        default:
            return false
        }
    }

    private static func stripLeadingSymbols(_ text: String) -> String {
        var result = Substring(text)
        while let first = result.first, isDecorativeSymbol(first) || first == "\u{FE0F}" {
            result = result.dropFirst()
        }
        return String(result).trimmingCharacters(in: .whitespaces)
    }

    private static func stripTrailingSymbols(_ text: String) -> String {
        var result = Substring(text)
        while let last = result.last, isDecorativeSymbol(last) || last == "\u{FE0F}" || last.isWhitespace {
            result = result.dropLast()
        }
        return String(result)
    }

    private static let quotePairs: [(Character, Character)] = [
        ("\"", "\""), ("'", "'"), ("„", "“"), ("“", "”"), ("”", "”"), ("‚", "‘"), ("‘", "’"),
        ("«", "»"), ("»", "«"), ("`", "`"),
    ]

    private static func unwrapQuotes(_ text: String) -> String {
        var result = text
        var changed = true
        while changed, result.count >= 2 {
            changed = false
            for (open, close) in quotePairs where result.first == open && result.last == close {
                result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return result
    }

    static func alphanumericCount(_ text: String) -> Int {
        text.filter { $0.isLetter || $0.isNumber }.count
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// „Meine Playlist:“, „Rock:“ oder „Tracklist“ sind Überschriften, keine Lieder.
    private static func looksLikeHeading(_ text: String) -> Bool {
        text.hasSuffix(":") || Patterns.headingWord.matches(text)
    }

    /// Ganze Sätze („Das sind meine Lieblingssongs für die Party am Samstag.“) sind Zusatztext.
    private static func looksLikeProse(_ text: String) -> Bool {
        let words = wordCount(text)
        if words >= 18 { return true }
        guard words >= 7, let last = text.last, ".!?".contains(last) else { return false }
        return !Patterns.artistTitleSeparator.matches(text)
    }

    private static func fileTitle(_ path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let name = normalized.split(separator: "/").last.map(String.init) ?? normalized
        let decoded = name.removingPercentEncoding ?? name
        let base = (decoded as NSString).deletingPathExtension
        let cleaned = base.replacingOccurrences(of: "_", with: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Abschluss

    private static func finalize(_ raw: [RawEntry], ignored: Int) -> ListParseResult {
        var seen = Set<String>()
        var result = ListParseResult()
        result.ignoredLineCount = ignored

        for entry in raw {
            let key: String
            let kind: ParsedEntry.Kind
            let label: String?
            switch entry {
            case let .link(url, entryLabel):
                key = YouTubeLink.dedupeKey(url)
                kind = .url(url)
                label = entryLabel
            case let .title(title):
                key = searchKey(title)
                kind = .search(title)
                label = nil
            }
            guard !key.isEmpty else { continue }
            guard seen.insert(key).inserted else {
                result.duplicateCount += 1
                continue
            }
            result.entries.append(ParsedEntry(id: result.entries.count, kind: kind, label: label))
        }
        return result
    }

    /// „Beyoncé – Halo“ und „beyonce halo“ gelten als dasselbe Lied.
    static func searchKey(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
            .filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Tabellen

/// Erkennt tabellarische Listen (Excel/Numbers, CSV, Markdown, Spotify- und Apple-Music-Exporte).
enum TableReader {
    struct Result {
        var entries: [ListParser.RawEntry]
        var ignored: Int
    }

    static func read(_ lines: [String]) -> Result? {
        guard lines.count >= 2 else { return nil }
        if let markdown = readMarkdownTable(lines) { return markdown }
        for delimiter: Character in ["\t", ";", ","] {
            if let table = readDelimited(lines, delimiter: delimiter) { return table }
        }
        return nil
    }

    private static func readMarkdownTable(_ lines: [String]) -> Result? {
        let rows = lines.filter { $0.hasPrefix("|") }
        guard rows.count >= 2, Double(rows.count) / Double(lines.count) >= 0.6 else { return nil }
        let cells = rows
            .map { row -> [String] in
                var inner = Substring(row)
                if inner.hasPrefix("|") { inner = inner.dropFirst() }
                if inner.hasSuffix("|") { inner = inner.dropLast() }
                return inner.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            .filter { row in !row.allSatisfy { Patterns.markdownRule.matches($0) || $0.isEmpty } }
        guard !cells.isEmpty else { return nil }
        var result = build(cells)
        result.ignored += lines.count - rows.count
        return result
    }

    private static func readDelimited(_ lines: [String], delimiter: Character) -> Result? {
        let rows = lines.map { split($0, by: delimiter) }
        let counts = rows.map(\.count).filter { $0 >= 2 }
        guard let mode = mostCommon(counts), mode >= 2 else { return nil }

        let consistent = rows.filter { $0.count == mode }.count
        let ratio = Double(consistent) / Double(lines.count)
        let hasHeader = HeaderMap(rows[0]) != nil
        let required: Double = delimiter == "," ? (hasHeader ? 0.7 : 0.9) : 0.8
        guard ratio >= required else { return nil }
        return build(rows)
    }

    private static func build(_ rows: [[String]]) -> Result {
        let header = rows.first.flatMap(HeaderMap.init)
        let dataRows = header == nil ? rows : Array(rows.dropFirst())
        var entries: [ListParser.RawEntry] = []
        var ignored = 0

        for row in dataRows {
            let cells = row.map(cleanCell)
            guard cells.contains(where: { !$0.isEmpty }) else { continue }

            var parts: [String] = []
            if let header {
                if let artist = header.artist, artist < cells.count, !cells[artist].isEmpty { parts.append(cells[artist]) }
                if let title = header.title, title < cells.count, !cells[title].isEmpty { parts.append(cells[title]) }
            }
            if parts.isEmpty {
                parts = Array(cells.filter(isTextual).prefix(2))
            }
            let label = parts.isEmpty ? nil : ListParser.cleanTitle(parts.joined(separator: " - "), style: .plain)

            if let url = cells.lazy.compactMap({ ListParser.link(from: $0) }).first {
                entries.append(.link(url, label: label))
            } else if let label {
                entries.append(.title(label))
            } else {
                ignored += 1
            }
        }
        return Result(entries: entries, ignored: ignored)
    }

    private static func cleanCell(_ cell: String) -> String {
        var text = cell.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, text.first == "\"", text.last == "\"" {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Zellen, die wie ein Titel oder Interpret aussehen – keine Nummern, Zeiten, Daten oder Links.
    private static func isTextual(_ cell: String) -> Bool {
        guard !cell.isEmpty, cell.contains(where: \.isLetter) else { return false }
        if ListParser.link(from: cell) != nil { return false }
        if cell.lowercased().hasPrefix("spotify:") { return false }
        return true
    }

    /// CSV-Zeile mit Anführungszeichen-Unterstützung („"Artist, feat. X";"Titel"“).
    static func split(_ line: String, by delimiter: Character) -> [String] {
        if delimiter == "\t" {
            return line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if inQuotes, index + 1 < characters.count, characters[index + 1] == "\"" {
                    current.append("\"")
                    index += 1
                } else {
                    inQuotes.toggle()
                }
            } else if character == delimiter, !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        fields.append(current)
        return fields
    }

    private static func mostCommon(_ values: [Int]) -> Int? {
        var counts: [Int: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    /// Spaltenköpfe wie „Titel“, „Track Name“, „Interpret“, „Artist Name(s)“ oder „Link“.
    struct HeaderMap {
        var title: Int?
        var artist: Int?
        var link: Int?

        private static let titleKeys: Set<String> = [
            "title", "titel", "song", "songs", "songtitel", "song title", "songname", "song name", "track", "tracks",
            "track name", "trackname", "track title", "name", "lied", "lieder", "video", "videotitel", "video title",
        ]
        private static let artistKeys: Set<String> = [
            "artist", "artists", "artist name", "artist names", "interpret", "interpreten", "künstler", "künstlerin",
            "band", "sänger", "sängerin", "performer", "album artist", "musiker",
        ]
        private static let linkKeys: Set<String> = [
            "url", "link", "links", "youtube", "youtube link", "youtube-link", "video url", "video link", "youtube url",
        ]

        init?(_ cells: [String]) {
            guard !cells.contains(where: { ListParser.link(from: $0) != nil }) else { return nil }
            for (index, cell) in cells.enumerated() {
                let key = Self.normalize(cell)
                if title == nil, Self.titleKeys.contains(key) {
                    title = index
                } else if artist == nil, Self.artistKeys.contains(key) {
                    artist = index
                } else if link == nil, Self.linkKeys.contains(key) {
                    link = index
                }
            }
            guard title != nil || artist != nil || link != nil else { return nil }
        }

        private static func normalize(_ cell: String) -> String {
            var key = cell.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " \"'#"))
            for suffix in ["(s)", "(en)", "*in", ":in", "_in", "/in"] {
                key = key.replacingOccurrences(of: suffix, with: "")
            }
            return key.trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - Muster

/// Kleiner Komfort-Wrapper um NSRegularExpression.
struct Pattern: @unchecked Sendable {
    struct Match {
        let range: Range<String.Index>
        let capture: String
    }

    let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = true) {
        regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func firstCapture(in text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    func allMatches(in text: String) -> [Match] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let capture = match.numberOfRanges > 1 ? Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? "" : ""
            return Match(range: range, capture: capture)
        }
    }

    /// Entfernt den (ersten) Treffer und trimmt Leerzeichen.
    func strip(_ text: String) -> String {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return text }
        var result = text
        result.removeSubrange(range)
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Ersetzt jeden Treffer durch das Ergebnis von `transform(capture1)`; `nil` behält den Treffer.
    func replace(in text: String, _ transform: (String) -> String?) -> String {
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result),
                  let captureRange = Range(match.range(at: 1), in: text),
                  let replacement = transform(String(text[captureRange])) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

enum Patterns {
    static let numericEntity = Pattern(#"&#(\d{1,7});"#)

    static let link = Pattern(#"(?:https?://|www\.|(?:m\.|music\.)?youtube\.com/|youtu\.be/)[^\s<>"'“”‘’\[\]{}|\\^]+"#)

    static let markdownLink = Pattern(#"\[([^\]]*)\]\((?:[^)\s]+)\)"#)
    static let boldStars = Pattern(#"\*\*(.+?)\*\*"#)
    static let boldUnderscores = Pattern(#"__(.+?)__"#)
    static let italicStars = Pattern(#"(?<![\w*])\*(?!\s)([^*]+?)(?<!\s)\*(?![\w*])"#)
    static let inlineCode = Pattern(#"`([^`]+)`"#)
    static let strikethrough = Pattern(#"~~(.+?)~~"#)
    static let markdownRule = Pattern(#"^:?-{2,}:?$"#)

    static let checkbox = Pattern(#"^(?:[-*+]\s*)?\[(?:\s|x|✓|✔)?\]\s*"#)
    static let bullet = Pattern(#"^(?:[-–—•●○◦▪▫■□‣⁃∙·*+~>→➔➜➤►▸▶]\s*)+"#)
    /// „1.“, „1)“, „(1)“, „[1]“, „1:“, „Nr. 3.“ – aber nicht „3:45“ oder „1.5“.
    static let enumerator = Pattern(#"^[(\[]?\s*(?:(?:nr|no|nummer)\.?\s*)?\d{1,4}\s*[.):\]](?!\d)\s*"#)
    static let hashNumber = Pattern(#"^#\d{1,4}\b\s*[-–—:.)]?\s*"#)
    /// „Nr. 7 Song“ – „No.“ bleibt, wegen Titeln wie „No. 1 Party Anthem“.
    static let germanNumber = Pattern(#"^(?:nr|nummer)\.?\s*\d{1,4}\b\s*[-–—:.)]?\s*"#)
    static let numberDash = Pattern(#"^\d{1,3}\s*[-–—]\s+(?=\S)"#)
    static let bareNumber = Pattern(#"^(\d{1,3})\s+(?=\S)"#)
    static let inlineNumber = Pattern(#"(?:^|\s)(\d{1,3})[.)]\s+"#)

    static let leadingTimestamp = Pattern(#"^[(\[]?\d{1,2}:\d{2}(?::\d{2})?[)\]]?\s*(?:[-–—|:]\s*)?(?=\S)"#)
    static let trailingDuration = Pattern(#"\s*(?:[-–—|•·]\s*)?[(\[]?\d{1,2}:\d{2}(?::\d{2})?[)\]]?\s*$"#)
    static let bracketedDuration = Pattern(#"\s*[(\[]\d{1,2}:\d{2}(?::\d{2})?[)\]]\s*$"#)

    static let titlePrefix = Pattern(#"^(?:titel|title|song|lied|track|video)\s*[:：]\s*"#)
    static let trailingPunctuation = Pattern(#"(?:\s*[,;|•·]+|\s+[-–—]+)+\s*$"#)
    static let artistTitleSeparator = Pattern(#"\S\s+[-–—]\s+\S"#)
    static let headingWord = Pattern(#"^(?:tracklist|trackliste|playlist|setlist|songliste|liste|songs|lieder|videos)$"#)

    static let comment = Pattern(#"^(?:#+\s|#(?!\d)|//)"#)
    static let extinf = Pattern(#"^#EXTINF:[^,]*,(.+)$"#)
    static let filePath = Pattern(#"^(?:file://|/|~/|[A-Z]:\\).*\.(?:mp3|m4a|aac|flac|wav|ogg|opus|mp4|m4v|mkv|webm|alac|aiff?)$"#)
}
