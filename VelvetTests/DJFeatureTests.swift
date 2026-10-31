import XCTest
@testable import Velvet

/// Versionserkennung, Tonarten, Ranking, Set-Reihenfolge, Spotify, rekordbox und ID3 – ohne Internet.
final class TrackVersionTests: XCTestCase {
    func testExtendedMixWithFeaturing() {
        let version = TrackVersion.parse("CamelPhat, ARTBAT - For A Feeling (Extended Mix) [Audio] ft. RHODES")
        XCTAssertEqual(version.artist, "CamelPhat, ARTBAT")
        XCTAssertEqual(version.song, "For A Feeling")
        XCTAssertEqual(version.mix, "Extended Mix")
        XCTAssertEqual(version.featuring, "RHODES")
        XCTAssertTrue(version.badges.contains(.extended))
        XCTAssertEqual(version.fileName, "CamelPhat, ARTBAT feat. RHODES - For A Feeling (Extended Mix)")
        XCTAssertEqual(version.artistKey, "camelphat")
    }

    func testSubtitleStaysPartOfTheSong() {
        let version = TrackVersion.parse("Fred again - Marea (We've Lost Dancing) (Extended Mix)")
        XCTAssertEqual(version.song, "Marea (We've Lost Dancing)")
        XCTAssertEqual(version.mix, "Extended Mix")
        XCTAssertEqual(version.fileName, "Fred again - Marea (We've Lost Dancing) (Extended Mix)")
    }

    func testNoiseIsRemoved() {
        XCTAssertEqual(TrackVersion.parse("Toto - Africa (Official HD Video)").fileName, "Toto - Africa")
        XCTAssertEqual(TrackVersion.parse("BICEP | GLUE (Official Video)").fileName, "BICEP - GLUE")
        XCTAssertEqual(TrackVersion.parse("Weska & MORGANJ - No Escape | Truesoul").song, "No Escape")
        XCTAssertEqual(TrackVersion.parse("Junior Jack, Mark Knight, James Hurr - Feelings [House]").song, "Feelings")
        let visualizer = TrackVersion.parse("Mauro Picotto - Lizard (Dan Cooper Remix) [Official Visualizer]")
        XCTAssertEqual(visualizer.mix, "Dan Cooper Remix")
        XCTAssertTrue(visualizer.badges.contains(.remix))
    }

    func testRemixerExtendedRemix() {
        let version = TrackVersion.parse("Louie Vega & The Martinez Brothers with Marc E. Bassy - Let It Go (Vintage Culture Extended Remix)")
        XCTAssertEqual(version.mix, "Vintage Culture Extended Remix")
        XCTAssertTrue(version.badges.isSuperset(of: [.extended, .remix]))
        XCTAssertEqual(version.artistKey, "louievega")
    }

    func testLiveSpedUpAndSets() {
        XCTAssertTrue(TrackVersion.parse("Fred again.., Sammy Virji, Reggie - Talk of the Town (Dublin, 30th October 2025)").badges.contains(.live))
        XCTAssertTrue(TrackVersion.parse("Drake - Hotline Bling (Sped Up)").badges.contains(.spedUp))
        XCTAssertTrue(TrackVersion.parse("Defected Radio Show Takeover by Ranger Trucco 30.10.26", duration: 4617).isFullSet)
        XCTAssertTrue(TrackVersion.parse("Boiler Room: Fred again.. DJ Set").isFullSet)
        XCTAssertFalse(TrackVersion.parse("Fred again.. - Delilah (pull me out of this)", duration: 260).isFullSet)
    }

    func testVersionWithoutBrackets() {
        let edit = TrackVersion.parse("Fred again.. - Marea We've Lost Dancing Extended Progressive Edit")
        XCTAssertTrue(edit.badges.contains(.extended))
        XCTAssertEqual(edit.song, "Marea We've Lost Dancing")
        XCTAssertEqual(edit.mix, "Extended Progressive Edit")
        let spotify = TrackVersion.parse("Duke Dumont - The Power - Extended Mix")
        XCTAssertEqual(spotify.song, "The Power")
        XCTAssertEqual(spotify.mix, "Extended Mix")
        let remaster = TrackVersion.parse("Fleetwood Mac - Dreams - 2004 Remaster")
        XCTAssertEqual(remaster.song, "Dreams")
        XCTAssertNil(remaster.mix)
    }

