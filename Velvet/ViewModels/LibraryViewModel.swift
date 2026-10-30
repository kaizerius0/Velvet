import AppKit
import Foundation

/// Alle Bibliotheken: deine Ordner auf dem Mac und jeder eingesteckte Stick.
/// Sticks erscheinen und verschwinden automatisch, Ordner auf dem Mac holst du selbst in die Seitenleiste.
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
    /// Die Ordner auf dem Mac in der Seitenleiste.
    @Published private(set) var macFolders: [URL]

    private let history: HistoryStore
    private let defaults: UserDefaults
    private static let macFoldersKey = "macFolders"
    private var observers: [NSObjectProtocol] = []
    private var scanTasks: [String: Task<Void, Never>] = [:]
    private var noticeTask: Task<Void, Never>?

    init(history: HistoryStore, defaults: UserDefaults = .standard, macFolders: [URL]? = nil) {
        self.history = history
        self.defaults = defaults
        self.macFolders = (macFolders ?? Self.storedMacFolders(in: defaults)).map(\.standardizedFileURL)
        if macFolders == nil { saveMacFolders() }
        observeVolumes()
        refreshSources(announceNewSticks: false)
    }

    private static func storedMacFolders(in defaults: UserDefaults) -> [URL] {
        if let paths = defaults.stringArray(forKey: macFoldersKey) {
            return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        // Bis Velvet 1.2 gab es genau einen Musikordner auf dem Mac: Er kommt mit seinen
        // Unterordnern (sofern darin Musik liegt) als eigene Ordner in die Seitenleiste.
        guard let old = oldMacFolder(in: defaults),
              FileManager.default.fileExists(atPath: old.path) else { return [] }
        return [old] + LibraryFiles.subfolders(of: old).filter(LibraryFiles.containsMedia)
    }

    private static func oldMacFolder(in defaults: UserDefaults) -> URL? {
        if let path = defaults.string(forKey: "macLibraryPath") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        struct OldLocation: Decodable { let path: String; let isExternal: Bool }
        if let data = defaults.data(forKey: "libraryLocation"),
           let old = try? JSONDecoder().decode(OldLocation.self, from: data), !old.isExternal {
            return URL(fileURLWithPath: old.path, isDirectory: true)
        }
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("Velvet", isDirectory: true)
    }

    private func saveMacFolders() {
        defaults.set(macFolders.map(\.path), forKey: Self.macFoldersKey)
    }

    // MARK: Quellen

    var volumes: [VolumeInfo] { sources.compactMap(\.volume) }

    func source(id: String) -> LibrarySource? {
        sources.first { $0.id == id }
    }

    /// Die Bibliothek, in der eine Datei oder ein Ordner liegt.
    func source(containing url: URL) -> LibrarySource? {
        let path = url.standardizedFileURL.path
        var best: (source: LibrarySource, length: Int)?
        for source in sources {
            for root in source.roots {
                let rootPath = root.standardizedFileURL.path
                guard path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") else { continue }
                if rootPath.count > best?.length ?? -1 { best = (source, rootPath.count) }
            }
        }
        return best?.source
    }

    func refreshSources(announceNewSticks: Bool = true) {
        let mac = LibrarySource(id: LibrarySource.macID, name: "Dieser Mac", roots: macFolders, volume: nil)
        let sticks = VolumeService.externalVolumes().map {
            LibrarySource(id: $0.id, name: $0.name, roots: [$0.url], volume: $0)
        }
        let updated = [mac] + sticks
        let changed = updated.filter { new in
            !sources.contains { $0.id == new.id && $0.roots == new.roots }
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

    // MARK: Ordner auf dem Mac

    func isMacFolder(_ url: URL) -> Bool {
        macFolders.contains { Self.samePath($0, url) }
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// Holt einen Ordner in die Seitenleiste. Ordner auf Sticks stehen dort ohnehin.
    func addMacFolder(_ url: URL) {
        guard !isMacFolder(url), !isOnStick(url) else { return }
        macFolders.append(url.standardizedFileURL)
        saveMacFolders()
        refreshSources(announceNewSticks: false)
    }

    /// Nimmt einen Ordner aus der Seitenleiste – die Dateien bleiben, wo sie sind.
    func removeMacFolder(_ url: URL) {
        macFolders.removeAll { Self.samePath($0, url) }
        saveMacFolders()
        refreshSources(announceNewSticks: false)
    }

    private func replaceMacFolder(_ old: URL, with new: URL) {
        guard let index = macFolders.firstIndex(where: { Self.samePath($0, old) }) else { return }
        macFolders[index] = new.standardizedFileURL
        saveMacFolders()
        refreshSources(announceNewSticks: false)
    }

    func isOnStick(_ url: URL) -> Bool {
        source(containing: url)?.isExternal ?? (VolumeService.volume(containing: url)?.isExternal ?? false)
    }

    /// Ein vorhandener Ordner – auf dem Mac oder einem Stick. Ordner auf dem Mac kommen in die Seitenleiste.
    func chooseFolder(title: String = "Ordner wählen", prompt: String = "Auswählen", startingAt start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = start ?? macFolders.last?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        addMacFolder(url)
        return url
    }

    /// „Neuer Ordner …“ auf dem Mac: Ort und Namen wählen.
    func createMacFolder() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Neuer Ordner"
        panel.prompt = "Erstellen"
        panel.nameFieldLabel = "Name:"
        panel.nameFieldStringValue = "Neuer Ordner"
        panel.canCreateDirectories = true
        panel.directoryURL = macFolders.last?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Gibt es den Ordner schon, kommt er einfach in die Seitenleiste.
        if FileManager.default.fileExists(atPath: url.path) {
            addMacFolder(url)
            return url
        }
        return createFolder(named: url.lastPathComponent, in: url.deletingLastPathComponent())?.url
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

    func folders(in sourceID: String) -> [LibraryFolder] {
        snapshots[sourceID]?.folders ?? []
    }

    func folder(id: String, in sourceID: String) -> LibraryFolder? {
        folders(in: sourceID).first { $0.id == id }
    }

    /// Titel eines Ordners – oder alle Titel der Bibliothek (`folderID == nil`).
    func tracks(in sourceID: String, folderID: String? = nil) -> [Track] {
        let all = snapshots[sourceID]?.tracks ?? []
        guard let folderID else { return all }
        return all.filter { $0.folderID == folderID }
    }

    func isScanning(_ sourceID: String) -> Bool {
        scanning.contains(sourceID)
    }

    func rescan(_ sourceID: String) {
        guard let source = source(id: sourceID) else { return }
        let roots = source.roots
        let volumeName = source.volume?.name
        scanTasks[sourceID]?.cancel()
        scanning.insert(sourceID)
        scanTasks[sourceID] = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                if let volumeName, let root = roots.first { return LibraryFiles.scanVolume(root: root, name: volumeName) }
                return LibraryFiles.scan(folders: roots)
            }.value
            guard let self, !Task.isCancelled, self.source(id: sourceID)?.roots == roots else { return }
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
        sources[index] = LibrarySource(id: source.id, name: source.name, roots: source.roots, volume: fresh)
    }

    // MARK: Orte

    /// „AUTO-STICK › Rock“, direkt auf dem Stick „AUTO-STICK“, auf dem Mac nur der Ordnername.
    func locationText(for file: URL) -> String {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        guard let source = source(containing: file), let volume = source.volume else { return folder.lastPathComponent }
        if folder == volume.url.standardizedFileURL { return source.name }
        return "\(source.name) › \(folder.lastPathComponent)"
    }

    /// „AUTO-STICK › Rock“ für einen Ordner.
    func locationText(forFolder folder: URL) -> String {
        locationText(for: folder.appendingPathComponent("_"))
    }

    /// Auf Sticks wird endgültig gelöscht, auf dem Mac in den Papierkorb gelegt.
    func deletesPermanently(at url: URL) -> Bool {
        isOnStick(url)
    }

    // MARK: Ordner

    /// Legt einen Ordner an – auf dem Stick oder dem Mac. Auf dem Mac kommt er in die Seitenleiste.
    @discardableResult
    func createFolder(named name: String, in parent: URL) -> LibraryFolder? {
        do {
            let url = try LibraryFiles.createFolder(named: name, in: parent)
            if isOnStick(url) {
                refreshIfAffected(by: url)
            } else {
                addMacFolder(url)
            }
            return LibraryFolder(url: url, name: url.lastPathComponent, trackCount: 0, isVolumeRoot: false)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Gibt die neue Ordner-ID zurück, damit die Auswahl folgen kann.
    @discardableResult
    func rename(_ folder: LibraryFolder, to name: String) -> String? {
        guard !folder.isVolumeRoot else { return nil }
        var newID: String?
        perform(at: folder.url) {
            let renamed = try LibraryFiles.rename(folder.url, to: name)
            history.updatePaths(from: folder.url, to: renamed)
            replaceMacFolder(folder.url, with: renamed)
            newID = renamed.standardizedFileURL.path
        }
        return newID
    }

    func delete(_ folder: LibraryFolder) {
        guard !folder.isVolumeRoot else { return }
        let files = trackIndex.map(\.track).filter { $0.folderID == folder.id }
        let permanently = deletesPermanently(at: folder.url)
        perform(at: folder.url) {
            try LibraryFiles.remove(folder.url, permanently: permanently)
            files.forEach { history.markRemoved($0.url, state: .deleted) }
            removeMacFolder(folder.url)
            showNotice("„\(folder.name)“ gelöscht")
        }
    }

    // MARK: Titel

    func rename(_ track: Track, to name: String) {
        perform(at: track.url) {
            let renamed = try LibraryFiles.rename(track.url, to: name)
            history.updatePaths(from: track.url, to: renamed)
        }
    }

    func move(_ selection: [Track], to folder: LibraryFolder) {
        perform(at: folder.url) {
            for track in selection where track.folderID != folder.id {
                let moved = try LibraryFiles.move(track.url, into: folder.url)
                history.updatePaths(from: track.url, to: moved)
            }
            showNotice("\(Formatters.count(selection.count, "Titel", "Titel")) nach „\(folder.name)“ verschoben")
        }
    }

    /// Kopiert Titel in einen Ordner einer anderen Bibliothek, z. B. vom Mac auf den Stick.
    func copy(_ selection: [Track], to folder: LibraryFolder) {
        perform(at: folder.url) {
            for track in selection {
                let target = LibraryFiles.uniqueURL(folder.url.appendingPathComponent(track.url.lastPathComponent))
                try FileManager.default.copyItem(at: track.url, to: target)
            }
            showNotice("\(Formatters.count(selection.count, "Titel", "Titel")) nach „\(locationText(forFolder: folder.url))“ kopiert")
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

    // MARK: Stick

    /// Entfernt „._“-Dateien und „.DS_Store“, die Autoradios als kaputte Titel anzeigen.
    func cleanForCar(_ sourceID: String) async {
        guard let root = source(id: sourceID)?.volume?.url else { return }
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
