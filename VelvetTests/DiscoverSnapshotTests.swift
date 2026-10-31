import AppKit
import SwiftUI
import XCTest
@testable import Velvet

/// „Entdecken“ und Set-Builder mit echten Daten: drei Titel laden (inkl. Tempo/Tonart), Vorschläge holen,
/// ein Set bauen, vorhören – und Bildschirmfotos speichern. Läuft nur mit `VELVET_SNAPSHOT_DIR=/pfad`:
///   TEST_RUNNER_VELVET_SNAPSHOT_DIR=/tmp/velvet-shots xcodebuild test -scheme Velvet -only-testing:VelvetTests/DiscoverSnapshotTests
@MainActor
final class DiscoverSnapshotTests: XCTestCase {
    private var outputDirectory: URL!
    private var root: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELVET_SNAPSHOT_DIR"] else {
            throw XCTSkip("Snapshot-Test deaktiviert (VELVET_SNAPSHOT_DIR setzen).")
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Velvet-DJ-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("House"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testDiscoverAndSetBuilder() async throws {
        let defaults = UserDefaults(suiteName: "velvet-dj-snapshot")!
        defaults.removePersistentDomain(forName: "velvet-dj-snapshot")
        defer { defaults.removePersistentDomain(forName: "velvet-dj-snapshot") }

        let settings = AppSettings(defaults: defaults)
        settings.preferredVersion = .extended
        let tools = ToolManager()
        await tools.prepare(autoUpdate: false)
        XCTAssertNotNil(tools.paths, "\(tools.state)")

        let house = root.appendingPathComponent("House")
        let history = HistoryStore(fileURL: root.appendingPathComponent(".history.json"))
        let library = LibraryViewModel(history: history, defaults: defaults, macFolders: [house])
        let queue = QueueViewModel(settings: settings, tools: tools, history: history, library: library)
        let taste = TasteStore(fileURL: root.appendingPathComponent(".discover.json"))
        let analysis = AnalysisCenter(tools: tools, settings: settings, fileURL: root.appendingPathComponent(".analysis.json"))
        analysis.library = library
        queue.analysis = analysis
        let player = PreviewPlayer(tools: tools, settings: settings)
        let discover = DiscoverViewModel(settings: settings, tools: tools, history: history, library: library, queue: queue,
                                         taste: taste, analysis: analysis, cacheURL: root.appendingPathComponent(".cache.json"))
        let navigation = AppNavigation()
        let input = InputViewModel()
        settings.addTarget = house
        taste.follow(TasteStore.suggestedLabels[0])
        taste.follow(TasteStore.suggestedLabels[1])

        func environment<V: View>(_ view: V) -> some View {
            view
                .environmentObject(settings).environmentObject(tools).environmentObject(input)
                .environmentObject(queue).environmentObject(history).environmentObject(library)
                .environmentObject(navigation).environmentObject(taste).environmentObject(analysis)
                .environmentObject(player).environmentObject(discover)
                .background(Color(nsColor: .windowBackgroundColor))
        }

        // 1. Drei Club-Titel laden: sauberer Dateiname, danach Tempo und Tonart in der MP3.
        let titles = [
            ("x3rbGKihrOM", "Fred again - Marea (We've Lost Dancing) (Extended Mix)"),
            ("9M0kwjH4GQ4", "CamelPhat X Cristoph (Feat. Jem Cooke) - Breathe (Club Mix)"),
            ("fg21FNkNtYQ", "CamelPhat, ARTBAT - For A Feeling (Extended Mix) [Audio] ft. RHODES"),
        ]
        queue.add(candidates: titles.map { TrackVersionTests.candidate($0.0, $0.1, nil) }, to: house)
        try await waitUntil("Downloads fertig", timeout: 300) { queue.items.allSatisfy { $0.status.isTerminal } }
        XCTAssertEqual(queue.activity.completed, 3, queue.items.map { "\($0.status)" }.joined(separator: ", "))
        try await waitUntil("Analyse fertig", timeout: 180) {
            analysis.pendingCount == 0 && !library.isScanning(LibrarySource.macID)
                && library.tracks(in: LibrarySource.macID).filter { $0.bpm != nil }.count == 3
        }
        let tracks = library.tracks(in: LibrarySource.macID)
        XCTAssertTrue(tracks.contains { $0.title == "CamelPhat, ARTBAT feat. RHODES - For A Feeling (Extended Mix)" }, tracks.map(\.title).description)
        XCTAssertTrue(tracks.allSatisfy { $0.key != nil }, "Tonart steht in den Tags")
        try await snapshot(environment(FolderScreen(sourceID: LibrarySource.macID, folderID: house.standardizedFileURL.path)), "dj-1-ordner", dark: false)

        // 2. Entdecken: Reihen aus dem Verlauf, dem Ordner, Labels und Künstlern.
        discover.refresh()
        try await waitUntil("Vorschläge", timeout: 300) { !discover.isRefreshing }
        XCTAssertFalse(discover.shelves.isEmpty)
        XCTAssertTrue(discover.shelves.contains { $0.kind == .because })
        XCTAssertTrue(discover.shelves.contains { $0.kind == .folder })
        let suggested = discover.shelves.flatMap(\.items)
        XCTAssertFalse(suggested.contains { ["x3rbGKihrOM", "9M0kwjH4GQ4", "fg21FNkNtYQ"].contains($0.id) }, "Vorhandenes wird nicht vorgeschlagen")
        try await snapshot(environment(DiscoverScreen()), "dj-2-entdecken", dark: false, size: CGSize(width: 1180, height: 1300))
        try await snapshot(environment(DiscoverScreen()), "dj-2-entdecken-dunkel", dark: true, size: CGSize(width: 1180, height: 1300))

        // 3. Vorhören eines Vorschlags.
        let first = try XCTUnwrap(discover.shelves.first?.items.first)
        player.play(first.candidate)
        try await waitUntil("Vorschau spielt", timeout: 60) { player.isPlaying }
        XCTAssertGreaterThan(player.position, 30, "Vorschau beginnt nach dem Intro")
        try await snapshot(environment(ContentView()), "dj-3-player", dark: false, size: CGSize(width: 1240, height: 820))
        player.stop()

        // 4. Set-Builder: aus einem Song, nach Tonart gefiltert und harmonisch sortiert.
        discover.startSet(query: "Fred again Marea")
        let set = try XCTUnwrap(discover.setBuilder)
        try await waitUntil("Set bereit", timeout: 180) { set.phase == .ready && set.seedAnalysis != nil }
        set.count = 10
        try await waitUntil("Tempo der Titel", timeout: 300) { set.analysisProgress == nil }
        XCTAssertEqual(set.entries.count, 10)
        set.order = .harmonic
        try await snapshot(environment(DiscoverScreen()), "dj-4-set", dark: false, size: CGSize(width: 1180, height: 820))
        set.matchKey = true
        try await waitUntil("Tonart-Filter", timeout: 400) { set.analysisProgress == nil }
        let reference = try XCTUnwrap(set.seedAnalysis?.key)
        XCTAssertTrue(set.entries.allSatisfy { set.analyses[$0.id]?.key?.isCompatible(with: reference) == true })
        try await snapshot(environment(DiscoverScreen()), "dj-5-set-harmonisch", dark: true, size: CGSize(width: 1180, height: 820))

        // 5. Set auf den „Stick“ (hier ein Mac-Ordner).
        set.count = 10
        set.target = .existing(house)
        let before = queue.items.count
        set.commit()
        XCTAssertEqual(queue.items.count - before, set.selectedEntries.count)
        for item in queue.items { queue.remove(item) }

        try await snapshot(environment(Sidebar()), "dj-6-seitenleiste", dark: false, size: CGSize(width: 250, height: 520))
    }

    // MARK: Hilfen

    private func waitUntil(_ what: String, timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Zeitüberschreitung: \(what)") }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func snapshot<V: View>(_ view: V, _ name: String, dark: Bool, size: CGSize = CGSize(width: 1100, height: 820)) async throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}
