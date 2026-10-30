import AppKit
import Foundation

/// Die Bibliothek: ein Stick oder Ordner, dessen Unterordner Playlists sind.
/// Merkt sich den gewählten Stick und findet ihn beim nächsten Einstecken automatisch wieder.
@MainActor
final class LibraryViewModel: ObservableObject {
    enum Status: Equatable {
        case none
        case offline(String)
        case ready
    }

    static let allTracksID = "__all__"

    @Published private(set) var volumes: [VolumeInfo] = []
    @Published private(set) var location: LibraryLocation?
    @Published private(set) var rootURL: URL?
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isScanning = false
    /// Erhöht sich nach jedem Einlesen.
    @Published private(set) var revision = 0
    @Published var selectedPlaylistID = LibraryViewModel.allTracksID
    @Published var errorMessage: String?
    @Published var notice: String?

    /// Titel mit vorberechneten Suchwörtern – für die Duplikat-Erkennung.
    private(set) var trackIndex: [(track: Track, tokens: Set<String>)] = []

    private let history: HistoryStore
    private let defaults: UserDefaults
    private let locationKey = "libraryLocation"
    private var observers: [NSObjectProtocol] = []
    private var scanTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    init(history: HistoryStore, defaults: UserDefaults = .standard) {
        self.history = history
        self.defaults = defaults
        if let data = defaults.data(forKey: locationKey) {
            location = try? JSONDecoder().decode(LibraryLocation.self, from: data)
        }
        observeVolumes()
        refreshVolumes()
    }

    // MARK: Zustand

    var status: Status {
        guard let location else { return .none }
        return rootURL == nil ? .offline(location.displayName) : .ready
    }

    /// Laufwerk der Bibliothek (für freien Speicher und Auswerfen).
    var volume: VolumeInfo? {
        guard let rootURL else { return nil }
        return VolumeService.volume(containing: rootURL)
    }

    var isExternal: Bool { location?.isExternal ?? false }

    /// Auf Sticks wird endgültig gelöscht, auf dem Mac in den Papierkorb gelegt.
    var deletesPermanently: Bool { isExternal }

    var selectedPlaylist: Playlist? {
        playlists.first { $0.id == selectedPlaylistID }
    }

    var visibleTracks: [Track] {
        guard selectedPlaylistID != Self.allTracksID else { return tracks }
        return tracks.filter { $0.folderID == selectedPlaylistID }
    }

    /// Echte Unterordner (ohne Hauptordner).
    var folderPlaylists: [Playlist] {
        playlists.filter { !$0.isRoot }
    }