    func testTopicChannelGivesArtist() {
        let version = TrackVersion.parse("Cherry Pie", channel: "MBP - Topic")
        XCTAssertEqual(version.artist, "MBP")
        XCTAssertTrue(version.isTopicChannel)
        XCTAssertEqual(version.fileName, "MBP - Cherry Pie")
    }

    func testSameSongDifferentUploadsShareBaseKey() {
        let a = TrackVersion.parse("CamelPhat X Cristoph (Feat. Jem Cooke) - Breathe (Club Mix)")
        let b = TrackVersion.parse("CamelPhat X Cristoph - Breathe (Radio Edit)")
        XCTAssertEqual(a.baseKey, b.baseKey)
        XCTAssertNotEqual(a.songKey, b.songKey)
    }

    func testPreferredVersion() {
        XCTAssertEqual(PreferredVersion.extended.searchQuery(for: "Marea"), "Marea extended mix")
        XCTAssertEqual(PreferredVersion.extended.searchQuery(for: "Marea Radio Edit"), "Marea Radio Edit")
        XCTAssertEqual(PreferredVersion.any.searchQuery(for: "Marea"), "Marea")

        let radio = Self.candidate("a", "Artist - Song (Radio Edit)", 190)
        let original = Self.candidate("b", "Artist - Song", 200)
        let extended = Self.candidate("c", "Artist - Song (Extended Mix)", 380)
        XCTAssertEqual(DownloadManager.ordered([radio, original, extended], preferring: .extended).map(\.id), ["c", "b", "a"])
        XCTAssertEqual(DownloadManager.ordered([extended, original, radio], preferring: .short).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(DownloadManager.ordered([radio, original, extended], preferring: .any).map(\.id), ["a", "b", "c"])
    }

    func testAutoPickAvoidsLiveAndWrongLength() {
        let live = Self.candidate("live", "Artist - Song (Live at Tomorrowland 2024)", 240)
        let long = Self.candidate("set", "Artist - Song (1 Hour Loop)", 3600)
        let fine = Self.candidate("ok", "Artist - Song (Official Audio)", 205)
        XCTAssertEqual(QueueViewModel.bestPick([live, long, fine], expectedDuration: 200).id, "ok")
        XCTAssertEqual(QueueViewModel.bestPick([live], expectedDuration: nil).id, "live", "Ohne Alternative bleibt der erste Treffer")
    }

    static func candidate(_ id: String, _ title: String, _ duration: TimeInterval?, channel: String? = nil) -> VideoCandidate {
        VideoCandidate(id: id, title: title, channel: channel, duration: duration, viewCount: nil, thumbnailURL: nil,
                       url: YouTubeLink.watchURL(id))
    }
}

final class MusicalKeyTests: XCTestCase {
    func testCamelotWheel() {
        XCTAssertEqual(MusicalKey(pitchClass: 0, isMinor: false).camelot, "8B")
        XCTAssertEqual(MusicalKey(pitchClass: 9, isMinor: true).camelot, "8A")
        XCTAssertEqual(MusicalKey(pitchClass: 6, isMinor: true).camelot, "11A")
        XCTAssertEqual(MusicalKey(pitchClass: 8, isMinor: true).camelot, "1A")
        XCTAssertEqual(MusicalKey(pitchClass: 11, isMinor: false).camelot, "1B")
        XCTAssertEqual(MusicalKey(pitchClass: 5, isMinor: false).camelot, "7B")
        // Hin und zurück für alle 24 Tonarten
        for pitch in 0..<12 {
            for minor in [false, true] {
                let key = MusicalKey(pitchClass: pitch, isMinor: minor)
                XCTAssertEqual(MusicalKey.parse(key.camelot), key, key.camelot)
                XCTAssertEqual(MusicalKey.parse(key.name), key, key.name)
            }
        }
    }

