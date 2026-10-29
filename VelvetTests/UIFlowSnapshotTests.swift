import AppKit
import SwiftUI
import XCTest
@testable import Velvet

/// Spielt einen kompletten Lauf über die echten ViewModels durch und speichert Bildschirmfotos der Oberfläche
/// (hell und dunkel). Läuft nur mit `VELVET_SNAPSHOT_DIR=/pfad`:
///   TEST_RUNNER_VELVET_SNAPSHOT_DIR=/tmp/velvet-shots xcodebuild test -scheme Velvet -only-testing:VelvetTests/UIFlowSnapshotTests
@MainActor
final class UIFlowSnapshotTests: XCTestCase {
    private var outputDirectory: URL!
    private var destination: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["VELVET_SNAPSHOT_DIR"] else {
            throw XCTSkip("Snapshot-Test deaktiviert (VELVET_SNAPSHOT_DIR setzen).")
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        destination = FileManager.default.temporaryDirectory.appendingPathComponent("velvet-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let destination { try? FileManager.default.removeItem(at: destination) }
    }

    func testCompleteFlow() async throws {
        let defaults = UserDefaults(suiteName: "velvet-snapshot-tests")!
        defaults.removePersistentDomain(forName: "velvet-snapshot-tests")
        let settings = AppSettings(defaults: defaults)
        settings.format = .audio
        let tools = ToolManager()
        await tools.prepare(autoUpdate: false)
        XCTAssertTrue(tools.isReady, "\(tools.state)")

        let input = InputViewModel()
        let queue = QueueViewModel(settings: settings, tools: tools)
        func screen() -> some View {
            ContentView()
                .environmentObject(settings)
                .environmentObject(tools)
                .environmentObject(input)
                .environmentObject(queue)
        }

        // 1. Eingabe mit unordentlicher Liste
        input.text = """
        Meine Party-Playlist:
        1. Queen – Bohemian Rhapsody
        2) toto africa
        • Me at the zoo 🎵 (0:19)
        https://youtu.be/jNQXAC9IVRw?si=abc
        Das sind die Lieder, die unbedingt laufen müssen.
        queen - bohemian rhapsody
        """
        let parsed = input.parseNow()
        XCTAssertEqual(parsed.entries.map(\.displayText), [
            "Queen – Bohemian Rhapsody", "toto africa", "Me at the zoo", "youtube.com/watch?v=jNQXAC9IVRw",
        ])
        try await snapshot(screen(), "1-eingabe", dark: false)
        try await snapshot(screen(), "1-eingabe-dunkel", dark: true)

        // 2. Start: Link lädt sofort, Titel werden gesucht
        queue.start(entries: parsed.entries, destination: destination)
        XCTAssertEqual(queue.items.count, 4)
        try await waitUntil("Suchergebnisse") { queue.summary.needsAttention == 3 }
        let zoo = queue.items[2]
        XCTAssertEqual(zoo.status, .needsSelection)
        XCTAssertGreaterThanOrEqual(zoo.candidates.count, 3)
        try await snapshot(screen(), "2-auswahl", dark: false)
        try await snapshot(screen(), "2-auswahl-dunkel", dark: true)

        // 3. „Andere Vorschläge“ liefert neue Treffer
        let firstPage = Set(queue.items[0].candidates.map(\.id))
        queue.showMoreSuggestions(for: queue.items[0])
        try await waitUntil("zweite Seite") { queue.items[0].status == .needsSelection }
        XCTAssertEqual(queue.items[0].page, 1)
        XCTAssertTrue(firstPage.isDisjoint(with: queue.items[0].candidates.map(\.id)))

        // 4. Auswahl per Klick (hier: das kurze „Me at the zoo“), Rest überspringen / eigener Link
        let target = try XCTUnwrap(zoo.candidates.first { $0.id == "jNQXAC9IVRw" } ?? zoo.candidates.first)
        queue.choose(target, for: zoo)
        queue.skip(queue.items[0])
        queue.useLink(YouTubeLink.watchURL("jNQXAC9IVRw"), for: queue.items[1])
        try await waitUntil("Downloads fertig", timeout: 240) { queue.isFinished }

        let statuses = queue.items.map(\.status)
        XCTAssertEqual(statuses[0], .ignored)
        XCTAssertTrue(statuses[1...].contains(.completed), "\(statuses)")
        // Dasselbe Video dreimal: einmal geladen, die anderen beiden übersprungen (Archiv)
        XCTAssertEqual(queue.summary.completed + queue.summary.skipped, 3, "\(statuses)")
        let mp3s = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasSuffix(".mp3") }
        XCTAssertEqual(mp3s.count, 1, "\(mp3s)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".velvet-temp").path))
        try await snapshot(screen(), "3-fertig", dark: false)
        try await snapshot(screen(), "3-fertig-dunkel", dark: true)

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

    private func snapshot<V: View>(_ view: V, _ name: String, dark: Bool, size: CGSize = CGSize(width: 1120, height: 840)) async throws {
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
