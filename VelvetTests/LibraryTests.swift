import XCTest
@testable import Velvet

final class TitleMatcherTests: XCTestCase {
    private func compare(_ a: String, _ b: String) -> DuplicateHit.Strength? {
        TitleMatcher.compare(TitleMatcher.tokens(a), TitleMatcher.tokens(b))
    }

    func testSameSongIsExactDespiteNoise() {
        XCTAssertEqual(compare("toto africa", "Toto - Africa (Official HD Video)"), .exact)
        XCTAssertEqual(compare("Queen – Bohemian Rhapsody", "Queen - Bohemian Rhapsody (Official Video Remastered 2011)"), .exact)
        XCTAssertEqual(compare("Beyoncé Halo", "Beyonce - Halo [Lyrics]"), .exact)
    }

    func testOtherVersionsAreOnlySimilar() {
        XCTAssertEqual(compare("Toto Africa Extended", "Toto - Africa"), .similar)
        XCTAssertEqual(compare("Queen Bohemian Rhapsody", "Queen - Bohemian Rhapsody (Live Aid 1985)"), .similar)
    }

    func testDifferentSongsDoNotMatch() {
        XCTAssertNil(compare("Queen Bohemian Rhapsody", "Queen - Don't Stop Me Now"))
        XCTAssertNil(compare("Africa", "Toto - Rosanna"))
        // Ein einzelnes Wort reicht nur bei exakter Übereinstimmung.
        XCTAssertNil(compare("Queen", "Queen - Bohemian Rhapsody"))
    }
}

final class LibraryFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("velvet-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Rock"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Party"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("System Volume Information"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Velvet.app/Contents"), withIntermediateDirectories: true)
        for path in ["Rock/Toto - Africa.mp3", "Rock/Queen - Bohemian Rhapsody.mp3", "Party/Daft Punk - Get Lucky.mp4",
                     "Einzeln.mp3", "Rock/notizen.txt", "Rock/._Toto - Africa.mp3", ".DS_Store", "Rock/.DS_Store"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(path))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testStickScanFindsFoldersAndMediaOnly() {
        let snapshot = LibraryFiles.scanVolume(root: root, name: "AUTO-STICK")
        // Der Stick selbst heißt wie der Stick – keinen „Hauptordner“.
        XCTAssertEqual(snapshot.folders.map(\.name), ["AUTO-STICK", "Party", "Rock"])
        XCTAssertEqual(snapshot.folders.map(\.isVolumeRoot), [true, false, false])
        XCTAssertEqual(snapshot.folders.first { $0.name == "Rock" }?.trackCount, 2)
        XCTAssertEqual(Set(snapshot.tracks.map(\.title)), ["Toto - Africa", "Queen - Bohemian Rhapsody", "Daft Punk - Get Lucky", "Einzeln"])
        XCTAssertEqual(snapshot.tracks.first { $0.title == "Einzeln" }?.folderName, "AUTO-STICK")
        XCTAssertEqual(snapshot.tracks.first { $0.title == "Daft Punk - Get Lucky" }?.isAudio, false)
    }

    func testMacScanReadsOnlyChosenFolders() {
        let snapshot = LibraryFiles.scan(folders: [root.appendingPathComponent("Rock"), root.appendingPathComponent("Gibt es nicht")])
        XCTAssertEqual(snapshot.folders.map(\.name), ["Rock"])
        XCTAssertEqual(Set(snapshot.tracks.map(\.title)), ["Toto - Africa", "Queen - Bohemian Rhapsody"])
        XCTAssertEqual(Set(snapshot.tracks.map(\.folderName)), ["Rock"])
    }

    func testRenameMoveAndRemove() throws {
        let africa = root.appendingPathComponent("Rock/Toto - Africa.mp3")
        let renamed = try LibraryFiles.rename(africa, to: "Toto - Africa (Extended)")
        XCTAssertEqual(renamed.lastPathComponent, "Toto - Africa (Extended).mp3")

        // Gleichnamige Datei im Ziel wird nicht überschrieben.
        try Data("y".utf8).write(to: root.appendingPathComponent("Party/Toto - Africa (Extended).mp3"))
        let moved = try LibraryFiles.move(renamed, into: root.appendingPathComponent("Party"))
        XCTAssertEqual(moved.lastPathComponent, "Toto - Africa (Extended) 2.mp3")

        try LibraryFiles.remove(moved, permanently: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.path))

        XCTAssertThrowsError(try LibraryFiles.createFolder(named: "Rock", in: root))
        XCTAssertEqual(try LibraryFiles.createFolder(named: "Chill: Abend/Nacht", in: root).lastPathComponent, "Chill- Abend-Nacht")
    }

    func testCleanForCarRemovesOnlyMacMetadata() {
        let report = LibraryFiles.cleanForCar(root: root)
        XCTAssertEqual(report.removedFiles, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Rock/._Toto - Africa.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Rock/Toto - Africa.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Rock/notizen.txt").path))
    }
}