    func testParsingVariants() {
        XCTAssertEqual(MusicalKey.parse("Gbm"), MusicalKey(pitchClass: 6, isMinor: true))
        XCTAssertEqual(MusicalKey.parse("a-Moll"), MusicalKey(pitchClass: 9, isMinor: true))
        XCTAssertEqual(MusicalKey.parse("Bb major"), MusicalKey(pitchClass: 10, isMinor: false))
        XCTAssertEqual(MusicalKey.parse("08A"), MusicalKey(pitchClass: 9, isMinor: true))
        XCTAssertNil(MusicalKey.parse("13A"))
        XCTAssertNil(MusicalKey.parse("Hallo"))
    }

    func testHarmonicNeighbours() {
        let eightA = MusicalKey.parse("8A")!
        for compatible in ["8A", "7A", "9A", "8B"] {
            XCTAssertTrue(eightA.isCompatible(with: MusicalKey.parse(compatible)!), compatible)
        }
        for incompatible in ["10A", "9B", "2A"] {
            XCTAssertFalse(eightA.isCompatible(with: MusicalKey.parse(incompatible)!), incompatible)
        }
        XCTAssertTrue(MusicalKey.parse("12A")!.isCompatible(with: MusicalKey.parse("1A")!), "Das Rad ist rund")
        XCTAssertEqual(eightA.distance(to: MusicalKey.parse("8B")!), 1)
    }
}

final class AudioAnalyzerTests: XCTestCase {
    /// Kick auf jeder Zählzeit, Hi-Hat dazwischen – wie ein einfacher House-Beat.
    private func beat(bpm: Double, seconds: Double = 40) -> [Float] {
        let rate = AudioAnalyzer.sampleRate
        let count = Int(rate * seconds)
        var samples = [Float](repeating: 0, count: count)
        let period = 60 / bpm
        var time = 0.0
        var generator = SystemRandomNumberGenerator()
        while time < seconds {
            let start = Int(time * rate)
            for index in 0..<Int(rate * 0.12) where start + index < count {
                let t = Double(index) / rate
                samples[start + index] += Float(sin(2 * .pi * 55 * t) * exp(-t * 30)) * 0.9
            }
            let hat = Int((time + period / 2) * rate)
            for index in 0..<Int(rate * 0.03) where hat + index < count {
                let noise = Float.random(in: -1...1, using: &generator)
                samples[hat + index] += noise * Float(exp(-Double(index) / rate * 120)) * 0.3
            }
            time += period
        }
        return samples
    }

    func testTempoOfHouseBeat() throws {
        for bpm in [100.0, 124, 128] {
            let detected = try XCTUnwrap(AudioAnalyzer.tempo(beat(bpm: bpm)), "\(bpm)")
            XCTAssertEqual(detected, bpm, accuracy: 0.6, "\(bpm) BPM")
        }
    }

    func testDrumAndBassIsHalfOrFullTime() throws {
        let detected = try XCTUnwrap(AudioAnalyzer.tempo(beat(bpm: 174)))
        XCTAssertEqual(SetPlanner.tempoDistance(detected, 174), 0, accuracy: 0.8)
    }

    func testSilenceHasNoTempo() {
        XCTAssertNil(AudioAnalyzer.tempo([Float](repeating: 0, count: 11_025 * 20)))
    }

    /// Ein Akkord aus Sinustönen (mit etwas Bass) über 20 Sekunden.
    private func chord(_ frequencies: [Double], seconds: Double = 20) -> [Float] {
        let rate = AudioAnalyzer.sampleRate
        return (0..<Int(rate * seconds)).map { index in
            let t = Double(index) / rate
            return Float(frequencies.reduce(0) { $0 + sin(2 * .pi * $1 * t) } / Double(frequencies.count)) * 0.5
        }
    }

