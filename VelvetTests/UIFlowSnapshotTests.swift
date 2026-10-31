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

        // Zwei Musikordner auf dem Mac.
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
        let library = LibraryViewModel(history: history, defaults: defaults,
                                       macFolders: [root.appendingPathComponent("Rock"), root.appendingPathComponent("Party")])
        let navigation = AppNavigation()
        let queue = QueueViewModel(settings: settings, tools: tools, history: history, library: library)
        let taste = TasteStore(fileURL: root.appendingPathComponent(".discover-test.json"))
        let analysis = AnalysisCenter(tools: tools, settings: settings, fileURL: root.appendingPathComponent(".analysis-test.json"))
        let player = PreviewPlayer(tools: tools, settings: settings)
        let discover = DiscoverViewModel(settings: settings, tools: tools, history: history, library: library, queue: queue,
                                         taste: taste, analysis: analysis, cacheURL: root.appendingPathComponent(".cache-test.json"))
        let mac = LibrarySource.macID
        try await waitUntil("Bibliothek eingelesen") { library.revision > 0 && !library.isScanning(mac) }
        let rock = try XCTUnwrap(library.folders(in: mac).first { $0.name == "Rock" })
        let party = try XCTUnwrap(library.folders(in: mac).first { $0.name == "Party" })
        navigation.selection = .folder(source: mac, id: rock.id)

        func environment<V: View>(_ view: V) -> some View {
            view
                .environmentObject(settings).environmentObject(tools).environmentObject(input)
                .environmentObject(queue).environmentObject(history).environmentObject(library)
                .environmentObject(navigation).environmentObject(taste).environmentObject(analysis)
                .environmentObject(player).environmentObject(discover)
                .background(Color(nsColor: .windowBackgroundColor))
        }

        // 1. Hinzufügen: ein Titel zum Auswählen und ein Link, Ziel „Rock“
        settings.addTarget = rock.url
        navigation.selection = .add
        input.text = "Toto Africa Extended\nMe at the zoo\nhttps://youtu.be/jNQXAC9IVRw"
        let entries = input.parseNow().entries
        XCTAssertEqual(entries.count, 3)
        try await snapshot(environment(AddScreen()), "1-eingabe", dark: false)

        queue.add(entries: Array(entries.dropFirst()), to: rock.url)
        input.clear()
        try await waitUntil("Auswahl nötig") { queue.activity.needsAttention == 1 }
        let choice = try XCTUnwrap(queue.items.first { $0.status == .needsSelection })
        XCTAssertEqual(choice.candidates.count, 5)

        // 2. Zur Seite wischen: fünf weitere werden angehängt, die ersten bleiben (zurückwischen geht).
        let firstFive = choice.candidates.map(\.id)
        queue.loadMoreCandidates(for: choice)
        try await waitUntil("Weitere Vorschläge") { !choice.isLoadingMore && choice.candidates.count >= 10 }
        XCTAssertEqual(Array(choice.candidates.prefix(5)).map(\.id), firstFive)
        XCTAssertEqual(Set(choice.candidates.map(\.id)).count, choice.candidates.count, "keine doppelten Vorschläge")
        try await snapshot(environment(AddScreen()), "2-auswahl", dark: false)
        try await snapshot(environment(AddScreen()), "2-auswahl-dunkel", dark: true)

        queue.choose(try XCTUnwrap(choice.candidates.first { $0.id == "jNQXAC9IVRw" } ?? choice.candidates.first), for: choice)
        try await waitUntil("Alles geladen", timeout: 240) {
            queue.items.allSatisfy { $0.status == .completed } && !library.isScanning(mac)
        }
        XCTAssertEqual(queue.activity.completed, 2)
        XCTAssertEqual(history.entries.filter { $0.state == .downloaded }.count, 1, "Gleiche Datei in Rock zählt einmal")
        try await snapshot(environment(AddScreen()), "3-fertig", dark: false)
        queue.clearFinished()
        XCTAssertTrue(queue.items.isEmpty)

        // 3. Der Ordner im Alltag (hell und dunkel)
        try await waitUntil("Titel in Rock") { library.tracks(in: mac, folderID: rock.id).contains { $0.title.contains("zoo") } }
        try await snapshot(environment(FolderScreen(sourceID: mac, folderID: rock.id)), "4-ordner", dark: false)
        try await snapshot(environment(FolderScreen(sourceID: mac, folderID: party.id)), "4-ordner-dunkel", dark: true)

        // 5. Andere Version: den Titel in Rock austauschen
        let downloaded = try XCTUnwrap(library.tracks(in: mac, folderID: rock.id).first { $0.title.contains("zoo") })
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
        try await snapshot(environment(HistoryScreen()), "5-verlauf", dark: false)
        try await snapshot(environment(Sidebar()), "6-seitenleiste", dark: false, size: CGSize(width: 250, height: 640))
    }

    // MARK: Hilfen

    private func waitUntil(_ what: String, timeout: TimeInterval = 120, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Zeitüberschreitung: \(what)") }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func snapshot<V: View>(_ view: V, _ name: String, dark: Bool, size: CGSize = CGSize(width: 1040, height: 900)) async throws {
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