@MainActor
final class HistoryAndDuplicateTests: XCTestCase {
    private var root: URL!
    private var historyFile: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("velvet-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Rock"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("Rock/Toto - Africa (Official HD Video).mp3"))
        historyFile = root.appendingPathComponent("history.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testHistoryRecordsMovesAndPersists() async throws {
        let file = root.appendingPathComponent("Rock/Toto - Africa (Official HD Video).mp3")
        let store = HistoryStore(fileURL: historyFile)
        store.recordDownload(title: "Toto - Africa (Official HD Video)", query: "toto africa", videoID: "FTQbiNvZqaY",
                             sourceURL: YouTubeLink.watchURL("FTQbiNvZqaY"), file: file)
        XCTAssertEqual(store.entries.first?.folderName, "Rock")
        XCTAssertTrue(store.availability(of: store.entries[0], volumes: []).isPresent)

        let moved = root.appendingPathComponent("Party/Toto - Africa (Official HD Video).mp3")
        store.updatePaths(from: root.appendingPathComponent("Rock"), to: root.appendingPathComponent("Party"))
        XCTAssertEqual(store.entries.first?.path, moved.path)
        XCTAssertEqual(store.entries.first?.folderName, "Party")

        store.markRemoved(moved, state: .replaced, note: "Ersetzt durch „Africa (Extended)“")
        XCTAssertEqual(store.availability(of: store.entries[0], volumes: []), .replaced("Ersetzt durch „Africa (Extended)“"))

        store.saveNow()
        let reloaded = HistoryStore(fileURL: historyFile)
        XCTAssertEqual(reloaded.entries, store.entries)
    }