    func contains(_ url: URL) -> Bool {
        guard let root = rootURL?.standardizedFileURL.path else { return false }
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    /// „AUTO-STICK › Rock“
    func locationText(for file: URL) -> String {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        let name = location?.shortName ?? folder.lastPathComponent
        if folder == rootURL?.standardizedFileURL { return "\(name) › Hauptordner" }
        return "\(name) › \(folder.lastPathComponent)"
    }

    // MARK: Laufwerk wählen

    func refreshVolumes() {
        volumes = VolumeService.externalVolumes()
        resolveRoot()
    }

    func use(volume: VolumeInfo) {
        use(folder: volume.url)
    }

    func use(folder url: URL) {
        let volume = VolumeService.volume(containing: url)
        let external = volume?.isExternal ?? false
        let newLocation = LibraryLocation(
            path: url.path,
            volumeUUID: external ? volume?.uuid : nil,
            relativePath: volume.map { VolumeService.relativePath(of: url, in: $0) } ?? "",
            volumeName: volume?.name ?? url.lastPathComponent,
            isExternal: external,
            folderName: url.lastPathComponent
        )
        location = newLocation
        defaults.set(try? JSONEncoder().encode(newLocation), forKey: locationKey)
        selectedPlaylistID = Self.allTracksID
        rootURL = nil
        resolveRoot()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Bibliothek wählen"
        panel.message = "Wähle den Stick oder Ordner, den Velvet verwalten soll. Unterordner werden zu Playlists."
        panel.prompt = "Verwalten"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(folder: url)
    }

    private func resolveRoot() {
        let resolved = location.flatMap(resolve)
        guard resolved?.standardizedFileURL != rootURL?.standardizedFileURL else { return }
        rootURL = resolved
        if resolved == nil {
            scanTask?.cancel()
            playlists = []
            tracks = []
            trackIndex = []
            isScanning = false
            revision += 1
        } else {
            rescan()
        }
    }

    private func resolve(_ location: LibraryLocation) -> URL? {
        var url = URL(fileURLWithPath: location.path, isDirectory: true)
        if let uuid = location.volumeUUID {
            guard let volume = volumes.first(where: { $0.uuid == uuid }) else { return nil }
            url = location.relativePath.isEmpty ? volume.url : volume.url.appendingPathComponent(location.relativePath, isDirectory: true)
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
    }

    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshVolumes() }
            })
        }
    }

    // MARK: Einlesen

    func rescan() {
        guard let root = rootURL else { return }
        scanTask?.cancel()
        isScanning = true
        scanTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) { LibraryFiles.scan(root: root) }.value
            guard let self, !Task.isCancelled, self.rootURL == root else { return }
            self.playlists = snapshot.playlists
            self.tracks = snapshot.tracks
            self.trackIndex = snapshot.tracks.map { ($0, TitleMatcher.tokens($0.title)) }
            if self.selectedPlaylistID != Self.allTracksID, !snapshot.playlists.contains(where: { $0.id == self.selectedPlaylistID }) {
                self.selectedPlaylistID = Self.allTracksID
            }
            self.volumes = VolumeService.externalVolumes()
            self.isScanning = false
            self.revision += 1
        }
    }

    /// Nach einem Download: neu einlesen, falls die Datei in der Bibliothek gelandet ist.
    func refreshIfAffected(by url: URL) {
        if contains(url) { rescan() }
    }

    // MARK: Playlists

    /// Ordner für eine Playlist (wird bei Bedarf angelegt). `nil`-Name = Hauptordner.
    func folder(forPlaylist name: String?) -> URL? {
        guard let root = rootURL else { return nil }
        guard let name, !name.isEmpty else { return root }
        let url = root.appendingPathComponent(LibraryFiles.sanitizedName(name), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func createPlaylist(named name: String) -> Playlist? {
        guard let root = rootURL else { return nil }
        do {
            let url = try LibraryFiles.createFolder(named: name, in: root)
            rescan()
            showNotice("Playlist „\(url.lastPathComponent)“ angelegt.")
            return Playlist(url: url, name: url.lastPathComponent, trackCount: 0, isRoot: false)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func rename(_ playlist: Playlist, to name: String) {
        guard !playlist.isRoot else { return }
        perform {
            let renamed = try LibraryFiles.rename(playlist.url, to: name)
            history.updatePaths(from: playlist.url, to: renamed)
            if selectedPlaylistID == playlist.id { selectedPlaylistID = renamed.standardizedFileURL.path }
        }
    }

    func delete(_ playlist: Playlist) {
        guard !playlist.isRoot else { return }
        let files = tracks.filter { $0.folderID == playlist.id }
        perform {
            try LibraryFiles.remove(playlist.url, permanently: deletesPermanently)
            files.forEach { history.markRemoved($0.url, state: .deleted) }
            showNotice("Playlist „\(playlist.name)“ gelöscht.")
        }
    }

    // MARK: Titel

    func rename(_ track: Track, to name: String) {
        perform {
            let renamed = try LibraryFiles.rename(track.url, to: name)
            history.updatePaths(from: track.url, to: renamed)
        }
    }

    func move(_ selection: [Track], to playlist: Playlist) {
        perform {
            for track in selection where track.folderID != playlist.id {
                let moved = try LibraryFiles.move(track.url, into: playlist.url)
                history.updatePaths(from: track.url, to: moved)
            }
            showNotice("\(Formatters.count(selection.count, "Titel", "Titel")) nach „\(playlist.displayName)“ verschoben.")
        }
    }

    func delete(_ selection: [Track]) {
        perform {
            for track in selection {
                try LibraryFiles.remove(track.url, permanently: deletesPermanently)
                history.markRemoved(track.url, state: .deleted)
            }
            showNotice("\(Formatters.count(selection.count, "Titel", "Titel")) gelöscht.")
        }
    }

    func play(_ track: Track) {
        NSWorkspace.shared.open(track.url)
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func revealRoot() {
        guard let rootURL else { return }
        NSWorkspace.shared.open(rootURL)
    }

    // MARK: Stick

    /// Entfernt „._“-Dateien und „.DS_Store“, die Autoradios als kaputte Titel anzeigen.
    func cleanForCar() async {
        guard let root = volume?.isExternal == true ? volume?.url : rootURL else { return }
        let report = await Task.detached(priority: .userInitiated) { LibraryFiles.cleanForCar(root: root) }.value
        showNotice(report.removedFiles == 0
            ? "Alles sauber – keine Mac-Begleitdateien gefunden."
            : "\(Formatters.count(report.removedFiles, "Mac-Begleitdatei", "Mac-Begleitdateien")) entfernt (\(Formatters.bytes(report.freedBytes))).")
        rescan()
    }

    func eject() async {
        guard let volume, volume.isExternal else { return }
        do {
            try await VolumeService.eject(volume)
            showNotice("„\(volume.name)“ wurde ausgeworfen – du kannst den Stick jetzt abziehen.")
        } catch {
            errorMessage = "„\(volume.name)“ konnte nicht ausgeworfen werden: \(error.localizedDescription)"
        }
        refreshVolumes()
    }

    // MARK: Intern

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
        rescan()
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