    func testKeyOfMinorAndMajorChords() {
        // a-Moll: A2, A3, C4, E4, A4
        XCTAssertEqual(AudioAnalyzer.key(chord([110, 220, 261.63, 329.63, 440]))?.camelot, "8A")
        // C-Dur: C3, C4, E4, G4
        XCTAssertEqual(AudioAnalyzer.key(chord([130.81, 261.63, 329.63, 392]))?.camelot, "8B")
    }
}

final class RecommenderTests: XCTestCase {
    private func c(_ id: String, _ title: String, _ duration: TimeInterval = 300) -> VideoCandidate {
        TrackVersionTests.candidate(id, title, duration)
    }

    func testSongsInSeveralMixesRankHigher() {
        let pools = [
            [c("1", "A - One"), c("2", "B - Two"), c("3", "C - Three")],
            [c("4", "D - Four"), c("3", "C - Three"), c("5", "E - Five")],
            [c("3b", "C - Three (Official Audio)"), c("6", "F - Six")],
        ]
        let ranked = Recommender.rank(pools, context: Recommender.Context(), limit: 10)
        XCTAssertEqual(ranked.first?.version.song, "Three")
        XCTAssertEqual(ranked.first?.hits, 3)
        XCTAssertEqual(ranked.filter { $0.version.song == "Three" }.count, 1, "Gleiches Lied nur einmal")
    }

    func testFiltersSetsLiveShortAndExisting() {
        let pools = [[
            c("set", "DJ X - Boiler Room London DJ Set", 3600),
            c("short", "A - Teaser", 30),
            c("fast", "B - Song (Sped Up)", 150),
            c("have", "C - Already Here (Extended Mix)", 400),
            c("hidden", "D - Hidden", 300),
            c("ok", "E - Good One", 320),
        ]]
        var context = Recommender.Context()
        context.excludedSongs = Recommender.songKeys(of: ["C - Already Here"])
        context.excludedIDs = ["hidden"]
        let ranked = Recommender.rank(pools, context: context, limit: 10)
        XCTAssertEqual(ranked.map(\.id), ["ok"])
    }

    func testPrefersExtendedUploadOfSameSong() {
        let pools = [[c("radio", "A - Song (Radio Edit)", 190), c("ext", "A - Song (Extended Mix)", 400)]]
        var context = Recommender.Context()
        context.preference = .extended
        let ranked = Recommender.rank(pools, context: context, limit: 5)
        XCTAssertEqual(ranked.map(\.id), ["ext"])
        context.onlyLong = true
        XCTAssertEqual(Recommender.rank([[c("r", "B - Song (Radio Edit)", 190)]], context: context, limit: 5).count, 0)
    }

    func testArtistBiasMovesArtistsUp() {
        let pools = [[c("1", "Disliked - Song"), c("2", "Liked - Song")]]
        var context = Recommender.Context()
        context.artistBias = ["liked": 4, "disliked": -4]
        XCTAssertEqual(Recommender.rank(pools, context: context, limit: 5).first?.id, "2")
    }

    func testHarmonicOrderFollowsTheWheel() {
        let items = ["10A", "8A", "9A", "3B"].map { MusicalKey.parse($0)! }
        let ordered = SetPlanner.harmonicOrder(items, start: TrackAnalysis(bpm: 124, key: MusicalKey.parse("8A"))) {
            TrackAnalysis(bpm: 124, key: $0)
        }
        XCTAssertEqual(ordered.map(\.camelot), ["8A", "9A", "10A", "3B"])
        XCTAssertEqual(SetPlanner.tempoDistance(87, 174), 0)
        let tempos = SetPlanner.tempoOrder([128.0, 120, 124]) { TrackAnalysis(bpm: $0) }
        XCTAssertEqual(tempos, [120, 124, 128])
    }

