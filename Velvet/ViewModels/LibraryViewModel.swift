import AppKit
import Foundation

/// Alle Bibliotheken: der Musikordner auf dem Mac und jeder eingesteckte Stick.
/// Unterordner sind Playlists; Sticks erscheinen und verschwinden automatisch.
@MainActor
final class LibraryViewModel: ObservableObject {
    struct IndexedTrack {
        let track: Track
        let sourceID: String
        let tokens: Set<String>
    }

    @Published private(set) var sources: [LibrarySource] = []
    @Published private(set) var snapshots: [String: LibraryFiles.Snapshot] = [:]
    @Published private(set) var scanning: Set<String> = []
    /// Erhöht sich nach jedem Einlesen.
    @Published private(set) var revision = 0
    /// Ein gerade eingesteckter Stick – die Seitenleiste springt dorthin.
    @Published private(set) var newlyMountedSourceID: String?
    @Published var errorMessage: String?
    @Published var notice: String?

    /// Alle Titel mit vorberechneten Suchwörtern – für die Duplikat-Erkennung.
    private(set) var trackIndex: [IndexedTrack] = []
    private(set) var macFolder: URL

    private let history: HistoryStore
    private let defaults: UserDefaults
    private static let macFolderKey = "macLibraryPath"
    private var observers: [NSObjectProtocol] = []
    private var scanTasks: [String: Task<Void, Never>] = [:]
    private var noticeTask: Task<Void, Never>?

    init(history: HistoryStore, defaults: UserDefaults = .standard, macFolder: URL? = nil) {
        self.history = history
        self.defaults = defaults
        self.macFolder = macFolder ?? Self.storedMacFolder(in: defaults) ?? Self.defaultMacFolder
        try? FileManager.default.createDirectory(at: self.macFolder, withIntermediateDirectories: true)
        observeVolumes()
        refreshSources(announceNewSticks: false)
    }

