import Foundation

/// Ein Titel, der gerade hinzugefügt wird – vom Suchbegriff bzw. Link bis zur fertigen Datei.
@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    enum Origin {
        /// Aus einem Titel – Velvet sucht und der Nutzer wählt.
        case search
        /// Aus einem Link – wird direkt geladen.
        case link
    }

    let id = UUID()
    let origin: Origin
    /// Der ursprüngliche Text (Suchbegriff oder Link).
    let originalText: String
    /// Ordner, in den der Titel geladen wird.
    let destination: URL
    let options: DownloadOptions

    @Published var status: ItemStatus
    @Published var query: String
    @Published var sourceURL: URL?
    @Published var label: String?
    @Published var title: String?
    @Published var videoID: String?
    @Published var chosen: VideoCandidate?

    @Published var candidates: [VideoCandidate] = []
    @Published var page = 0
    @Published var hasSearched = false
    /// Bereits gezeigte Vorschläge – Nachladen bringt nur neue.
    var seenCandidateIDs: Set<String> = []
    /// Beim seitlichen Wischen werden weitere Vorschläge angehängt.
    @Published var isLoadingMore = false
    @Published var hasMoreCandidates = true
    var moreToken: UUID?

    @Published var progress: Double = 0
    @Published var detail: String?
    @Published var phaseText: String?
    @Published var outputFile: URL?
    @Published var log: [String] = []

    /// Erstes Ergebnis automatisch wählen – nur bei der allerersten Suche.
    var allowAutoPick = true
    /// Archiv für diesen einen Download ignorieren („Trotzdem laden“).
    var ignoreArchive = false
    /// Wird nach erfolgreichem Ersatz-Download gelöscht.
    var replacedFile: URL?
    var replacedVideoID: String?

    var searchTask: Task<Void, Never>?
    var downloadTask: Task<Void, Never>?
    /// Ergebnisse veralteter Such- oder Download-Läufe werden anhand dieser Marken verworfen.
    var searchToken: UUID?
    var downloadToken: UUID?

    init(entry: ParsedEntry, destination: URL, options: DownloadOptions) {
        self.destination = destination
        self.options = options
        switch entry.kind {
        case let .url(url):
            origin = .link
            originalText = entry.label ?? url.absoluteString
            query = entry.label ?? ""
            label = entry.label
            sourceURL = url
            videoID = YouTubeLink.videoID(in: url)
            status = .waiting
        case let .search(text):
            origin = .search
            originalText = text
            query = text
            status = .searching
        }
    }

    /// Ein schon gewähltes Video – aus der Suche oder einer aufgelösten Playlist.
    init(candidate: VideoCandidate, query: String?, destination: URL, options: DownloadOptions) {
        self.destination = destination
        self.options = options
        origin = query == nil ? .link : .search
        originalText = query ?? candidate.title
        self.query = query ?? candidate.title
        title = candidate.title
        sourceURL = candidate.url
        videoID = candidate.id
        chosen = candidate
        hasSearched = query != nil
        status = .waiting
    }

    var displayTitle: String {
        if let title = chosen?.title ?? title { return title }
        if let label { return label }
        switch origin {
        case .search: return query
        case .link: return sourceURL.map(Self.shortLink) ?? originalText
        }
    }

    var thumbnailURL: URL? {
        chosen?.thumbnailURL ?? videoID.map(YouTubeLink.thumbnailURL)
    }

    /// „Weitere Vorschläge“ geht nur, wenn ein Suchbegriff oder Titel bekannt ist.
    var canSuggest: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || title != nil
    }

    nonisolated static func shortLink(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://", "www."] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text
    }
}
