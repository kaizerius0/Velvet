import Foundation

/// Zwischenspeicher für Vorschauen: die Tonspur in kleiner Qualität, je Video eine Datei.
/// Dient zum Vorhören und für die Tempo-/Tonart-Analyse von Vorschlägen. Alte Dateien werden gelöscht.
actor PreviewCache {
    static let shared = PreviewCache()

    nonisolated let folder: URL
    private var running: [String: Task<URL, Error>] = [:]
    private var observers: [String: [@Sendable (Double) -> Void]] = [:]
    private var downloadsSincePrune = 0
    private static let maxBytes: Int64 = 600_000_000

    init(folder: URL? = nil) {
        if let folder {
            self.folder = folder
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let bundle = Bundle.main.bundleIdentifier ?? "de.velvet.Velvet"
            self.folder = caches.appendingPathComponent(bundle, isDirectory: true).appendingPathComponent("Vorschau", isDirectory: true)
        }
    }

    /// Schon geladen?
    nonisolated func cachedFile(for videoID: String) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        return files.first { $0.deletingPathExtension().lastPathComponent == videoID && $0.pathExtension != "part" }
    }

    /// Lädt die Vorschau (oder wartet auf einen schon laufenden Download desselben Videos).
    func file(
        for candidate: VideoCandidate,
        manager: DownloadManager,
        cookies: CookieBrowser,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if let cached = cachedFile(for: candidate.id) {
            touch(cached)
            return cached
        }
        if let onProgress { observers[candidate.id, default: []].append(onProgress) }
        if let task = running[candidate.id] { return try await task.value }

        let id = candidate.id
        let folder = folder
        let task = Task<URL, Error> {
            try await manager.downloadPreview(candidate.url, videoID: id, to: folder, cookies: cookies) { fraction in
                Task { await self.report(fraction, for: id) }
            }
        }
        running[id] = task
        defer {
            running[id] = nil
            observers[id] = nil
        }
        let file = try await task.value
        downloadsSincePrune += 1
        if downloadsSincePrune >= 20 {
            downloadsSincePrune = 0
            prune()
        }
        return file
    }

    private func report(_ fraction: Double, for id: String) {
        observers[id]?.forEach { $0(fraction) }
    }

    private nonisolated func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    /// Hält den Zwischenspeicher unter ~600 MB – die zuletzt benutzten Dateien bleiben.
    func prune() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.compactMap { url -> (URL, Int64, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys), let size = values.fileSize else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total > Self.maxBytes {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}

/// Höchstens `limit` Aufgaben gleichzeitig – damit YouTube nicht mit Anfragen überhäuft wird.
actor AsyncLimiter {
    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            active -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
