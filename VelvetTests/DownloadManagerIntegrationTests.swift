import XCTest
@testable import Velvet

/// Echte Suche und echte Downloads über das Internet.
/// Läuft nur, wenn `VELVET_INTEGRATION=1` gesetzt ist:
///   TEST_RUNNER_VELVET_INTEGRATION=1 xcodebuild test -scheme Velvet
@MainActor
final class DownloadManagerIntegrationTests: XCTestCase {
    private var manager: DownloadManager!
    private var folder: URL!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["VELVET_INTEGRATION"] == "1" else {
            throw XCTSkip("Integrationstests sind deaktiviert (VELVET_INTEGRATION=1 setzen).")
        }
        let tools = ToolManager()
        await tools.prepare(autoUpdate: false)
        let paths = try XCTUnwrap(tools.paths, "Werkzeuge nicht bereit: \(tools.state)")
        manager = DownloadManager(tools: paths)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("velvet-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testLatestYtDlpVersionCanBeDetermined() async throws {
        let latest = try await YtDlpInstaller.latestVersion()
        let installed = try XCTUnwrap(YtDlpInstaller.installedVersion)
        XCTAssertFalse(VersionComparator.isNewer(installed, than: latest), "Installiert \(installed), neueste \(latest)")
    }

    func testSearchReturnsFiveResultsPerPage() async throws {
        let first = try await manager.search("rick astley never gonna give you up")
        let second = try await manager.search("rick astley never gonna give you up", excluding: Set(first.map(\.id)))
        XCTAssertEqual(first.count, DownloadManager.searchPageSize)
        XCTAssertEqual(second.count, DownloadManager.searchPageSize)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)), "„Andere Vorschläge“ muss neue Videos liefern")
        XCTAssertTrue(first.allSatisfy { !$0.title.isEmpty && $0.thumbnailURL != nil })
    }

    func testDownloadsMP4AndMP3AndSkipsArchived() async throws {
        let url = YouTubeLink.watchURL("jNQXAC9IVRw") // „Me at the zoo“, 19 Sekunden
        let events = EventLog()

        var options = DownloadOptions(format: .video, videoQuality: .p720, audioQuality: .best,
                                      destination: folder, useArchive: true, cookieBrowser: .none)
        let video = try await manager.download(url, options: options) { events.append($0) }
        guard case let .completed(file, videoID) = video else { return XCTFail("Erwartet: fertig, erhalten: \(video)") }
        XCTAssertEqual(file.pathExtension, "mp4")
        XCTAssertEqual(videoID, "jNQXAC9IVRw")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(events.sawMetadata)

        let again = try await manager.download(url, options: options) { _ in }
        XCTAssertEqual(again, .skipped(.archived))

        options.format = .audio
        let audio = try await manager.download(url, options: options) { events.append($0) }
        guard case let .completed(mp3, _) = audio else { return XCTFail("Erwartet: fertig, erhalten: \(audio)") }
        XCTAssertEqual(mp3.pathExtension, "mp3")
        XCTAssertTrue(events.sawPostprocessing)

        DownloadManager.removeFromArchive(videoID: "jNQXAC9IVRw", archive: options.archiveURL)
        let archive = try String(contentsOf: options.archiveURL, encoding: .utf8)
        XCTAssertFalse(archive.contains("jNQXAC9IVRw"))
    }

    func testUnavailableVideoFailsWithGermanMessage() async throws {
        let options = DownloadOptions(format: .video, videoQuality: .p480, audioQuality: .best,
                                      destination: folder, useArchive: false, cookieBrowser: .none)
        do {
            _ = try await manager.download(YouTubeLink.watchURL("aaaaaaaaaaa"), options: options) { _ in }
            XCTFail("Download hätte fehlschlagen müssen")
        } catch let failure as DownloadFailure {
            XCTAssertFalse(failure.message.isEmpty)
            XCTAssertFalse(failure.log.isEmpty)
        }
    }

    func testCancellationStopsDownload() async throws {
        let options = DownloadOptions(format: .video, videoQuality: .best, audioQuality: .best,
                                      destination: folder, useArchive: false, cookieBrowser: .none)
        let task = Task { [manager] in
            try await manager!.download(YouTubeLink.watchURL("aqz-KE-bpKQ"), options: options) { _ in }
        }
        try await Task.sleep(nanoseconds: 6_000_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Abbruch erwartet")
        } catch {
            XCTAssertTrue(error is CancellationError, "Erhalten: \(error)")
        }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DownloadEvent] = []

    func append(_ event: DownloadEvent) {
        lock.locked { events.append(event) }
    }

    var sawMetadata: Bool {
        lock.locked { events.contains { if case .metadata = $0 { return true } else { return false } } }
    }

    var sawPostprocessing: Bool {
        lock.locked { events.contains { if case .postprocessing = $0 { return true } else { return false } } }
    }
}
