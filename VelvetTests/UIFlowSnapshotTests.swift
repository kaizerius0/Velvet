import AppKit
import SwiftUI
import XCTest
@testable import Velvet

/// Spielt einen kompletten Ablauf über die echten ViewModels durch (mit echten Downloads)
/// und speichert Bildschirmfotos aller Bereiche (hell und dunkel). Läuft nur mit `VELVET_SNAPSHOT_DIR=/pfad`:
///   TEST_RUNNER_VELVET_SNAPSHOT_DIR=/tmp/velvet-shots xcodebuild test -scheme Velvet -only-testing:VelvetTests/UIFlowSnapshotTests
@MainActor
final class UIFlowSnapshotTests: XCTestCase {
    private var outputDirectory: URL!
    private var root: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELVET_SNAPSHOT_DIR"] else {
            throw XCTSkip("Snapshot-Test deaktiviert (VELVET_SNAPSHOT_DIR setzen).")
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // Eine kleine „Stick“-Bibliothek mit zwei Playlists.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AUTO-STICK-\(UUID().uuidString.prefix(6))", isDirectory: true)
        for folder in ["Rock", "Party"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["Rock/Toto - Africa (Official HD Video).mp3", "Rock/Queen - Bohemian Rhapsody.mp3",
                     "Party/Daft Punk - Get Lucky.mp3", "Party/a-ha - Take On Me.mp4"] {
            try Data(count: 3_400_000).write(to: root.appendingPathComponent(file))
        }
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testCompleteFlow() async throws {
        let defaults = UserDefaults(suiteName: "velvet-snapshot-tests")!
        defaults.removePersistentDomain(forName: "velvet-snapshot-tests")
        defer { defaults.removePersistentDomain(forName: "velvet-snapshot-tests") }

        let settings = AppSettings(defaults: defaults)
        settings.format = .audio
        let tools = ToolManager()
        await tools.prepare(autoUpdate: false)
        XCTAssertTrue(tools.isReady, "\(tools.state)")

        let input = InputViewModel()
        let history = HistoryStore(fileURL: root.appendingPathComponent(".history-test.json"))
        let library = LibraryViewModel(history: history, defaults: defaults)
        let navigation = AppNavigation()
        let queue = QueueViewModel(settings: settings, tools: tools, history: history, library: library)
        func screen() -> some View {
            ContentView()
                .environmentObject(settings)
                .environmentObject(tools)
                .environmentObject(input)
                .environmentObject(queue)
                .environmentObject(history)
                .environmentObject(library)
                .environmentObject(navigation)
        }

        library.use(folder: root)
        try await waitUntil("Bibliothek eingelesen") { library.revision > 0 && !library.isScanning }
        XCTAssertEqual(library.tracks.count, 4)
        settings.downloadTarget = .playlist("Neu geladen")

        // 1. Eingabe: unordentliche Liste, zwei Titel liegen schon (ähnlich) auf dem Stick
        input.text = """
        Meine Party-Playlist:
        1. Queen – Bohemian Rhapsody
        2) toto africa extended
        • Me at the zoo 🎵 (0:19)
        https://youtu.be/jNQXAC9IVRw?si=abc
        """
        let parsed = input.parseNow()
        let hits = DuplicateChecker(library: library, history: history).hits(for: parsed.entries)
        XCTAssertEqual(hits[0]?.strength, .exact)
        XCTAssertEqual(hits[1]?.strength, .similar)
        XCTAssertNil(hits[2])
        try await snapshot(screen(), "1-eingabe", dark: false)
        try await snapshot(screen(), "1-eingabe-dunkel", dark: true)

        // 2. Start in die Playlist „Neu geladen“ – Queen ist schon da und wird übersprungen
        let destination = try XCTUnwrap(library.folder(forPlaylist: "Neu geladen"))
        let existing = hits.filter { $0.value.strength == .exact && $0.value.inCurrentLibrary }.mapValues(\.location)
        queue.start(entries: parsed.entries, destination: destination, existing: existing)
        XCTAssertEqual(queue.items[0].status, .skipped(.inLibrary(hits[0]!.location)))
        try await waitUntil("Suchergebnisse") { queue.summary.needsAttention == 2 }
        try await snapshot(screen(), "2-auswahl", dark: false)

        // 3. Auswahl per Klick, Rest überspringen
        let zoo = queue.items[2]
        let target = try XCTUnwrap(zoo.candidates.first { $0.id == "jNQXAC9IVRw" } ?? zoo.candidates.first)
        queue.choose(target, for: zoo)
        queue.skip(queue.items[1])
        try await waitUntil("Downloads fertig", timeout: 240) { queue.isFinished }
        try await snapshot(screen(), "3-fertig", dark: true)
        XCTAssertGreaterThanOrEqual(history.entries.count, 1)

        // 4. Bibliothek: neue Playlist mit dem geladenen Titel
        try await waitUntil("Bibliothek aktualisiert") { library.tracks.count == 5 && !library.isScanning }
        let downloaded = try XCTUnwrap(library.tracks.first { $0.playlistName == "Neu geladen" })
        navigation.section = .library
        library.selectedPlaylistID = LibraryViewModel.allTracksID
        try await snapshot(screen(), "4-bibliothek", dark: false)
        try await snapshot(screen(), "4-bibliothek-dunkel", dark: true)

        // 5. Austauschen: dieselbe Datei durch eine neu geladene Version ersetzen
        let replace = ReplaceViewModel(track: downloaded, tools: try XCTUnwrap(tools.paths), settings: settings, library: library, history: history)
        replace.useLink("https://www.youtube.com/watch?v=jNQXAC9IVRw")
        try await waitUntil("Austauschen", timeout: 180) {
            if case .done = replace.phase { return true }
            if case .failed = replace.phase { return true }
            return false
        }
        XCTAssertEqual(replace.phase, .done("Me at the zoo"))
        let replaced = try XCTUnwrap(library.tracks.first { $0.playlistName == "Neu geladen" })
        XCTAssertGreaterThan(replaced.size, 100_000, "neue Datei sollte ein echtes MP3 sein")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".velvet-temp").path))
        XCTAssertTrue(history.entries.contains { $0.state == .replaced })

        // 6. Verlauf
        navigation.section = .history
        try await snapshot(screen(), "5-verlauf", dark: false)

        // Die Seitenleiste zeichnet macOS als „Glas“ – das erfasst der Schnappschuss im Fenster nicht, daher einzeln.
        let sidebar = Sidebar()
            .environmentObject(settings).environmentObject(tools).environmentObject(input).environmentObject(queue)
            .environmentObject(history).environmentObject(library).environmentObject(navigation)
            .background(Color(nsColor: .windowBackgroundColor))
        try await snapshot(sidebar, "6-seitenleiste", dark: false, size: CGSize(width: 250, height: 700))

        queue.reset()
        XCTAssertFalse(queue.hasRun)
    }

    // MARK: Hilfen

    private func waitUntil(_ what: String, timeout: TimeInterval = 120, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Zeitüberschreitung: \(what)") }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func snapshot<V: View>(_ view: V, _ name: String, dark: Bool, size: CGSize = CGSize(width: 1320, height: 880)) async throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        // Zeit für Layout und das Nachladen der Vorschaubilder
        try await Task.sleep(nanoseconds: 2_500_000_000)
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}