    func testSetSummaryUsesMedianAndCommonKey() {
        let summary = SetBuilderViewModel.summary(of: [
            TrackAnalysis(bpm: 122, key: MusicalKey.parse("8A")),
            TrackAnalysis(bpm: 124, key: MusicalKey.parse("8A")),
            TrackAnalysis(bpm: 140, key: MusicalKey.parse("3B")),
        ])
        XCTAssertEqual(summary?.bpm, 124)
        XCTAssertEqual(summary?.key?.camelot, "8A")
    }
}

final class SpotifyAndExportTests: XCTestCase {
    func testSpotifyLinks() {
        let playlist = URL(string: "https://open.spotify.com/intl-de/playlist/37i9dQZF1DX0BcQWzuB7ZO?si=abc")!
        XCTAssertEqual(SpotifyEmbed.reference(in: playlist)?.id, "37i9dQZF1DX0BcQWzuB7ZO")
        XCTAssertEqual(SpotifyEmbed.reference(in: playlist)?.kind, .playlist)
        XCTAssertEqual(SpotifyEmbed.reference(in: URL(string: "https://open.spotify.com/album/4m2880jivSbbyEGAKfITCa")!)?.kind, .album)
        XCTAssertEqual(SpotifyEmbed.reference(in: URL(string: "spotify:playlist:abc123")!)?.id, "abc123")
        XCTAssertNil(SpotifyEmbed.reference(in: URL(string: "https://open.spotify.com/track/xyz")!))
        XCTAssertNil(SpotifyEmbed.reference(in: URL(string: "https://www.youtube.com/watch?v=x3rbGKihrOM")!))

        let parsed = ListParser.parse("Meine Playlist: https://open.spotify.com/playlist/37i9dQZF1DX0BcQWzuB7ZO?si=1")
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertTrue(parsed.entries[0].isSpotify)
    }

    func testSpotifyEmbedParsing() throws {
        let json = """
        {"props":{"pageProps":{"state":{"data":{"entity":{"name":"Dance Hits","trackList":[
          {"uri":"spotify:track:1","title":"Just A Little Bit More","subtitle":"Mau P","duration":214038},
          {"uri":"spotify:track:2","title":"Dreams - 2004 Remaster","subtitle":"Fleetwood Mac","duration":257800},
          {"uri":"spotify:track:3","title":"The Power - Extended Mix","subtitle":"Duke Dumont,\\u00a0Zak Abel","duration":381000}
        ]}}}}}}
        """
        let html = #"<html><script id="__NEXT_DATA__" type="application/json">"# + json + "</script></html>"
        let playlist = try SpotifyEmbed.parse(html: html, id: "x")
        XCTAssertEqual(playlist.name, "Dance Hits")
        XCTAssertEqual(playlist.tracks.count, 3)
        XCTAssertEqual(playlist.tracks[0].searchText, "Mau P - Just A Little Bit More")
        XCTAssertEqual(playlist.tracks[1].searchText, "Fleetwood Mac - Dreams")
        XCTAssertEqual(playlist.tracks[2].searchText, "Duke Dumont, Zak Abel - The Power (Extended Mix)")
        XCTAssertEqual(playlist.tracks[0].duration ?? 0, 214.038, accuracy: 0.01)
        XCTAssertFalse(playlist.mayBeTruncated)
        XCTAssertThrowsError(try SpotifyEmbed.parse(html: "<html></html>", id: "x"))
    }

