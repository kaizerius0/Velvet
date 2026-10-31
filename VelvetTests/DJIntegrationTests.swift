import XCTest
@testable import Velvet

/// Tags schreiben mit dem gebündelten ffmpeg – ohne Internet.
final class TagWriterTests: XCTestCase {
    func testBPMAndKeyAreWrittenAndCoverStays() async throws {
        guard let ffmpeg = ToolManager.bundledTool("ffmpeg") else { throw XCTSkip("ffmpeg ist nicht im App-Bundle.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("velvet-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Eine kurze MP3 mit Titel und Cover, wie yt-dlp sie anlegt.
        let cover = folder.appendingPathComponent("cover.png")
        let file = folder.appendingPathComponent("Test - Song.mp3")
        _ = try await BinaryRunner.run(ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=red:s=64x64:d=1", "-frames:v", "1", cover.path,
        ], timeout: 30)
        _ = try await BinaryRunner.run(ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-i", cover.path,
            "-map", "0", "-map", "1", "-c:a", "libmp3lame", "-c:v", "png", "-disposition:v", "attached_pic",
            "-id3v2_version", "3", "-metadata", "title=Song", "-metadata", "artist=Test", file.path,
        ], timeout: 30)

        try await TagWriter.write(bpm: 123.6, key: MusicalKey.parse("8A"), to: file, ffmpeg: ffmpeg)

        let tags = try XCTUnwrap(ID3Reader.tags(of: file))
        XCTAssertEqual(tags.bpm, 124)
        XCTAssertEqual(tags.key?.camelot, "8A")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".velvet-tags") }
        XCTAssertTrue(leftovers.isEmpty, "Keine Zwischendateien übrig")

        // Titel und Cover sind noch da.
        if let ffprobe = ToolManager.bundledTool("ffprobe") {
            let output = try await BinaryRunner.run(ffprobe, arguments: [
                "-v", "error", "-show_entries", "format_tags=title,artist,TBPM:stream=codec_type", "-of", "default=nw=1", file.path,
            ], timeout: 30)
            let text = String(decoding: output, as: UTF8.self)
            XCTAssertTrue(text.contains("title=Song"), text)
            XCTAssertTrue(text.contains("artist=Test"), text)
            XCTAssertTrue(text.contains("codec_type=video"), "Cover fehlt: \(text)")
        }
    }
}

/// Empfehlungen, Vorschau und Spotify über das Internet.
/// Läuft nur mit `VELVET_INTEGRATION=1`:
///   TEST_RUNNER_VELVET_INTEGRATION=1 xcodebuild test -scheme Velvet -only-testing:VelvetTests/DJIntegrationTests
@MainActor
final class DJIntegrationTests: XCTestCase {
    private var manager: DownloadManager!
    private var paths: ToolPaths!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["VELVET_INTEGRATION"] == "1" else {
            throw XCTSkip("Integrationstests sind deaktiviert (VELVET_INTEGRATION=1 setzen).")
        }
        let tools = ToolManager()
        await tools.prepare(autoUpdate: false)
        paths = try XCTUnwrap(tools.paths, "Werkzeuge nicht bereit: \(tools.state)")
        manager = DownloadManager(tools: paths)
    }

    func testMixReturnsSimilarTracks() async throws {
        let mix = try await manager.mix(for: "x3rbGKihrOM", limit: 25)
        XCTAssertGreaterThanOrEqual(mix.count, 15)
        XCTAssertFalse(mix.contains { $0.id == "x3rbGKihrOM" }, "Der Ausgangstitel gehört nicht in die Vorschläge")
        let ranked = Recommender.rank([mix], context: Recommender.Context(), limit: 20)
        XCTAssertGreaterThanOrEqual(ranked.count, 8)
        XCTAssertTrue(ranked.allSatisfy { !$0.version.isFullSet })
    }

    func testPreviewDownloadAndAnalysis() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("velvet-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = PreviewCache(folder: folder)
        let candidate = TrackVersionTests.candidate("x3rbGKihrOM", "Fred again - Marea (We've Lost Dancing) (Extended Mix)", 289)
        let progress = ProgressLog()
        let file = try await cache.file(for: candidate, manager: manager, cookies: .none) { progress.append($0) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNotNil(cache.cachedFile(for: candidate.id), "Zweiter Aufruf kommt aus dem Zwischenspeicher")

        let samples = try await AudioDecoder.samples(of: file, ffmpeg: paths.ffmpeg, start: 10, duration: 420)
        XCTAssertGreaterThan(samples.count, Int(AudioAnalyzer.sampleRate) * 200)
        let result = AudioAnalyzer.analyze(samples)
        let bpm = try XCTUnwrap(result.bpm)
        XCTAssertEqual(bpm, 123, accuracy: 2, "Marea läuft mit etwa 123 BPM")
        XCTAssertNotNil(result.key)
    }

    func testSpotifyPlaylistLoads() async throws {
        let playlist = try await SpotifyEmbed.load(URL(string: "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M")!)
        XCTAssertGreaterThanOrEqual(playlist.tracks.count, 30)
        XCTAssertTrue(playlist.tracks.allSatisfy { !$0.title.isEmpty && !$0.artists.isEmpty })
    }

    func testDeezerFindsArtistsAndSongs() async throws {
        let artist = try await XCTUnwrapAsync(await DeezerClient.findArtist("Fred again.."))
        let related = try await DeezerClient.related(to: artist, limit: 5)
        XCTAssertFalse(related.isEmpty)
        let songs = try await DeezerClient.topSongs(of: artist, limit: 3)
        XCTAssertEqual(songs.count, 3)
    }

    func testLabelUploadsAndChannelInfo() async throws {
        let uploads = try await manager.channelUploads("UCpiZh3AGeTygzfmUgioOFFg", limit: 6)
        XCTAssertGreaterThanOrEqual(uploads.count, 3)
        let info = try await manager.channelInfo(URL(string: "https://www.youtube.com/@toolroomrecords")!)
        XCTAssertEqual(info.id, "UCpiZh3AGeTygzfmUgioOFFg")
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) { lock.locked { values.append(value) } }
}
