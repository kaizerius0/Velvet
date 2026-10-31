import Foundation

/// Tempo und Tonart eines Titels.
struct TrackAnalysis: Codable, Hashable, Sendable {
    var bpm: Double?
    var key: MusicalKey?
    var analyzedAt = Date()

    var bpmText: String? {
        guard let bpm else { return nil }
        return bpm == bpm.rounded() ? "\(Int(bpm))" : String(format: "%.1f", bpm)
    }

    /// „124 BPM · 8A“
    var shortText: String? {
        let parts = [bpmText.map { "\($0) BPM" }, key?.camelot].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Ermittelt Tempo und Tonart – für geladene Titel (und schreibt sie in die MP3) sowie für Vorschläge
/// (über die Vorschau-Datei). Ergebnisse stehen in `~/Library/Application Support/Velvet/analysis.json`.
@MainActor
final class AnalysisCenter: ObservableObject {
    /// Erhöht sich bei jedem neuen Ergebnis.
    @Published private(set) var revision = 0
    /// Dateien, die noch analysiert werden (inklusive der laufenden).
    @Published private(set) var pendingCount = 0

    weak var library: LibraryViewModel?

    private let tools: ToolManager
    private let settings: AppSettings
    private let fileURL: URL
    private var results: [String: TrackAnalysis] = [:]
    private var queue: [(file: URL, videoID: String?)] = []
    private var current: URL?
    private var worker: Task<Void, Never>?
    private var videoTasks: [String: Task<TrackAnalysis?, Never>] = [:]
    private var saveTask: Task<Void, Never>?
    private let limiter = AsyncLimiter(limit: 2)
    /// Ordner, deren Ansicht nach dem Schreiben der Tags neu eingelesen werden muss.
    private var changedFiles: [URL] = []
    private var lastLibraryRefresh = Date.distantPast

    nonisolated static var defaultFileURL: URL {
        #if DEBUG
        let name = "analysis-dev.json"
        #else
        let name = "analysis.json"
        #endif
        let root = (try? YtDlpInstaller.supportRoot()) ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(name)
    }

    init(tools: ToolManager, settings: AppSettings, fileURL: URL = AnalysisCenter.defaultFileURL) {
        self.tools = tools
        self.settings = settings
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            results = (try? decoder.decode([String: TrackAnalysis].self, from: data)) ?? [:]
        }
    }

    // MARK: Abfragen

    /// Aus den Tags der Datei oder aus einer früheren Analyse.
    func analysis(for track: Track) -> TrackAnalysis? {
        if track.bpm != nil || track.key != nil { return TrackAnalysis(bpm: track.bpm, key: track.key) }
        return results[Self.fileKey(track.url)]
    }

    func analysis(forVideo id: String) -> TrackAnalysis? {
        results[Self.videoKey(id)]
    }

    func isAnalyzing(_ file: URL) -> Bool {
        current?.standardizedFileURL == file.standardizedFileURL
            || queue.contains { $0.file.standardizedFileURL == file.standardizedFileURL }
    }

    /// Wird gerade etwas auf diesem Laufwerk/in diesem Ordner geändert? (Dann nicht auswerfen.)
    func isBusy(within root: URL) -> Bool {
        let path = root.standardizedFileURL.path
        let files = queue.map(\.file) + (current.map { [$0] } ?? [])
        return files.contains { $0.standardizedFileURL.path.hasPrefix(path == "/" ? path : path + "/") }
    }

    // MARK: Dateien

    /// Titel analysieren und (bei MP3) BPM und Tonart in die Datei schreiben.
    func enqueue(_ files: [URL], knownVideoID: String? = nil) {
        for file in files where !isAnalyzing(file) {
            queue.append((file, knownVideoID))
        }
        updateCount()
        startWorker()
    }

    /// Alle Titel ohne Tempo/Tonart (z. B. ein ganzer Stick).
    func enqueueMissing(_ tracks: [Track]) {
        enqueue(tracks.filter { $0.isAudio && analysis(for: $0) == nil }.map(\.url))
    }

    func cancelAll() {
        queue.removeAll()
        worker?.cancel()
        worker = nil
        current = nil
        updateCount()
    }

    private func startWorker() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.queue.isEmpty {
                let job = self.queue.removeFirst()
                self.current = job.file
                self.updateCount()
                await self.process(job.file, videoID: job.videoID)
                self.current = nil
                self.updateCount()
            }
            self?.worker = nil
        }
    }

    private func process(_ file: URL, videoID: String?) async {
        guard let ffmpeg = tools.paths?.ffmpeg, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let samples = try await AudioDecoder.samples(of: file, ffmpeg: ffmpeg, start: 10, duration: 420)
            let result = await Task.detached(priority: .utility) { AudioAnalyzer.analyze(samples) }.value
            guard result.bpm != nil || result.key != nil else { return }
            var analysis = TrackAnalysis(bpm: result.bpm, key: result.key)
            if settings.analyzeDownloads, TagWriter.canWrite(file) {
                try? await TagWriter.write(bpm: result.bpm, key: result.key, to: file, ffmpeg: ffmpeg)
            }
            analysis.analyzedAt = Date()
            results[Self.fileKey(file)] = analysis
            if let videoID { results[Self.videoKey(videoID)] = analysis }
            changed()
            changedFiles.append(file)
            refreshLibraryIfDue()
        } catch {
            // Nicht lesbare Dateien einfach auslassen.
        }
    }

    /// Bei vielen Dateien nicht nach jeder neu einlesen – höchstens alle acht Sekunden und am Ende.
    private func refreshLibraryIfDue() {
        guard queue.isEmpty || Date().timeIntervalSince(lastLibraryRefresh) > 8, let library else { return }
        var seen = Set<String>()
        for file in changedFiles {
            guard let source = library.source(containing: file), seen.insert(source.id).inserted else { continue }
            library.rescan(source.id)
        }
        changedFiles.removeAll()
        lastLibraryRefresh = Date()
    }

    // MARK: Vorschläge

    /// Tempo und Tonart eines Videos, das (noch) nicht geladen ist – über die Vorschau-Datei.
    func analyzeVideo(_ candidate: VideoCandidate) async -> TrackAnalysis? {
        if let known = analysis(forVideo: candidate.id) { return known }
        if let running = videoTasks[candidate.id] { return await running.value }
        guard let manager = tools.downloadManager, let ffmpeg = tools.paths?.ffmpeg else { return nil }
        let cookies = settings.cookieBrowser
        let limiter = limiter
        let task = Task<TrackAnalysis?, Never> {
            await limiter.run {
                guard let file = try? await PreviewCache.shared.file(for: candidate, manager: manager, cookies: cookies),
                      let samples = try? await AudioDecoder.samples(of: file, ffmpeg: ffmpeg, start: 10, duration: 420) else { return nil }
                let result = await Task.detached(priority: .utility) { AudioAnalyzer.analyze(samples) }.value
                guard result.bpm != nil || result.key != nil else { return nil }
                return TrackAnalysis(bpm: result.bpm, key: result.key)
            }
        }
        videoTasks[candidate.id] = task
        let analysis = await task.value
        videoTasks[candidate.id] = nil
        if let analysis {
            results[Self.videoKey(candidate.id)] = analysis
            changed()
        }
        return analysis
    }

    // MARK: Intern

    private static func fileKey(_ url: URL) -> String { "file:" + url.standardizedFileURL.path }
    private static func videoKey(_ id: String) -> String { "yt:" + id }

    private func updateCount() {
        let count = queue.count + (current == nil ? 0 : 1)
        if count != pendingCount { pendingCount = count }
    }

    private func changed() {
        revision += 1
        saveTask?.cancel()
        let snapshot = results
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
