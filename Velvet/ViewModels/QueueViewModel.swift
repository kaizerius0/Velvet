import AppKit
import Foundation

/// Die Warteschlange aller Titel, die gerade hinzugefügt werden – jeder mit seiner Ziel-Playlist.
/// Suchen, Auswahl, parallele Downloads; fertige Titel verschwinden und stehen dann in der Bibliothek.
@MainActor
final class QueueViewModel: ObservableObject {
    struct Activity: Equatable {
        var searching = 0
        var waiting = 0
        var transferring = 0
        var needsAttention = 0
        var problems = 0

        var busy: Int { searching + waiting + transferring }
        var isEmpty: Bool { busy == 0 && needsAttention == 0 && problems == 0 }
    }

    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var activity = Activity()

    private let settings: AppSettings
    private let tools: ToolManager
    private let history: HistoryStore
    private let library: LibraryViewModel
    private var cachedManager: DownloadManager?
    private var cachedPaths: ToolPaths?
    private var pendingSearches: [DownloadItem] = []
    private var activeSearchCount = 0
    private var activeDownloadCount = 0
    private var sleepActivity: NSObjectProtocol?

    private static let maxParallelSearches = 3

    init(settings: AppSettings, tools: ToolManager, history: HistoryStore, library: LibraryViewModel) {
        self.settings = settings
        self.tools = tools
        self.history = history
        self.library = library
    }

    var hasBusyItems: Bool { items.contains { $0.status.isBusy } }

    /// Titel, die in diesen Ordner geladen werden.
    func items(for folder: URL) -> [DownloadItem] {
        let path = folder.standardizedFileURL.path
        return items.filter { $0.destination.standardizedFileURL.path == path }
    }

    /// Titel, die irgendwo in diese Bibliothek geladen werden.
    func items(within root: URL) -> [DownloadItem] {
        let path = root.standardizedFileURL.path
        return items.filter {
            let destination = $0.destination.standardizedFileURL.path
            return destination == path || destination.hasPrefix(path + "/")
        }
    }

    func isWriting(to root: URL) -> Bool {
        items(within: root).contains { $0.status.isBusy }
    }

    private var manager: DownloadManager? {
        guard let paths = tools.paths else { return nil }
        if paths != cachedPaths {
            cachedManager = DownloadManager(tools: paths)
            cachedPaths = paths
        }
        return cachedManager
    }

    // MARK: - Hinzufügen

    /// Titel und Links aus einer Eingabe – Links laden sofort, Titel werden gesucht.
    func add(entries: [ParsedEntry], to folder: URL) {
        guard !entries.isEmpty else { return }
        let options = prepare(folder)
        for entry in entries {
            let item = DownloadItem(entry: entry, destination: folder, options: options)
            items.append(item)
            begin(item)
        }
        pumpSearches()
        pumpDownloads()
        refresh()
    }

    /// Ein schon gewähltes Video (z. B. aus den Vorschlägen unter dem Suchfeld).
    func add(candidate: VideoCandidate, query: String?, to folder: URL) {
        let item = DownloadItem(candidate: candidate, query: query, destination: folder, options: prepare(folder))
        items.append(item)
        pumpDownloads()
        refresh()
    }

    private func prepare(_ folder: URL) -> DownloadOptions {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let options = settings.downloadOptions(destination: folder)
        // Reste eines abgebrochenen Downloads in diesem Ordner (halbe Dateien) entfernen.
        if !items(for: folder).contains(where: { $0.status.isBusy }) {
            try? FileManager.default.removeItem(at: options.tempDirectory)
        }
        return options
    }

    private func begin(_ item: DownloadItem) {
        switch item.origin {
        case .search:
            enqueueSearch(item)
        case .link:
            guard let url = item.sourceURL else { return }
            if YouTubeLink.isChannel(url) {
                item.status = .failed("Kanal-Links werden nicht unterstützt.")
            } else if YouTubeLink.isPlaylist(url) {
                resolvePlaylist(item)
            } else {
                item.status = .waiting
            }
        }
    }

    // MARK: - Aktionen

    func choose(_ candidate: VideoCandidate, for item: DownloadItem) {
        stopWork(of: item)
        rememberFileForReplacement(item)
        item.chosen = candidate
        item.title = candidate.title
        item.videoID = candidate.id
        item.sourceURL = candidate.url
        queueDownload(item)
    }

