import Foundation

/// Der Verlauf aller Downloads – gespeichert in `~/Library/Application Support/Velvet/history.json`.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    /// Erhöht sich bei jeder Änderung.
    @Published private(set) var revision = 0

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    nonisolated static var defaultFileURL: URL {
        #if DEBUG
        let name = "history-dev.json"
        #else
        let name = "history.json"
        #endif
        let root = (try? YtDlpInstaller.supportRoot()) ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(name)
    }

    init(fileURL: URL = HistoryStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
        }
    }

    // MARK: Eintragen

    func recordDownload(title: String, query: String?, videoID: String?, sourceURL: URL?, file: URL) {
        let volume = VolumeService.volume(containing: file)
        var entry = HistoryEntry(
            date: Self.now(),
            title: title,
            query: query,
            videoID: videoID,
            sourceURL: sourceURL?.absoluteString,
            format: file.pathExtension.uppercased(),
            path: file.path,
            folderName: file.deletingLastPathComponent().lastPathComponent,
            volumeName: volume?.name ?? "Mac"
        )
        if let volume, volume.isExternal {
            entry.volumeUUID = volume.uuid
            entry.relativePath = VolumeService.relativePath(of: file, in: volume)
        }
        // Dieselbe Datei erneut geladen: den bisherigen Eintrag ersetzen statt doppelt aufzuführen.
        let path = file.standardizedFileURL.path
        entries.removeAll { $0.state == .downloaded && standardized($0.path) == path }
        entries.insert(entry, at: 0)
        changed()
    }

    /// Eine Datei wurde gelöscht oder ersetzt.
    func markRemoved(_ url: URL, state: HistoryEntry.State, note: String? = nil) {
        let path = url.standardizedFileURL.path
        var didChange = false
        for index in entries.indices where entries[index].state == .downloaded && standardized(entries[index].path) == path {
            entries[index].state = state
            entries[index].stateDate = Self.now()
            entries[index].note = note
            didChange = true
        }
        if didChange { changed() }
    }

    /// Eine Datei oder ein ganzer Ordner wurde umbenannt bzw. verschoben.
    func updatePaths(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        let newPath = new.standardizedFileURL.path
        var didChange = false
        for index in entries.indices {
            let path = standardized(entries[index].path)
            guard path == oldPath || path.hasPrefix(oldPath + "/") else { continue }
            let updated = URL(fileURLWithPath: newPath + path.dropFirst(oldPath.count))
            entries[index].path = updated.path
            entries[index].folderName = updated.deletingLastPathComponent().lastPathComponent
            if entries[index].volumeUUID != nil, let volume = VolumeService.volume(containing: updated) {
                entries[index].relativePath = VolumeService.relativePath(of: updated, in: volume)
            }
            didChange = true
        }
        if didChange { changed() }
    }

    func remove(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        changed()
    }

    func clear() {
        entries.removeAll()
        changed()
    }

    // MARK: Abfragen

    /// Findet die Datei – auch wenn der Stick unter einem anderen Pfad eingehängt ist.
    func resolvedURL(for entry: HistoryEntry, volumes: [VolumeInfo]) -> URL? {
        if let uuid = entry.volumeUUID, let relative = entry.relativePath {
            guard let volume = volumes.first(where: { $0.uuid == uuid }) else { return nil }
            return volume.url.appendingPathComponent(relative)
        }
        return URL(fileURLWithPath: entry.path)
    }

    func availability(of entry: HistoryEntry, volumes: [VolumeInfo]) -> HistoryAvailability {
        switch entry.state {
        case .replaced: return .replaced(entry.note)
        case .deleted: return .deleted
        case .downloaded: break
        }
        guard let url = resolvedURL(for: entry, volumes: volumes) else { return .offline(entry.volumeName) }
        return FileManager.default.fileExists(atPath: url.path) ? .present(url) : .missing
    }

    /// Sofort speichern, z. B. beim Beenden.
    func saveNow() {
        saveTask?.cancel()
        Self.write(entries, to: fileURL)
    }

    // MARK: Intern

    /// Auf Sekunden gerundet – so viel speichert das JSON-Datumsformat.
    private static func now() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func changed() {
        revision += 1
        saveTask?.cancel()
        let snapshot = entries
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            Self.write(snapshot, to: url)
        }
    }

    nonisolated private static func write(_ entries: [HistoryEntry], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