    func testDuplicatesInLibraryAndHistory() async throws {
        let defaults = UserDefaults(suiteName: "velvet-library-tests-\(UUID().uuidString)")!
        let history = HistoryStore(fileURL: historyFile)
        let library = LibraryViewModel(history: history, defaults: defaults, macFolders: [root.appendingPathComponent("Rock")])
        try await waitForScan(library)
        XCTAssertEqual(library.tracks(in: LibrarySource.macID).count, 1)
        XCTAssertEqual(library.locationText(for: root.appendingPathComponent("Rock/x.mp3")), "Rock")

        // Ein Video, das woanders auf dem Mac liegt (laut Verlauf).
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("velvet-elsewhere-\(UUID().uuidString).mp3")
        try Data("x".utf8).write(to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        history.recordDownload(title: "Rick Astley - Never Gonna Give You Up", query: nil, videoID: "dQw4w9WgXcQ",
                               sourceURL: YouTubeLink.watchURL("dQw4w9WgXcQ"), file: elsewhere)

        let entries = ListParser.parse("""
        toto africa
        Toto Africa Extended
        https://youtu.be/dQw4w9WgXcQ
        Queen Bohemian Rhapsody
        """).entries
        let checker = DuplicateChecker(library: library, history: history, sourceID: LibrarySource.macID)
        let hits = checker.hits(for: entries)

        XCTAssertEqual(hits[0]?.strength, .exact)
        XCTAssertEqual(hits[0]?.inCurrentLibrary, true)
        XCTAssertEqual(hits[0]?.location, "Rock")
        XCTAssertEqual(hits[1]?.strength, .similar)
        XCTAssertEqual(hits[2]?.strength, .exact)
        XCTAssertEqual(hits[2]?.inCurrentLibrary, false)
        XCTAssertNil(hits[3])

        // Einzelne Suchergebnisse: gleicher Titel in dieser Bibliothek → „Schon in …“
        let candidate = VideoCandidate(id: "FTQbiNvZqaY", title: "Toto - Africa (Official HD Video)", channel: "TOTO", duration: 295,
                                       viewCount: nil, thumbnailURL: nil, url: YouTubeLink.watchURL("FTQbiNvZqaY"))
        XCTAssertEqual(checker.existingLocation(of: candidate), "Rock")
        let other = VideoCandidate(id: "abcdefghijk", title: "Toto - Rosanna", channel: nil, duration: nil,
                                   viewCount: nil, thumbnailURL: nil, url: YouTubeLink.watchURL("abcdefghijk"))
        XCTAssertNil(checker.existingLocation(of: other))
    }

    func testFolderOperations() async throws {
        let defaults = UserDefaults(suiteName: "velvet-library-tests-\(UUID().uuidString)")!
        let history = HistoryStore(fileURL: historyFile)
        let rockURL = root.appendingPathComponent("Rock")
        let library = LibraryViewModel(history: history, defaults: defaults, macFolders: [rockURL])
        try await waitForScan(library)

        // Ein neuer Ordner auf dem Mac kommt in die Seitenleiste.
        let party = try XCTUnwrap(library.createFolder(named: "Party", in: root))
        XCTAssertTrue(library.isMacFolder(party.url))
        XCTAssertEqual(defaults.stringArray(forKey: "macFolders")?.count, 2)
        try await waitForRevision(library, after: library.revision)
        let africa = try XCTUnwrap(library.tracks(in: LibrarySource.macID).first)
        let before = library.revision
        library.move([africa], to: party)
        try await waitForRevision(library, after: before)
        XCTAssertEqual(library.tracks(in: LibrarySource.macID, folderID: party.id).map(\.title), ["Toto - Africa (Official HD Video)"])

        let rock = try XCTUnwrap(library.folders(in: LibrarySource.macID).first { $0.name == "Rock" })
        let moved = try XCTUnwrap(library.tracks(in: LibrarySource.macID, folderID: party.id).first)
        let beforeCopy = library.revision
        library.copy([moved], to: rock)
        try await waitForRevision(library, after: beforeCopy)
        XCTAssertEqual(library.tracks(in: LibrarySource.macID).count, 2)

        // Umbenennen: der Ordner bleibt in der Seitenleiste.
        let partyFolder = try XCTUnwrap(library.folder(id: party.id, in: LibrarySource.macID))
        let newID = try XCTUnwrap(library.rename(partyFolder, to: "Feier"))
        XCTAssertTrue(library.isMacFolder(URL(fileURLWithPath: newID)))
        XCTAssertFalse(library.isMacFolder(party.url))

        // Aus der Seitenleiste nehmen: die Dateien bleiben.
        library.removeMacFolder(URL(fileURLWithPath: newID))
        XCTAssertEqual(library.macFolders.map(\.path), [rockURL.standardizedFileURL.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: newID).appendingPathComponent("Toto - Africa (Official HD Video).mp3").path))
    }

    /// Der eine Musikordner aus Velvet 1.2 wird zu Ordnern in der Seitenleiste.
    func testOldMusicFolderBecomesFolders() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Leer"), withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "velvet-library-tests-\(UUID().uuidString)")!
        defaults.set(root.path, forKey: "macLibraryPath")
        let library = LibraryViewModel(history: HistoryStore(fileURL: historyFile), defaults: defaults)
        XCTAssertEqual(Set(library.macFolders.map(\.lastPathComponent)), [root.lastPathComponent, "Rock"])
        XCTAssertEqual(defaults.stringArray(forKey: "macFolders")?.count, 2)
    }

    private func waitForRevision(_ library: LibraryViewModel, after revision: Int) async throws {
        let deadline = Date().addingTimeInterval(10)
        while library.revision <= revision || library.isScanning(LibrarySource.macID) {
            if Date() > deadline { return XCTFail("Bibliothek wurde nicht neu eingelesen") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func waitForScan(_ library: LibraryViewModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while library.revision == 0 || library.isScanning(LibrarySource.macID) {
            if Date() > deadline { return XCTFail("Bibliothek wurde nicht eingelesen") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