    func useLink(_ url: URL, for item: DownloadItem) {
        stopWork(of: item)
        rememberFileForReplacement(item)
        item.chosen = nil
        item.title = nil
        item.sourceURL = YouTubeLink.normalized(url)
        item.videoID = YouTubeLink.videoID(in: url)
        queueDownload(item)
    }

    /// Fünf neue Vorschläge (beim ersten Mal für Links: Suche nach dem Videotitel).
    func showMoreSuggestions(for item: DownloadItem) {
        guard item.canSuggest else { return }
        stopWork(of: item)
        if item.query.trimmingCharacters(in: .whitespaces).isEmpty, let title = item.title {
            item.query = title
        }
        item.page = item.hasSearched ? item.page + 1 : 0
        item.allowAutoPick = false
        enqueueSearch(item)
        refresh()
    }

    func search(_ item: DownloadItem, for query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stopWork(of: item)
        item.query = trimmed
        item.page = 0
        item.seenCandidateIDs = []
        item.allowAutoPick = false
        enqueueSearch(item)
        refresh()
    }

    func retry(_ item: DownloadItem) {
        stopWork(of: item)
        if let url = item.sourceURL {
            if YouTubeLink.isPlaylist(url) {
                resolvePlaylist(item)
            } else {
                queueDownload(item)
            }
        } else {
            enqueueSearch(item)
        }
        refresh()
    }

    /// Lädt einen Titel, obwohl er im Archiv steht oder schon vorhanden ist.
    func forceDownload(_ item: DownloadItem) {
        stopWork(of: item)
        item.ignoreArchive = true
        if item.sourceURL != nil {
            queueDownload(item)
        } else {
            enqueueSearch(item)
        }
        refresh()
    }

    /// Bricht ab und entfernt den Eintrag.
    func remove(_ item: DownloadItem) {
        stopWork(of: item)
        items.removeAll { $0 === item }
        cleanUpTemporaryFiles(in: item.destination)
        refresh()
    }

    func removeAll() {
        for item in items { stopWork(of: item) }
        let folders = Set(items.map(\.destination))
        items.removeAll()
        pendingSearches = []
        folders.forEach { cleanUpTemporaryFiles(in: $0) }
        refresh()
    }

    func retryAllProblems() {
        for item in items where item.status.isProblem { retry(item) }
    }

    // MARK: - Suche

    private func enqueueSearch(_ item: DownloadItem) {
        item.status = .searching
        if !pendingSearches.contains(where: { $0 === item }) {
            pendingSearches.append(item)
        }
        pumpSearches()
    }

    private func pumpSearches() {
        while activeSearchCount < Self.maxParallelSearches, !pendingSearches.isEmpty {
            let item = pendingSearches.removeFirst()
            guard item.status == .searching else { continue }
            runSearch(item)
        }
    }

