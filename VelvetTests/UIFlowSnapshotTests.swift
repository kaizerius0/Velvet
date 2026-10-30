import AppKit
import SwiftUI
import XCTest
@testable import Velvet

/// Spielt den Alltag über die echten ViewModels durch (mit echten Downloads) und speichert Bildschirmfotos.
/// Läuft nur mit `VELVET_SNAPSHOT_DIR=/pfad`:
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

        // Ein kleiner Musikordner mit zwei Playlists.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Velvet-Musik-\(UUID().uuidString.prefix(6))", isDirectory: true)
        for folder in ["Rock", "Party"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["Rock/Toto - Africa (Official HD Video).mp3", "Rock/Queen - Bohemian Rhapsody.mp3",
                     "Rock/AC-DC - Highway to Hell.mp3", "Party/Daft Punk - Get Lucky.mp3", "Party/a-ha - Take On Me.mp4"] {
            try Data(count: 3_400_000).write(to: root.appendingPathComponent(file))
        }
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testEverydayFlow() async throws {
        let defaults = UserDefaults(suiteName: "velvet-snapshot-tests")!
        defaults.removePersistentDomain(forName: "velvet-snapshot-tests")
        defer { defaults.removePersistentDomain(forName: "velvet-snapshot-tests") }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.format, .audio)
        let tools = ToolManager()
        await tools.prepare(autoUpdate: false)
        let paths = try XCTUnwrap(tools.paths, "\(tools.state)")

        let input = InputViewModel()
        input.clear()
        let history = HistoryStore(fileURL: root.appendingPathComponent(".history-test.json"))
        let library = LibraryViewModel(history: history, defaults: defaults, macFolder: root)
        let navigation = AppNavigation()
        let queue = QueueViewModel(settings: settings, tools: tools, history: history, library: library)
        let mac = LibrarySource.macID
        try await waitUntil("Bibliothek eingelesen") { library.revision > 0 && !library.isScanning(mac) }
        let rock = try XCTUnwrap(library.playlists(in: mac).first { $0.name == "Rock" })
        let party = try XCTUnwrap(library.playlists(in: mac).first { $0.name == "Party" })
        navigation.selection = .playlist(source: mac, id: rock.id)

        func environment<V: View>(_ view: V) -> some View {
            view
                .environmentObject(settings).environmentObject(tools).environmentObject(input)
                .environmentObject(queue).environmentObject(history).environmentObject(library)
                .environmentObject(navigation)
                .background(Color(nsColor: .windowBackgroundColor))
        }

        // 1. Einen einzelnen Titel suchen – der schon vorhandene wird markiert.
        let quickAdd = QuickAddModel()
        quickAdd.text = "toto africa"
        quickAdd.search("toto africa", tools: paths, cookies: .none)
        try await waitUntil("Suchergebnisse") { quickAdd.phase == .results }
        try await snapshot(environment(PlaylistScreen(sourceID: mac, playlistID: rock.id, quickAdd: quickAdd)), "1-suchen", dark: false)

        // 2. Einen Titel per „+“ hinzufügen – er erscheint oben in der Playlist und lädt.
        quickAdd.search("me at the zoo jawed", tools: paths, cookies: .none)
        try await waitUntil("Zoo-Suche") { quickAdd.phase == .results }
        let zoo = try XCTUnwrap(quickAdd.results.first { $0.id == "jNQXAC9IVRw" } ?? quickAdd.results.first)
        queue.add(candidate: zoo, query: "me at the zoo jawed", to: rock.url)
        quickAdd.markAdded(zoo)
        try await waitUntil("Download läuft") { queue.items.first.map { $0.status.isTransferring || $0.status == .completed } ?? false }
        try await snapshot(environment(PlaylistScreen(sourceID: mac, playlistID: rock.id, quickAdd: quickAdd)), "2-hinzufuegen", dark: false)
        try await waitUntil("Titel in Rock", timeout: 180) {
            queue.items.isEmpty && library.tracks(in: mac, playlistID: rock.id).contains { $0.title.contains("zoo") }
        }

        // 3. Mehrere Titel: einer braucht eine Auswahl, der Link lädt direkt.
        input.text = "Me at the zoo\nhttps://youtu.be/jNQXAC9IVRw"
        let entries = input.parseNow().entries
        try await snapshot(environment(AddSeveralSheet(sourceID: mac, playlistID: party.id)), "3-mehrere-titel", dark: false, size: CGSize(width: 880, height: 470))
        queue.add(entries: entries, to: party.url)
        try await waitUntil("Auswahl nötig") { queue.activity.needsAttention == 1 }
        navigation.selection = .playlist(source: mac, id: party.id)
        try await snapshot(environment(PlaylistScreen(sourceID: mac, playlistID: party.id)), "4-auswahl", dark: true)
        let choice = try XCTUnwrap(queue.items.first { $0.status == .needsSelection })
        queue.choose(try XCTUnwrap(choice.candidates.first { $0.id == "jNQXAC9IVRw" } ?? choice.candidates.first), for: choice)
        try await waitUntil("Alles geladen", timeout: 240) { queue.items.isEmpty && !library.isScanning(mac) }
        XCTAssertEqual(history.entries.filter { $0.state == .downloaded }.count, 2, "Gleiche Datei in Party zählt einmal")

        // 4. Eine Playlist im Alltag (hell und dunkel)
        try await snapshot(environment(PlaylistScreen(sourceID: mac, playlistID: rock.id)), "5-playlist", dark: false)
        try await snapshot(environment(PlaylistScreen(sourceID: mac, playlistID: nil)), "5-alle-titel-dunkel", dark: true)

        // 5. Andere Version: den Titel in Rock austauschen
        let downloaded = try XCTUnwrap(library.tracks(in: mac, playlistID: rock.id).first { $0.title.contains("zoo") })
        let replace = ReplaceViewModel(track: downloaded, tools: paths, settings: settings, library: library, history: history)
        replace.useLink("https://www.youtube.com/watch?v=jNQXAC9IVRw")
        try await waitUntil("Austauschen", timeout: 180) {
            if case .done = replace.phase { return true }
            if case .failed = replace.phase { return true }
            return false
        }
        XCTAssertEqual(replace.phase, .done("Me at the zoo"))
        XCTAssertTrue(history.entries.contains { $0.state == .replaced })

        // 6. Verlauf und Seitenleiste
        try await snapshot(environment(HistoryScreen()), "6-verlauf", dark: false)
        try await snapshot(environment(Sidebar()), "7-seitenleiste", dark: false, size: CGSize(width: 250, height: 640))
    }

    // MARK: Hilfen

    private func waitUntil(_ what: String, timeout: TimeInterval = 120, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Zeitüberschreitung: \(what)") }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func snapshot<V: View>(_ view: V, _ name: String, dark: Bool, size: CGSize = CGSize(width: 1000, height: 760)) async throws {
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
