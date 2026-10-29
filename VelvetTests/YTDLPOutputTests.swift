import XCTest
@testable import Velvet

final class YTDLPOutputTests: XCTestCase {
    func testParsesMarkerLines() {
        XCTAssertEqual(
            YTDLPOutput.parse("VELVET|INFO|dQw4w9WgXcQ|136+140|Rick Astley | Never Gonna Give You Up"),
            .info(videoID: "dQw4w9WgXcQ", formatID: "136+140", title: "Rick Astley | Never Gonna Give You Up")
        )
        XCTAssertEqual(
            YTDLPOutput.parse("VELVET|DL|136|downloading|1024|629172|NA|3760628.95|12"),
            .progress(formatID: "136", status: "downloading", downloaded: 1024, total: 629172, speed: 3760628.95, eta: 12)
        )
        XCTAssertEqual(
            YTDLPOutput.parse("VELVET|DL|18|downloading|500|NA|1000|NA|NA"),
            .progress(formatID: "18", status: "downloading", downloaded: 500, total: 1000, speed: nil, eta: nil)
        )
        XCTAssertEqual(YTDLPOutput.parse("VELVET|PP|started|Merger"), .postprocess(status: "started", name: "Merger"))
        XCTAssertEqual(YTDLPOutput.parse("VELVET|FILE|/tmp/A | B.mp4"), .file("/tmp/A | B.mp4"))
        XCTAssertNil(YTDLPOutput.parse("[download] Destination: x.mp4"))
    }

    func testProgressIsWeightedAcrossVideoAndAudio() throws {
        let parts = ["136", "140"]
        let halfVideo = try XCTUnwrap(YTDLPOutput.downloadFraction(formatParts: parts, formatID: "136", downloaded: 50, total: 100))
        XCTAssertEqual(halfVideo, 0.425 * YTDLPOutput.downloadShare, accuracy: 0.0001)
        let doneAudio = try XCTUnwrap(YTDLPOutput.downloadFraction(formatParts: parts, formatID: "140", downloaded: 100, total: 100))
        XCTAssertEqual(doneAudio, YTDLPOutput.downloadShare, accuracy: 0.0001)
        XCTAssertNil(YTDLPOutput.downloadFraction(formatParts: parts, formatID: "136", downloaded: 10, total: nil))
    }

    func testSkipReasonsAndErrors() {
        XCTAssertEqual(YTDLPOutput.skipReason(in: "[download] dQw4w9WgXcQ: has already been recorded in the archive"), .archived)
        XCTAssertEqual(YTDLPOutput.errorMessage(in: "ERROR: [youtube] abc: Video unavailable"), "[youtube] abc: Video unavailable")
        XCTAssertEqual(YTDLPOutput.friendlyError("ERROR: [youtube] dQw4w9WgXcQ: Private video. Sign in if you've been granted access"), "Das Video ist privat.")
        XCTAssertTrue(YTDLPOutput.friendlyError("[youtube] x: Sign in to confirm you’re not a bot").contains("Bot-Prüfung"))
        XCTAssertTrue(YTDLPOutput.friendlyError("HTTP Error 403: Forbidden").contains("403"))
    }

    func testParsesSearchJSON() throws {
        let json = """
        {"id": "queen", "_type": "playlist", "entries": [
          {"id": "fJ9rUzIMcZQ", "title": "Queen – Bohemian Rhapsody (Official Video Remastered)", "duration": 359.0,
           "channel": "Queen Official", "view_count": 1834567890, "url": "https://www.youtube.com/watch?v=fJ9rUzIMcZQ",
           "thumbnails": [{"url": "https://i.ytimg.com/vi/fJ9rUzIMcZQ/hq720.jpg", "width": 360, "height": 202},
                          {"url": "https://i.ytimg.com/vi/fJ9rUzIMcZQ/hq720b.jpg", "width": 720, "height": 404}]},
          {"id": "live1234567", "title": "Queen Radio 24/7", "live_status": "is_live", "url": "https://www.youtube.com/watch?v=live1234567"},
          {"id": "deleted1234", "title": "[Deleted video]"},
          {"id": "irp8CNj9qBI", "title": "Queen - Bohemian Rhapsody", "duration": 351, "uploader": "frozentoast"}
        ]}
        """
        let entries = try YTDLPOutput.parseEntries(Data(json.utf8))
        XCTAssertEqual(entries.map(\.id), ["fJ9rUzIMcZQ", "irp8CNj9qBI"])
        XCTAssertEqual(entries[0].durationText, "5:59")
        XCTAssertEqual(entries[0].viewCountText, "1,8 Mrd. Aufrufe")
        XCTAssertEqual(entries[0].thumbnailURL?.absoluteString, "https://i.ytimg.com/vi/fJ9rUzIMcZQ/hq720.jpg")
        XCTAssertEqual(entries[1].channel, "frozentoast")
        XCTAssertEqual(entries[1].url.absoluteString, "https://www.youtube.com/watch?v=irp8CNj9qBI")
        XCTAssertEqual(entries[1].thumbnailURL?.absoluteString, "https://i.ytimg.com/vi/irp8CNj9qBI/mqdefault.jpg")
    }

    func testChecksumLookup() {
        let sums = """
        0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa  yt-dlp_macos
        20d98fa608998eff87d1d35a6e9fb65e4b874639a6cc89addc19da3becde3ef1  yt-dlp_macos.zip
        """
        XCTAssertEqual(YtDlpInstaller.checksum(for: "yt-dlp_macos.zip", in: sums), "20d98fa608998eff87d1d35a6e9fb65e4b874639a6cc89addc19da3becde3ef1")
        XCTAssertNil(YtDlpInstaller.checksum(for: "yt-dlp.exe", in: sums))
    }

    func testFormatters() {
        XCTAssertEqual(Formatters.duration(3725), "1:02:05")
        XCTAssertEqual(Formatters.views(34_567), "34.567 Aufrufe")
        XCTAssertEqual(Formatters.views(1_234_567), "1,2 Mio. Aufrufe")
        XCTAssertEqual(Formatters.percent(0.456), "45 %")
        XCTAssertTrue(VersionComparator.isNewer("2026.10.26", than: "2026.9.30"))
        XCTAssertFalse(VersionComparator.isNewer("2026.10.26", than: "2026.10.26.1"))
    }
}