    func testRekordboxXML() throws {
        let file = URL(fileURLWithPath: "/Volumes/DJ STICK/House/CamelPhat - Cola (Club Mix).mp3")
        let xml = RekordboxExporter.xml(
            entries: [RekordboxExporter.Entry(url: file, title: "Cola (Club Mix)", artist: "CamelPhat & Elderbrook", size: 9_000_000,
                                              bpm: 122, key: MusicalKey.parse("4A"))],
            playlists: [RekordboxExporter.Playlist(name: "House <Peak>", entries: [file])],
            version: "1.4"
        )
        let document = try XMLDocument(xmlString: xml)
        let track = try XCTUnwrap(try document.nodes(forXPath: "//COLLECTION/TRACK").first as? XMLElement)
        XCTAssertEqual(track.attribute(forName: "Location")?.stringValue, "file://localhost/Volumes/DJ%20STICK/House/CamelPhat%20-%20Cola%20(Club%20Mix).mp3")
        XCTAssertEqual(track.attribute(forName: "AverageBpm")?.stringValue, "122.00")
        XCTAssertEqual(track.attribute(forName: "Tonality")?.stringValue, "Fm")
        XCTAssertEqual(track.attribute(forName: "Artist")?.stringValue, "CamelPhat & Elderbrook")
        let playlist = try XCTUnwrap(try document.nodes(forXPath: "//NODE[@Type='1']").first as? XMLElement)
        XCTAssertEqual(playlist.attribute(forName: "Name")?.stringValue, "House <Peak>")
        XCTAssertEqual(playlist.attribute(forName: "Entries")?.stringValue, "1")
        XCTAssertEqual(try document.nodes(forXPath: "//NODE[@Type='1']/TRACK/@Key").first?.stringValue, "1")
    }

    func testID3TagsAreRead() {
        func frame(_ id: String, _ text: String) -> [UInt8] {
            let payload = [UInt8(3)] + Array(text.utf8)  // UTF-8
            let size = payload.count
            return Array(id.utf8) + [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF), 0, 0] + payload
        }
        let body = frame("TIT2", "Cola") + frame("TBPM", "122") + frame("TKEY", "Fm") + [UInt8](repeating: 0, count: 20)
        let size = body.count
        let header: [UInt8] = [0x49, 0x44, 0x33, 3, 0, 0,
                               UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)]
        let tags = ID3Reader.parse(header: Data(header), body: Data(body))
        XCTAssertEqual(tags?.bpm, 122)
        XCTAssertEqual(tags?.key?.camelot, "4A")
        XCTAssertNil(ID3Reader.parse(header: Data([0, 0, 0, 3, 0, 0, 0, 0, 0, 10]), body: Data(count: 10)))
    }

    func testMixLinksAndStickHints() {
        XCTAssertTrue(YouTubeLink.isMix(URL(string: "https://www.youtube.com/playlist?list=RDAMVMx3rbGKihrOM")!))
        XCTAssertFalse(YouTubeLink.isMix(URL(string: "https://www.youtube.com/playlist?list=PL123")!))
        XCTAssertEqual(YouTubeLink.mixURL(for: "abc").absoluteString, "https://www.youtube.com/watch?v=abc&list=RDAMVMabc")

        func volume(_ format: String) -> VolumeInfo {
            VolumeInfo(url: URL(fileURLWithPath: "/Volumes/X"), name: "X", uuid: nil, isExternal: true, fileSystem: format,
                       totalBytes: nil, availableBytes: nil)
        }
        XCTAssertNil(volume("MS-DOS (FAT32)").compatibilityHint)
        XCTAssertNotNil(volume("APFS").compatibilityHint)
        XCTAssertNotNil(volume("ExFAT").compatibilityHint)
        XCTAssertNotNil(volume("Mac OS Extended (Journaled)").compatibilityHint)
    }

    func testCleanRename() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("velvet-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Toto - Africa (Official HD Video).mp3")
        try Data(count: 10).write(to: file)
        let renamed = QueueViewModel.renameCleanly(file, title: "Toto - Africa (Official HD Video)", channel: "TotoVEVO")
        XCTAssertEqual(renamed.lastPathComponent, "Toto - Africa.mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        // Gibt es den Namen schon, wird durchnummeriert statt überschrieben.
        let second = folder.appendingPathComponent("Toto - Africa (Lyrics).mp3")
        try Data(count: 10).write(to: second)
        XCTAssertEqual(QueueViewModel.renameCleanly(second, title: "Toto - Africa (Lyrics)", channel: nil).lastPathComponent, "Toto - Africa 2.mp3")
    }
}
