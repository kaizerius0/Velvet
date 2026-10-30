import AppKit
import Foundation

/// Steuert einen Download-Lauf: Suchen, Auswahl, Warteschlange, parallele Downloads und Zusammenfassung.
@MainActor
final class QueueViewModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case attention
        case active
        case problems

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "Alle"
            case .attention: return "Auswahl nötig"
            case .active: return "In Arbeit"
            case .problems: return "Probleme"
            }
        }
    }

    struct Summary: Equatable {
        var total = 0
        var completed = 0
        var skipped = 0
        var failed = 0
        var cancelled = 0
        var ignored = 0
        var needsAttention = 0
        var searching = 0
        var transferring = 0
        var waiting = 0

        var finished: Int { completed + skipped + failed + cancelled + ignored }
        var active: Int { searching + transferring + waiting }
    }

    @Published private(set) var items: [DownloadItem] = []
    @Published private(set) var summary = Summary()
    @Published private(set) var overallProgress: Double = 0
    @Published private(set) var options: DownloadOptions?
    @Published var filter: Filter = .all

    private let settings: AppSettings
    private let tools: ToolManager
    private let history: HistoryStore
    private let library: LibraryViewModel
    private var manager: DownloadManager?
    private var pendingSearches: [DownloadItem] = []
    private var activeSearchCount = 0
    private var activeDownloadCount = 0
    private var sleepActivity: NSObjectProtocol?
    private var didAnnounceFinish = false

    private static let maxParallelSearches = 3

    init(settings: AppSettings, tools: ToolManager, history: HistoryStore, library: LibraryViewModel) {
        self.settings = settings
        self.tools = tools
        self.history = history
        self.library = library
    }

    var hasRun: Bool { !items.isEmpty }
    var isFinished: Bool { hasRun && summary.finished == summary.total }
    var hasBusyItems: Bool { items.contains { $0.status.isBusy } }
    var destination: URL? { options?.destination }

    var filteredItems: [DownloadItem] {
        switch filter {
        case .all: return items
        case .attention: return items.filter { $0.status.needsAttention }
        case .active: return items.filter { $0.status.isBusy }
        case .problems: return items.filter { $0.status.isProblem }
        }
    }

    func count(for filter: Filter) -> Int {
        switch filter {
        case .all: return summary.total
        case .attention: return summary.needsAttention
        case .active: return summary.active
        case .problems: return summary.failed + summary.cancelled
        }
    }

    var failedItems: [DownloadItem] {
        items.filter { if case .failed = $0.status { return true } else { return false } }
    }

    // MARK: - Start

    /// - Parameter existing: Einträge, die schon in der Bibliothek liegen (Eintrags-ID → Ort) – sie werden übersprungen.
    func start(entries: [ParsedEntry], destination: URL, existing: [Int: String] = [:]) {
        guard let paths = tools.paths, !entries.isEmpty else { return }
        reset()
        manager = DownloadManager(tools: paths)
        let options = settings.downloadOptions(destination: destination)
        self.options = options
        settings.lastDestinationPath = destination.path
        // Reste eines abgebrochenen Laufs in diesem Ordner (halbe Dateien) entfernen.
        try? FileManager.default.removeItem(at: options.tempDirectory)

        items = entries.enumerated().map { DownloadItem(entry: $1, number: $0 + 1) }
        for (entry, item) in zip(entries, items) {
            if let location = existing[entry.id] {
                item.status = .skipped(.inLibrary(location))
                continue
            }
            switch item.origin {
            case .search:
                enqueueSearch(item)
            case .link:
                guard let url = item.sourceURL else { continue }
                if YouTubeLink.isChannel(url) {
                    item.status = .failed("Kanal-Links werden nicht unterstützt – bitte einzelne Videos oder Playlists einfügen.")
                } else if YouTubeLink.isPlaylist(url) {
                    resolvePlaylist(item)
                } else {
                    item.status = .waiting
                }
            }
        }
        pumpSearches()
        pumpDownloads()
        refresh()
    }

    /// Beendet alles und kehrt zur Eingabe zurück. Bereits geladene Dateien bleiben erhalten.
    func reset() {
        for item in items {
            stopWork(of: item)
            if !item.status.isTerminal { item.status = .cancelled }
        }
        cleanUpTemporaryFiles()
        items = []
        pendingSearches = []
        options = nil
        manager = nil
        filter = .all
        didAnnounceFinish = false
        refresh()
    }

    // MARK: - Nutzeraktionen

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

    /// Lädt die nächsten fünf Treffer (beim ersten Mal für Links: Suche nach dem Videotitel).
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

    func skip(_ item: DownloadItem) {
        stopWork(of: item)
        item.status = .ignored
        refresh()
    }

    func cancel(_ item: DownloadItem) {
        stopWork(of: item)
        item.status = .cancelled
        refresh()
    }

    func retry(_ item: DownloadItem) {
        stopWork(of: item)
        // Mit Link (direkt, gewählt oder manuell) erneut laden, sonst erneut suchen.
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

    /// Lädt ein Video, obwohl es im Archiv oder in der Bibliothek schon vorhanden ist.
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

    func retryAllFailed() {
        for item in failedItems { retry(item) }
    }

    func skipRemainingSelections() {
        for item in items where item.status.needsAttention {
            item.status = .ignored
        }
        refresh()
    }

    func cancelAll() {
        for item in items where !item.status.isTerminal {
            stopWork(of: item)
            item.status = .cancelled
        }
        pendingSearches = []
        refresh()
    }

    func openDestination() {
        guard let destination else { return }
        NSWorkspace.shared.open(destination)
    }

    func reveal(_ item: DownloadItem) {
        guard let file = item.outputFile, FileManager.default.fileExists(atPath: file.path) else {
            openDestination()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
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
        guard let manager else { return }
        let token = UUID()
        let query = item.query
        // Das bisher gewählte (falsche) Video und schon gezeigte Vorschläge nicht noch einmal anbieten.
        var excluded = item.seenCandidateIDs
        if let current = item.videoID { excluded.insert(current) }
        let cookies = options?.cookieBrowser ?? .none
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
        let cookies = options?.cookieBrowser ?? .none
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
        let children = entries.map { DownloadItem(candidate: $0, number: 0) }
        items.replaceSubrange(index...index, with: children)
        for (offset, entry) in items.enumerated() { entry.number = offset + 1 }
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
        guard let manager, var options, let url = item.sourceURL else {
            item.status = .failed("Für diesen Eintrag gibt es keinen Link.")
            return
        }
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
        refreshProgress()
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

    /// Wurde ein bereits geladenes Video durch ein anderes ersetzt, wandert die alte Datei in den Papierkorb.
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
            // Auf Sticks endgültig löschen, auf dem Mac in den Papierkorb.
            let permanently = VolumeService.volume(containing: old)?.isExternal ?? false
            try? LibraryFiles.remove(old, permanently: permanently)
        }
        history.markRemoved(old, state: .replaced, note: item.outputFile.map { "Ersetzt durch „\($0.deletingPathExtension().lastPathComponent)“" })
        if let oldID = item.replacedVideoID, oldID != item.videoID, let options, options.useArchive {
            DownloadManager.removeFromArchive(videoID: oldID, archive: options.archiveURL)
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

    // MARK: - Zusammenfassung

    private func refresh() {
        var next = Summary()
        next.total = items.count
        for item in items {
            switch item.status {
            case .completed: next.completed += 1
            case .skipped: next.skipped += 1
            case .failed: next.failed += 1
            case .cancelled: next.cancelled += 1
            case .ignored: next.ignored += 1
            case .needsSelection, .noResults: next.needsAttention += 1
            case .searching, .resolvingPlaylist: next.searching += 1
            case .downloading, .processing: next.transferring += 1
            case .waiting: next.waiting += 1
            }
        }
        if next != summary { summary = next }
        refreshProgress()
        updateSystemIntegration()
    }

    private func refreshProgress() {
        guard !items.isEmpty else {
            overallProgress = 0
            return
        }
        let done = items.reduce(0.0) { sum, item in
            if item.status.isTerminal { return sum + 1 }
            if item.status.isTransferring { return sum + item.progress }
            return sum
        }
        let value = done / Double(items.count)
        if abs(value - overallProgress) >= 0.002 || value == 1 || value == 0 {
            overallProgress = value
        }
    }

    /// Dock-Symbol, Ruhezustand und Hinweis, wenn alles fertig ist.
    private func updateSystemIntegration() {
        NSApp?.dockTile.badgeLabel = summary.needsAttention > 0 ? "\(summary.needsAttention)" : nil

        let busy = hasBusyItems
        if busy, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Velvet lädt Videos herunter"
            )
        } else if !busy, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }

        if isFinished {
            if !didAnnounceFinish {
                didAnnounceFinish = true
                cleanUpTemporaryFiles()
                if let destination { library.refreshIfAffected(by: destination) }
                if NSApp?.isActive == false { NSApp?.requestUserAttention(.informationalRequest) }
            }
        } else {
            didAnnounceFinish = false
        }
    }

    private func cleanUpTemporaryFiles() {
        guard let temp = options?.tempDirectory, !hasBusyItems else { return }
        try? FileManager.default.removeItem(at: temp)
    }

    private static func message(for error: Error) -> String {
        if let failure = error as? DownloadFailure { return failure.message }
        return error.localizedDescription
    }
}