    static var defaultMacFolder: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("Velvet", isDirectory: true)
    }

    private static func storedMacFolder(in defaults: UserDefaults) -> URL? {
        if let path = defaults.string(forKey: macFolderKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        // Velvet 1.1 merkte sich genau einen Ort – war es ein Ordner auf dem Mac, wird er übernommen.
        struct OldLocation: Decodable { let path: String; let isExternal: Bool }
        if let data = defaults.data(forKey: "libraryLocation"),
           let old = try? JSONDecoder().decode(OldLocation.self, from: data), !old.isExternal {
            return URL(fileURLWithPath: old.path, isDirectory: true)
        }
        return nil
    }

    // MARK: Quellen

    var volumes: [VolumeInfo] { sources.compactMap(\.volume) }

    func source(id: String) -> LibrarySource? {
        sources.first { $0.id == id }
    }

    /// Die Bibliothek, in der eine Datei oder ein Ordner liegt.
    func source(containing url: URL) -> LibrarySource? {
        let path = url.standardizedFileURL.path
        return sources
            .filter { path == $0.rootURL.standardizedFileURL.path || path.hasPrefix($0.rootURL.standardizedFileURL.path + "/") }
            .max { $0.rootURL.path.count < $1.rootURL.path.count }
    }

    func refreshSources(announceNewSticks: Bool = true) {
        let mac = LibrarySource(id: LibrarySource.macID, name: "Mac", rootURL: macFolder, volume: nil)
        let sticks = VolumeService.externalVolumes().map {
            LibrarySource(id: $0.id, name: $0.name, rootURL: $0.url, volume: $0)
        }
        let updated = [mac] + sticks
        let changed = updated.filter { new in
            !sources.contains { $0.id == new.id && $0.rootURL == new.rootURL }
        }
        let removedIDs = Set(sources.map(\.id)).subtracting(updated.map(\.id))

        sources = updated
        for id in removedIDs {
            scanTasks[id]?.cancel()
            snapshots[id] = nil
            scanning.remove(id)
        }
        changed.forEach { rescan($0.id) }
        if !removedIDs.isEmpty {
            rebuildIndex()
            revision += 1
        }
        if announceNewSticks, let stick = changed.last(where: \.isExternal) {
            newlyMountedSourceID = stick.id
        }
    }

    func chooseMacFolder() {
        let panel = NSOpenPanel()
        panel.title = "Musikordner wählen"
        panel.prompt = "Auswählen"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = macFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        macFolder = url
        defaults.set(url.path, forKey: Self.macFolderKey)
        refreshSources(announceNewSticks: false)
    }

    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshSources() }
            })
        }
    }

    // MARK: Inhalte

    func playlists(in sourceID: String) -> [Playlist] {
        snapshots[sourceID]?.playlists ?? []
    }

    func playlist(id: String, in sourceID: String) -> Playlist? {
        playlists(in: sourceID).first { $0.id == id }
    }

    /// Titel einer Playlist – oder alle Titel der Bibliothek (`playlistID == nil`).
    func tracks(in sourceID: String, playlistID: String? = nil) -> [Track] {
        let all = snapshots[sourceID]?.tracks ?? []
        guard let playlistID else { return all }
        return all.filter { $0.folderID == playlistID }
    }

    func isScanning(_ sourceID: String) -> Bool {
        scanning.contains(sourceID)
    }

    func rescan(_ sourceID: String) {
        guard let source = source(id: sourceID) else { return }
        let root = source.rootURL
        scanTasks[sourceID]?.cancel()
        scanning.insert(sourceID)
        scanTasks[sourceID] = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) { LibraryFiles.scan(root: root) }.value
            guard let self, !Task.isCancelled, self.source(id: sourceID)?.rootURL == root else { return }
            self.snapshots[sourceID] = snapshot
            self.scanning.remove(sourceID)
            self.updateFreeSpace(of: sourceID)
            self.rebuildIndex()
            self.revision += 1
        }
    }

    func rescanAll() {
        sources.forEach { rescan($0.id) }
    }

    /// Nach einem Download oder einer Änderung: die betroffene Bibliothek neu einlesen.
    func refreshIfAffected(by url: URL) {
        if let source = source(containing: url) { rescan(source.id) }
    }

    private func rebuildIndex() {
        trackIndex = sources.flatMap { source in
            (snapshots[source.id]?.tracks ?? []).map {
                IndexedTrack(track: $0, sourceID: source.id, tokens: TitleMatcher.tokens($0.title))
            }
        }
    }

    private func updateFreeSpace(of sourceID: String) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }),
              let volume = sources[index].volume,
              let fresh = VolumeService.info(forVolume: volume.url) else { return }
        let source = sources[index]
        sources[index] = LibrarySource(id: source.id, name: source.name, rootURL: source.rootURL, volume: fresh)
    }

    // MARK: Orte

    /// „AUTO-STICK › Rock“ bzw. „Mac › Rock“
    func locationText(for file: URL) -> String {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        guard let source = source(containing: file) else { return folder.lastPathComponent }
        if folder == source.rootURL.standardizedFileURL { return source.name }
        return "\(source.name) › \(folder.lastPathComponent)"
    }

    /// „AUTO-STICK › Rock“ für einen Ordner.
    func locationText(forFolder folder: URL) -> String {
        locationText(for: folder.appendingPathComponent("_"))
    }

    /// Auf Sticks wird endgültig gelöscht, auf dem Mac in den Papierkorb gelegt.
    func deletesPermanently(at url: URL) -> Bool {
        source(containing: url)?.isExternal ?? (VolumeService.volume(containing: url)?.isExternal ?? false)
    }

    /// Ordner einer Playlist (wird bei Bedarf angelegt). Ohne Namen: Hauptordner der Bibliothek.
    func folder(forPlaylist name: String?, in sourceID: String) -> URL? {
        guard let root = source(id: sourceID)?.rootURL else { return nil }
        guard let name, !name.isEmpty else { return root }
        let url = root.appendingPathComponent(LibraryFiles.sanitizedName(name), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(named name: String, in sourceID: String) -> Playlist? {
        guard let root = source(id: sourceID)?.rootURL else { return nil }
        do {
            let url = try LibraryFiles.createFolder(named: name, in: root)
            rescan(sourceID)
            return Playlist(url: url, name: url.lastPathComponent, trackCount: 0, isRoot: false)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Gibt die neue Playlist-ID zurück, damit die Auswahl folgen kann.
    @discardableResult
    func rename(_ playlist: Playlist, to name: String) -> String? {
        guard !playlist.isRoot else { return nil }
        var newID: String?
        perform(at: playlist.url) {
            let renamed = try LibraryFiles.rename(playlist.url, to: name)
            history.updatePaths(from: playlist.url, to: renamed)
            newID = renamed.standardizedFileURL.path
        }
        return newID
    }

    func delete(_ playlist: Playlist) {
        guard !playlist.isRoot else { return }
        let files = trackIndex.map(\.track).filter { $0.folderID == playlist.id }
        let permanently = deletesPermanently(at: playlist.url)
        perform(at: playlist.url) {
            try LibraryFiles.remove(playlist.url, permanently: permanently)
            files.forEach { history.markRemoved($0.url, state: .deleted) }
            showNotice("„\(playlist.name)“ gelöscht")
        }
    }

    // MARK: Titel

    func rename(_ track: Track, to name: String) {
        perform(at: track.url) {
            let renamed = try LibraryFiles.rename(track.url, to: name)
            history.updatePaths(from: track.url, to: renamed)
        }
    }

    func move(_ selection: [Track], to playlist: Playlist) {
        perform(at: playlist.url) {
            for track in selection where track.folderID != playlist.id {
                let moved = try LibraryFiles.move(track.url, into: playlist.url)
                history.updatePaths(from: track.url, to: moved)
            }
            showNotice("\(Formatters.count(selection.count, "Titel", "Titel")) nach „\(playlist.displayName)“ verschoben")
        }
    }

    /// Kopiert Titel in eine Playlist einer anderen Bibliothek, z. B. vom Mac auf den Stick.
    func copy(_ selection: [Track], to playlist: Playlist) {
        perform(at: playlist.url) {
            for track in selection {
                let target = LibraryFiles.uniqueURL(playlist.url.appendingPathComponent(track.url.lastPathComponent))
                try FileManager.default.copyItem(at: track.url, to: target)
            }
            showNotice("\(Formatters.count(selection.count, "Titel", "Titel")) nach „\(locationText(forFolder: playlist.url))“ kopiert")
        }
    }

    func delete(_ selection: [Track]) {
        guard let first = selection.first else { return }
        perform(at: first.url) {
            for track in selection {
                try LibraryFiles.remove(track.url, permanently: deletesPermanently(at: track.url))
                history.markRemoved(track.url, state: .deleted)
            }
        }
    }

    func play(_ track: Track) {
        NSWorkspace.shared.open(track.url)
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func open(_ sourceID: String) {
        guard let url = source(id: sourceID)?.rootURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Stick

    /// Entfernt „._“-Dateien und „.DS_Store“, die Autoradios als kaputte Titel anzeigen.
    func cleanForCar(_ sourceID: String) async {
        guard let root = source(id: sourceID)?.rootURL else { return }
        let report = await Task.detached(priority: .userInitiated) { LibraryFiles.cleanForCar(root: root) }.value
        showNotice(report.removedFiles == 0
            ? "Keine Mac-Begleitdateien gefunden"
            : "\(Formatters.count(report.removedFiles, "Begleitdatei", "Begleitdateien")) entfernt (\(Formatters.bytes(report.freedBytes)))")
        rescan(sourceID)
    }

    func eject(_ sourceID: String) async {
        guard let volume = source(id: sourceID)?.volume else { return }
        do {
            try await VolumeService.eject(volume)
            showNotice("„\(volume.name)“ kann jetzt abgezogen werden")
        } catch {
            errorMessage = "„\(volume.name)“ konnte nicht ausgeworfen werden: \(error.localizedDescription)"
        }
        refreshSources()
    }

    // MARK: Intern

    private func perform(at url: URL, _ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshIfAffected(by: url)
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
