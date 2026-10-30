import Foundation

/// Dateioperationen der Bibliothek: einlesen, Playlists anlegen, umbenennen, verschieben, löschen, aufräumen.
enum LibraryFiles {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma", "alac"]
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi"]
    /// Systemordner von Windows/Android, die keine Playlists sind.
    private static let ignoredFolders: Set<String> = ["System Volume Information", "$RECYCLE.BIN", "RECYCLER", "LOST.DIR", "Android"]

    static func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return audioExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    struct Snapshot: Sendable {
        var playlists: [Playlist] = []
        var tracks: [Track] = []
    }

    /// Liest den Hauptordner und alle direkten Unterordner (= Playlists) ein.
    static func scan(root: URL) -> Snapshot {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]

        func contents(of folder: URL) -> [URL] {
            (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }

        func tracks(in folder: URL, playlist: String) -> [Track] {
            contents(of: folder).compactMap { url in
                guard isMedia(url), !url.lastPathComponent.hasPrefix("._"),
                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory != true else { return nil }
                return Track(
                    url: url,
                    playlistName: playlist,
                    size: Int64(values.fileSize ?? 0),
                    added: values.creationDate ?? values.contentModificationDate ?? .distantPast,
                    isAudio: audioExtensions.contains(url.pathExtension.lowercased())
                )
            }
        }

        var snapshot = Snapshot()
        let rootTracks = tracks(in: root, playlist: "")
        snapshot.tracks = rootTracks

        var playlists: [Playlist] = []
        for folder in contents(of: root) {
            // Ordner sind Playlists – Programme und andere Pakete (z. B. „Velvet.app“) nicht.
            guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                  values.isDirectory == true, values.isPackage != true,
                  !ignoredFolders.contains(folder.lastPathComponent) else { continue }
            let folderTracks = tracks(in: folder, playlist: folder.lastPathComponent)
            snapshot.tracks += folderTracks
            playlists.append(Playlist(url: folder, name: folder.lastPathComponent, trackCount: folderTracks.count, isRoot: false))
        }
        playlists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !rootTracks.isEmpty || playlists.isEmpty {
            playlists.insert(Playlist(url: root, name: "", trackCount: rootTracks.count, isRoot: true), at: 0)
        }
        snapshot.playlists = playlists
        return snapshot
    }

    // MARK: - Namen

    /// Entfernt Zeichen, die auf Sticks (FAT32/exFAT) oder im Auto Probleme machen.
    static func sanitizedName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var cleaned = name.components(separatedBy: forbidden).joined(separator: "-")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces)
    }

    /// „Titel.mp3“ → „Titel 2.mp3“, falls schon vorhanden.
    static func uniqueURL(_ url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    // MARK: - Ändern

    enum FileError: LocalizedError {
        case invalidName
        case alreadyExists(String)

        var errorDescription: String? {
            switch self {
            case .invalidName: return "Bitte gib einen gültigen Namen ein."
            case let .alreadyExists(name): return "„\(name)“ gibt es hier schon."
            }
        }
    }

    static func createFolder(named name: String, in root: URL) throws -> URL {
        let cleaned = sanitizedName(name)
        guard !cleaned.isEmpty else { throw FileError.invalidName }
        let url = root.appendingPathComponent(cleaned, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw FileError.alreadyExists(cleaned) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Benennt eine Datei (Endung bleibt) oder einen Ordner um.
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let cleaned = sanitizedName(newName)
        guard !cleaned.isEmpty else { throw FileError.invalidName }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let ext = url.pathExtension
        let name = isDirectory || ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
        let target = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: isDirectory)
        guard target.standardizedFileURL != url.standardizedFileURL else { return url }
        // Nur Groß-/Kleinschreibung geändert: auf FAT/APFS ohne Unterscheidung über einen Zwischennamen gehen.
        if target.path.lowercased() == url.path.lowercased() {
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".velvet-rename-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: temporary)
            try FileManager.default.moveItem(at: temporary, to: target)
            return target
        }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw FileError.alreadyExists(name) }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Verschiebt eine Datei in einen anderen Ordner; gleichnamige Dateien werden nicht überschrieben.
    static func move(_ url: URL, into folder: URL) throws -> URL {
        let target = uniqueURL(folder.appendingPathComponent(url.lastPathComponent))
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Auf Sticks wird endgültig gelöscht (ein Papierkorb auf dem Stick würde im Auto nur stören),
    /// auf dem Mac landet die Datei im Papierkorb.
    static func remove(_ url: URL, permanently: Bool) throws {
        if permanently {
            try FileManager.default.removeItem(at: url)
        } else {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    // MARK: - Für das Auto aufräumen

    struct CleanupReport: Sendable {
        var removedFiles = 0
        var freedBytes: Int64 = 0
    }

    /// Entfernt Mac-Begleitdateien („._Titel.mp3“, „.DS_Store“), die manche Autoradios als kaputte Titel anzeigen.
    ///
    /// `FileManager` blendet „._“-Dateien aus – deshalb wird der Ordner hier direkt mit `readdir` gelesen.
    static func cleanForCar(root: URL) -> CleanupReport {
        var report = CleanupReport()
        let skippedFolders: Set<String> = [".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems", ".velvet-temp"]
        var folders = [root.path]
        while let folder = folders.popLast() {
            for entry in rawEntries(of: folder) {
                let path = (folder as NSString).appendingPathComponent(entry.name)
                if entry.isDirectory {
                    if !skippedFolders.contains(entry.name) { folders.append(path) }
                    continue
                }
                guard entry.name == ".DS_Store" || entry.name.hasPrefix("._") else { continue }
                var info = stat()
                let size = lstat(path, &info) == 0 ? Int64(info.st_size) : 0
                if unlink(path) == 0 {
                    report.removedFiles += 1
                    report.freedBytes += size
                }
            }
        }
        return report
    }

    /// Alle Einträge eines Ordners – auch solche, die `FileManager` verbirgt.
    private static func rawEntries(of folder: String) -> [(name: String, isDirectory: Bool)] {
        guard let directory = opendir(folder) else { return [] }
        defer { closedir(directory) }
        var entries: [(name: String, isDirectory: Bool)] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { buffer in
                String(decoding: buffer.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard name != ".", name != ".." else { continue }
            var isDirectory = Int32(entry.pointee.d_type) == DT_DIR
            if Int32(entry.pointee.d_type) == DT_UNKNOWN {
                var info = stat()
                isDirectory = lstat((folder as NSString).appendingPathComponent(name), &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            }
            entries.append((name, isDirectory))
        }
        return entries
    }
}
