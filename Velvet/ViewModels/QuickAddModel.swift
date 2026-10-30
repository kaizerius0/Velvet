import Foundation

/// Das Suchfeld oben in jeder Playlist: einen Titel suchen und per „+“ hinzufügen.
@MainActor
final class QuickAddModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case searching
        case results
        case empty
        case failed(String)
    }

    @Published var text = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var query = ""
    @Published private(set) var results: [VideoCandidate] = []
    @Published private(set) var added: Set<String> = []

    private var seen: Set<String> = []
    private var task: Task<Void, Never>?

    var isOpen: Bool { phase != .idle }

    func search(_ text: String, tools: ToolPaths?, cookies: CookieBrowser) {
        query = text
        seen = []
        added = []
        load(tools: tools, cookies: cookies)
    }

    /// Fünf weitere Treffer, die noch nicht gezeigt wurden.
    func loadMore(tools: ToolPaths?, cookies: CookieBrowser) {
        load(tools: tools, cookies: cookies)
    }

    func markAdded(_ candidate: VideoCandidate) {
        added.insert(candidate.id)
    }

    func close() {
        task?.cancel()
        phase = .idle
        results = []
        added = []
    }

    private func load(tools: ToolPaths?, cookies: CookieBrowser) {
        guard let tools else {
            phase = .failed("Velvet wird noch vorbereitet. Gleich noch einmal versuchen.")
            return
        }
        task?.cancel()
        phase = .searching
        let manager = DownloadManager(tools: tools)
        let text = query
        let excluded = seen
        task = Task { [weak self] in
            do {
                let found = try await manager.search(text, excluding: excluded, cookies: cookies)
                guard let self, !Task.isCancelled else { return }
                self.results = found
                self.seen.formUnion(found.map(\.id))
                self.phase = found.isEmpty ? .empty : .results
            } catch {
                guard let self, !(error is CancellationError) else { return }
                self.phase = .failed((error as? DownloadFailure)?.message ?? error.localizedDescription)
            }
        }
    }
}
