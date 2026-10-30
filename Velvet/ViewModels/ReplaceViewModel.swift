import Foundation

/// Tauscht einen Titel der Bibliothek gegen eine andere Version aus (z. B. die Extended Version):
/// suchen → auswählen → neue Datei in denselben Ordner laden → alte Datei löschen.
@MainActor
final class ReplaceViewModel: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case searching
        case choosing
        case noResults
        case downloading
        case done(String)
        case failed(String)
    }

    let id = UUID()
    let track: Track
    let locationText: String

    @Published var query: String
    @Published private(set) var candidates: [VideoCandidate] = []
    @Published private(set) var phase: Phase = .searching
    @Published private(set) var progress: Double = 0
    @Published private(set) var detail: String?

    private let manager: DownloadManager
    private let settings: AppSettings
    private let library: LibraryViewModel
    private let history: HistoryStore
    private var seen: Set<String> = []
    private var task: Task<Void, Never>?

    init(track: Track, tools: ToolPaths, settings: AppSettings, library: LibraryViewModel, history: HistoryStore) {
        self.track = track
        self.locationText = library.locationText(for: track.url)
        self.query = track.title
        self.manager = DownloadManager(tools: tools)
        self.settings = settings
        self.library = library
        self.history = history
    }

    var isBusy: Bool { phase == .searching || phase == .downloading }

    // MARK: Suchen

    func search() {
        seen = []
        loadSuggestions()
    }

    /// Hängt ein Stichwort an („Extended“, „Live“ …) und sucht neu.
    func refine(with word: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.lowercased().contains(word.lowercased()) {
            query = trimmed.isEmpty ? word : "\(trimmed) \(word)"
        }
        search()
    }

    func loadSuggestions() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        task?.cancel()
        phase = .searching
        let excluded = seen
        let cookies = settings.cookieBrowser
        task = Task { [weak self, manager] in
            do {
                let results = try await manager.search(text, excluding: excluded, cookies: cookies)
                guard let self, !Task.isCancelled else { return }
                self.candidates = results
                self.seen.formUnion(results.map(\.id))
                self.phase = results.isEmpty ? .noResults : .choosing
            } catch {
                guard let self, !(error is CancellationError) else { return }
                self.phase = .failed((error as? DownloadFailure)?.message ?? error.localizedDescription)
            }
        }
    }

    // MARK: Austauschen

    func choose(_ candidate: VideoCandidate) {
        replace(with: candidate.url, title: candidate.title)
    }

    func useLink(_ text: String) {
        guard let url = ListParser.link(from: text), !YouTubeLink.isPlaylist(url), !YouTubeLink.isChannel(url) else {
            phase = .failed("Das ist kein gültiger Link zu einem einzelnen Video.")
            return
        }
        replace(with: url, title: nil)
    }

    func cancel() {
        task?.cancel()
    }

    private func replace(with url: URL, title: String?) {
        task?.cancel()
        phase = .downloading
        progress = 0
        detail = nil

        let oldFile = track.url
        let folder = oldFile.deletingLastPathComponent()
        let options = DownloadOptions(
            format: track.isAudio ? .audio : .video,
            videoQuality: settings.videoQuality,
            audioQuality: settings.audioQuality,
            destination: folder,
            // Austauschen soll immer laden, auch wenn das Video schon einmal geladen wurde.
            useArchive: false,
            cookieBrowser: settings.cookieBrowser
        )
        let permanently = library.deletesPermanently

        task = Task { [weak self, manager] in
            // Die alte Datei zur Seite legen, damit eine gleichnamige neue Datei nicht übersprungen wird.
            let backupFolder = options.tempDirectory.appendingPathComponent("replaced-\(UUID().uuidString)", isDirectory: true)
            let backup = backupFolder.appendingPathComponent(oldFile.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: oldFile, to: backup)
            } catch {
                self?.phase = .failed("Die alte Datei konnte nicht verschoben werden: \(error.localizedDescription)")
                return
            }

            func restore() {
                if !FileManager.default.fileExists(atPath: oldFile.path) {
                    try? FileManager.default.moveItem(at: backup, to: oldFile)
                }
                try? FileManager.default.removeItem(at: backupFolder)
            }

            do {
                let result = try await manager.download(url, options: options) { event in
                    Task { @MainActor in self?.apply(event) }
                }
                guard let self else { return restore() }
                switch result {
                case let .completed(file, videoID):
                    try? LibraryFiles.remove(backup, permanently: permanently)
                    try? FileManager.default.removeItem(at: backupFolder)
                    try? FileManager.default.removeItem(at: options.tempDirectory)
                    let newTitle = file.deletingPathExtension().lastPathComponent
                    self.history.markRemoved(oldFile, state: .replaced, note: "Ersetzt durch „\(newTitle)“")
                    self.history.recordDownload(title: title ?? newTitle, query: self.query, videoID: videoID, sourceURL: url, file: file)
                    self.progress = 1
                    self.phase = .done(newTitle)
                    self.library.rescan()
                case .skipped:
                    restore()
                    self.phase = .failed("Das Video wurde übersprungen (Livestream?). Die alte Datei bleibt erhalten.")
                }
            } catch {
                restore()
                guard let self else { return }
                if error is CancellationError {
                    self.phase = .choosing
                } else {
                    self.phase = .failed(((error as? DownloadFailure)?.message ?? error.localizedDescription) + " Die alte Datei bleibt erhalten.")
                }
            }
        }
    }

    private func apply(_ event: DownloadEvent) {
        guard phase == .downloading else { return }
        switch event {
        case .metadata:
            break
        case let .progress(fraction, speed, eta):
            progress = max(progress, fraction)
            detail = Formatters.progressDetail(speed: speed, eta: eta).map { "\(Formatters.percent(progress)) · \($0)" } ?? Formatters.percent(progress)
        case let .postprocessing(label):
            progress = max(progress, YTDLPOutput.downloadShare)
            detail = label
        }
    }
}