    private func runSearch(_ item: DownloadItem) {
        guard let manager else {
            item.status = .failed("Die Werkzeuge sind noch nicht bereit.")
            return
        }
        let token = UUID()
        let query = item.query
        // Das bisher gewählte (falsche) Video und schon gezeigte Vorschläge nicht noch einmal anbieten.
        var excluded = item.seenCandidateIDs
        if let current = item.videoID { excluded.insert(current) }
        let cookies = item.options.cookieBrowser
        item.searchToken = token
        activeSearchCount += 1

        item.searchTask = Task { [weak self] in
            let outcome: Result<[VideoCandidate], Error>
            do {
                outcome = .success(try await manager.search(query, excluding: excluded, cookies: cookies))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            self.activeSearchCount -= 1
            if item.searchToken == token {
                self.finishSearch(item, outcome)
            }
            self.pumpSearches()
            self.refresh()
        }
    }

    private func finishSearch(_ item: DownloadItem, _ outcome: Result<[VideoCandidate], Error>) {
        item.searchTask = nil
        item.searchToken = nil
        guard item.status == .searching else { return }

        switch outcome {
        case let .success(fresh):
            item.hasSearched = true
            item.candidates = fresh
            item.seenCandidateIDs.formUnion(fresh.map(\.id))
            if fresh.isEmpty {
                item.status = .noResults
            } else if settings.autoPickFirstResult, item.allowAutoPick {
                item.allowAutoPick = false
                choose(fresh[0], for: item)
            } else {
                item.status = .needsSelection
            }
        case let .failure(error):
            guard !(error is CancellationError) else { return }
            item.status = .failed(Self.message(for: error))
        }
    }

    // MARK: - Playlists

    private func resolvePlaylist(_ item: DownloadItem) {
        guard let manager, let url = item.sourceURL else { return }
        let token = UUID()
        let cookies = item.options.cookieBrowser
        item.searchToken = token
        item.status = .resolvingPlaylist

        item.searchTask = Task { [weak self] in
            let outcome: Result<[VideoCandidate], Error>
            do {
                outcome = .success(try await manager.playlistEntries(url, cookies: cookies))
            } catch {
                outcome = .failure(error)
            }
            guard let self, item.searchToken == token else { return }
            item.searchTask = nil
            item.searchToken = nil
            switch outcome {
            case let .success(entries) where !entries.isEmpty:
                self.expand(item, into: entries)
            case .success:
                item.status = .failed("Die Playlist ist leer oder nicht verfügbar.")
            case let .failure(error):
                if !(error is CancellationError) { item.status = .failed(Self.message(for: error)) }
            }
            self.pumpDownloads()
            self.refresh()
        }
    }

    /// Ersetzt den Playlist-Eintrag durch die einzelnen Videos.
    private func expand(_ item: DownloadItem, into entries: [VideoCandidate]) {
        guard let index = items.firstIndex(where: { $0 === item }) else { return }
        let children = entries.map { DownloadItem(candidate: $0, query: nil, destination: item.destination, options: item.options) }
        items.replaceSubrange(index...index, with: children)
    }

    // MARK: - Downloads

    private func queueDownload(_ item: DownloadItem) {
        item.status = .waiting
        item.progress = 0
        item.detail = nil
        item.phaseText = nil
        pumpDownloads()
        refresh()
    }

    private func pumpDownloads() {
        let limit = min(max(settings.maxParallelDownloads, 1), 4)
        while activeDownloadCount < limit, let next = items.first(where: { $0.status == .waiting }) {
            startDownload(next)
        }
    }

    private func startDownload(_ item: DownloadItem) {
        guard let manager, let url = item.sourceURL else {
            item.status = .failed(tools.paths == nil ? "Die Werkzeuge sind noch nicht bereit." : "Für diesen Titel gibt es keinen Link.")
            return
        }
        var options = item.options
        if item.ignoreArchive { options.useArchive = false }
        item.ignoreArchive = false

        let token = UUID()
        item.downloadToken = token
        item.status = .downloading
        item.progress = 0
        item.detail = nil
        item.phaseText = nil
        item.log = []
        activeDownloadCount += 1

        item.downloadTask = Task { [weak self] in
            var captured: AsyncStream<DownloadEvent>.Continuation?
            let events = AsyncStream<DownloadEvent>(bufferingPolicy: .bufferingNewest(200)) { captured = $0 }
            let continuation = captured!

            // Ereignisse in Reihenfolge auf dem Main Actor verarbeiten.
            let consumer = Task { [weak self] in
                for await event in events where item.downloadToken == token {
                    self?.apply(event, to: item)
                }
            }

            let outcome: Result<DownloadResult, Error>
            do {
                outcome = .success(try await manager.download(url, options: options) { continuation.yield($0) })
            } catch {
                outcome = .failure(error)
            }
            continuation.finish()
            await consumer.value

            guard let self else { return }
            self.activeDownloadCount -= 1
            if item.downloadToken == token {
                self.finishDownload(item, outcome)
            }
            self.pumpDownloads()
            self.refresh()
        }
    }

    private func apply(_ event: DownloadEvent, to item: DownloadItem) {
        switch event {
        case let .metadata(videoID, title):
            item.videoID = videoID
            if item.chosen == nil { item.title = title }
        case let .progress(fraction, speed, eta):
            if item.status != .downloading { item.status = .downloading }
            item.progress = max(item.progress, fraction)
            item.detail = Formatters.progressDetail(speed: speed, eta: eta)
        case let .postprocessing(label):
            item.status = .processing
            item.phaseText = label
            item.detail = nil
            item.progress = max(item.progress, YTDLPOutput.downloadShare)
        }
    }

    private func finishDownload(_ item: DownloadItem, _ outcome: Result<DownloadResult, Error>) {
        item.downloadTask = nil
        item.downloadToken = nil
        item.detail = nil
        item.phaseText = nil

        switch outcome {
        case let .success(.completed(file, videoID)):
            item.status = .completed
            item.progress = 1
            item.outputFile = file
            if let videoID { item.videoID = videoID }
            history.recordDownload(
                title: item.chosen?.title ?? item.title ?? file.deletingPathExtension().lastPathComponent,
                query: item.origin == .search ? item.originalText : item.label,
                videoID: item.videoID,
                sourceURL: item.sourceURL,
                file: file
            )
            replacePreviousFile(of: item)
            library.refreshIfAffected(by: file)
            cleanUpTemporaryFiles(in: item.destination)
            removeLater(item)
        case let .success(.skipped(reason)):
            item.status = .skipped(reason)
            item.progress = 1
            item.replacedFile = nil
            item.replacedVideoID = nil
        case let .failure(error):
            if error is CancellationError {
                item.status = .cancelled
            } else if let failure = error as? DownloadFailure {
                item.status = .failed(failure.message)
                item.log = failure.log
            } else {
                item.status = .failed(Self.message(for: error))
            }
        }
    }

    /// Fertige Titel bleiben kurz als „Hinzugefügt“ stehen – bis die Bibliothek sie zeigt.
    private func removeLater(_ item: DownloadItem) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, item.status == .completed else { return }
            self.items.removeAll { $0 === item }
            self.refresh()
        }
    }

    /// Wurde ein bereits geladenes Video durch ein anderes ersetzt, wird die alte Datei gelöscht.
    private func rememberFileForReplacement(_ item: DownloadItem) {
        guard let file = item.outputFile else { return }
        item.replacedFile = file
        item.replacedVideoID = item.videoID
        item.outputFile = nil
    }

    private func replacePreviousFile(of item: DownloadItem) {
        defer {
            item.replacedFile = nil
            item.replacedVideoID = nil
        }
        guard let old = item.replacedFile, old != item.outputFile else { return }
        if FileManager.default.fileExists(atPath: old.path) {
            try? LibraryFiles.remove(old, permanently: library.deletesPermanently(at: old))
        }
        history.markRemoved(old, state: .replaced, note: item.outputFile.map { "Ersetzt durch „\($0.deletingPathExtension().lastPathComponent)“" })
        if let oldID = item.replacedVideoID, oldID != item.videoID, item.options.useArchive {
            DownloadManager.removeFromArchive(videoID: oldID, archive: item.options.archiveURL)
        }
    }

    /// Bricht laufende Suchen/Downloads ab; deren spätere Ergebnisse werden verworfen.
    private func stopWork(of item: DownloadItem) {
        item.searchToken = nil
        item.downloadToken = nil
        item.searchTask?.cancel()
        item.downloadTask?.cancel()
        item.searchTask = nil
        item.downloadTask = nil
        pendingSearches.removeAll { $0 === item }
        item.detail = nil
        item.phaseText = nil
    }

    // MARK: - Zustand

    private func refresh() {
        var next = Activity()
        for item in items {
            switch item.status {
            case .searching, .resolvingPlaylist: next.searching += 1
            case .waiting: next.waiting += 1
            case .downloading, .processing: next.transferring += 1
            case .needsSelection, .noResults: next.needsAttention += 1
            case .failed, .skipped: next.problems += 1
            case .completed, .cancelled, .ignored: break
            }
        }
        if next != activity { activity = next }
        updateSystemIntegration()
    }

    /// Dock-Symbol und Ruhezustand.
    private func updateSystemIntegration() {
        NSApp?.dockTile.badgeLabel = activity.needsAttention > 0 ? "\(activity.needsAttention)" : nil

        let busy = activity.busy > 0
        if busy, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Velvet lädt Titel herunter"
            )
        } else if !busy, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    private func cleanUpTemporaryFiles(in folder: URL) {
        guard !items(for: folder).contains(where: { $0.status.isBusy }) else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(".velvet-temp", isDirectory: true))
    }

    private static func message(for error: Error) -> String {
        if let failure = error as? DownloadFailure { return failure.message }
        return error.localizedDescription
    }
}
