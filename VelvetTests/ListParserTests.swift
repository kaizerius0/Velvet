import XCTest
@testable import Velvet

final class ListParserTests: XCTestCase {
    private func queries(_ text: String) -> [String] {
        ListParser.parse(text).entries.map(\.displayText)
    }

    private func urls(_ text: String) -> [String] {
        ListParser.parse(text).entries.compactMap { $0.url?.absoluteString }
    }

    func testNumberedListsInAllStyles() {
        let text = """
        1. Queen - Bohemian Rhapsody
        2) Toto – Africa
        (3) Daft Punk: Get Lucky
        [4] a-ha - Take On Me
        #5 Nirvana - Smells Like Teen Spirit
        06. Oasis - Wonderwall
        Nr. 7 Michael Jackson - Billie Jean
        """
        XCTAssertEqual(queries(text), [
            "Queen - Bohemian Rhapsody",
            "Toto – Africa",
            "Daft Punk: Get Lucky",
            "a-ha - Take On Me",
            "Nirvana - Smells Like Teen Spirit",
            "Oasis - Wonderwall",
            "Michael Jackson - Billie Jean",
        ])
    }

    func testBulletsCheckboxesAndEmojis() {
        let text = """
        - Queen Bohemian Rhapsody
        • Toto Africa
        * Daft Punk Get Lucky
        – a-ha take on me
        - [ ] Eminem Lose Yourself
        - [x] Adele Hello
        🎵 Coldplay Yellow 🎶
        ✅ Linkin Park Numb
        → Muse Uprising
        """
        XCTAssertEqual(queries(text), [
            "Queen Bohemian Rhapsody",
            "Toto Africa",
            "Daft Punk Get Lucky",
            "a-ha take on me",
            "Eminem Lose Yourself",
            "Adele Hello",
            "Coldplay Yellow",
            "Linkin Park Numb",
            "Muse Uprising",
        ])
    }

    func testNumbersThatBelongToTheTitleAreKept() {
        let text = """
        1. 99 Luftballons - Nena
        2. 7 Rings - Ariana Grande
        3. 21 Guns - Green Day
        4. 5:15 - The Who
        """
        XCTAssertEqual(queries(text), [
            "99 Luftballons - Nena",
            "7 Rings - Ariana Grande",
            "21 Guns - Green Day",
            "5:15 - The Who",
        ])
        // Ohne Nummerierung bleiben einzelne Zahlen-Titel unangetastet.
        XCTAssertEqual(queries("99 Luftballons\n7 Rings\nYellow"), ["99 Luftballons", "7 Rings", "Yellow"])
    }

    func testSequentialBareNumbersAndNumberDashesAreStripped() {
        XCTAssertEqual(queries("1 Queen - Bohemian Rhapsody\n2 Toto - Africa\n3 Oasis - Wonderwall"), [
            "Queen - Bohemian Rhapsody", "Toto - Africa", "Oasis - Wonderwall",
        ])
        XCTAssertEqual(queries("01 - Queen - Bohemian Rhapsody\n02 - Toto - Africa"), [
            "Queen - Bohemian Rhapsody", "Toto - Africa",
        ])
    }

    func testTracklistTimestampsAndDurations() {
        let tracklist = """
        0:00 Intro
        3:45 Queen - Bohemian Rhapsody
        9:40 - Toto - Africa
        1:02:10 Oasis - Wonderwall
        """
        XCTAssertEqual(queries(tracklist), ["Intro", "Queen - Bohemian Rhapsody", "Toto - Africa", "Oasis - Wonderwall"])

        let durations = """
        Queen - Bohemian Rhapsody (5:55)
        Toto - Africa 4:55
        Oasis - Wonderwall [4:18]
        """
        XCTAssertEqual(queries(durations), ["Queen - Bohemian Rhapsody", "Toto - Africa", "Oasis - Wonderwall"])
    }

    func testExtraTextHeadingsAndProseAreIgnored() {
        let text = """
        Hier ist meine Playlist für Samstag:

        ## Rock
        1. Queen - Bohemian Rhapsody
        2. AC/DC - Highway to Hell
        ---
        Das sind die Lieder, die unbedingt auf der Party laufen müssen.
        Pop:
        3. Dua Lipa - Levitating
        """
        let result = ListParser.parse(text)
        XCTAssertEqual(result.entries.map(\.displayText), [
            "Queen - Bohemian Rhapsody", "AC/DC - Highway to Hell", "Dua Lipa - Levitating",
        ])
        XCTAssertEqual(result.ignoredLineCount, 5)
    }

    func testMarkdownFromChatbots() {
        let text = """
        1. **Queen** – *Bohemian Rhapsody*
        2. **Toto** – „Africa“
        3. `Daft Punk - Get Lucky`
        """
        XCTAssertEqual(queries(text), ["Queen – Bohemian Rhapsody", "Toto – „Africa“", "Daft Punk - Get Lucky"])
    }

    func testQuotesAndTrailingPunctuation() {
        XCTAssertEqual(queries("\"Bohemian Rhapsody\",\n„Africa“;\n'Wonderwall' -"), ["Bohemian Rhapsody", "Africa", "Wonderwall"])
    }

    func testDuplicatesAreRemoved() {
        let result = ListParser.parse("Queen - Bohemian Rhapsody\nqueen – bohemian rhapsody\nBeyoncé Halo\nBeyonce Halo\nhttps://youtu.be/dQw4w9WgXcQ\nhttps://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42")
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(result.duplicateCount, 3)
    }

    func testYouTubeLinksInAllForms() {
        let text = """
        https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123&index=2
        youtu.be/9bZkp7q19f0?si=abc
        https://youtube.com/shorts/aqz-KE-bpKQ
        https://music.youtube.com/watch?v=fJ9rUzIMcZQ&feature=share
        www.youtube.com/embed/kJQP7kiw5Fk
        https://m.youtube.com/watch?v=OPf0YbXqDm0.
        """
        XCTAssertEqual(urls(text), [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/watch?v=9bZkp7q19f0",
            "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
            "https://www.youtube.com/watch?v=fJ9rUzIMcZQ",
            "https://www.youtube.com/watch?v=kJQP7kiw5Fk",
            "https://www.youtube.com/watch?v=OPf0YbXqDm0",
        ])
    }

    func testLinksWithLabelsAndMarkdownLinks() {
        let result = ListParser.parse("""
        1. Rick Astley - Never Gonna Give You Up: https://youtu.be/dQw4w9WgXcQ
        [PSY - Gangnam Style](https://www.youtube.com/watch?v=9bZkp7q19f0)
        """)
        XCTAssertEqual(result.entries.map(\.label), ["Rick Astley - Never Gonna Give You Up", "PSY - Gangnam Style"])
        XCTAssertEqual(result.entries.map { $0.url?.absoluteString }, [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/watch?v=9bZkp7q19f0",
        ])
    }

    func testPlaylistLinksAreRecognized() {
        let entry = ListParser.parse("https://www.youtube.com/playlist?list=PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI").entries.first
        XCTAssertEqual(entry?.isPlaylist, true)
        XCTAssertEqual(entry?.url?.absoluteString, "https://www.youtube.com/playlist?list=PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI")
    }

    func testMixedTitlesAndLinks() {
        let result = ListParser.parse("Queen - Bohemian Rhapsody\nhttps://youtu.be/dQw4w9WgXcQ\nToto Africa")
        XCTAssertEqual(result.searchCount, 2)
        XCTAssertEqual(result.linkCount, 1)
    }

    func testSingleLineLists() {
        XCTAssertEqual(queries("1. Queen Bohemian Rhapsody 2. Toto Africa 3. Oasis Wonderwall"), [
            "Queen Bohemian Rhapsody", "Toto Africa", "Oasis Wonderwall",
        ])
        XCTAssertEqual(queries("Queen Bohemian Rhapsody; Toto Africa; Oasis Wonderwall"), [
            "Queen Bohemian Rhapsody", "Toto Africa", "Oasis Wonderwall",
        ])
        XCTAssertEqual(queries("Queen Bohemian Rhapsody, Toto Africa, Oasis Wonderwall"), [
            "Queen Bohemian Rhapsody", "Toto Africa", "Oasis Wonderwall",
        ])
        XCTAssertEqual(queries("Queen - Bohemian Rhapsody, Toto - Africa"), ["Queen - Bohemian Rhapsody", "Toto - Africa"])
        // Ein einzelner Titel mit Komma bleibt ganz.
        XCTAssertEqual(queries("Hello, Goodbye"), ["Hello, Goodbye"])
        XCTAssertEqual(queries("Queen - Bohemian Rhapsody, Live Aid 1985"), ["Queen - Bohemian Rhapsody, Live Aid 1985"])
    }

    func testTabSeparatedSpreadsheet() {
        let text = "1\tQueen\tBohemian Rhapsody\t5:55\n2\tToto\tAfrica\t4:55\n3\tOasis\tWonderwall\t4:18"
        XCTAssertEqual(queries(text), ["Queen - Bohemian Rhapsody", "Toto - Africa", "Oasis - Wonderwall"])
    }

    func testGermanExcelCSVWithHeader() {
        let text = "Titel;Interpret;Album\nBohemian Rhapsody;Queen;A Night at the Opera\nAfrica;Toto;Toto IV"
        XCTAssertEqual(queries(text), ["Queen - Bohemian Rhapsody", "Toto - Africa"])
    }

    func testExportifyCSV() {
        let text = """
        "Track URI","Track Name","Artist Name(s)","Album Name","Duration (ms)"
        "spotify:track:4u7EnebtmKWzUH433cf5Qv","Bohemian Rhapsody - Remastered 2011","Queen","A Night At The Opera","354320"
        "spotify:track:2374M0fQpWi3dLnB54qaLX","Africa","TOTO","Toto IV","295893"
        "spotify:track:1BxfuPKGuaTgP7aM0Bbdwr","Cruel Summer","Taylor Swift","Lover","178426"
        """
        XCTAssertEqual(queries(text), [
            "Queen - Bohemian Rhapsody - Remastered 2011",
            "TOTO - Africa",
            "Taylor Swift - Cruel Summer",
        ])
    }

    func testAppleMusicExport() {
        let text = "Name\tArtist\tComposer\tAlbum\tTime\nBohemian Rhapsody\tQueen\tFreddie Mercury\tA Night at the Opera\t354\nAfrica\tToto\tDavid Paich\tToto IV\t295"
        XCTAssertEqual(queries(text), ["Queen - Bohemian Rhapsody", "Toto - Africa"])
    }

    func testMarkdownTable() {
        let text = """
        Hier deine Liste:
        | # | Titel | Interpret |
        |---|-------|-----------|
        | 1 | Bohemian Rhapsody | Queen |
        | 2 | Africa | Toto |
        """
        XCTAssertEqual(queries(text), ["Queen - Bohemian Rhapsody", "Toto - Africa"])
    }

    func testTableWithLinkColumn() {
        let text = "Titel,Link\nNever Gonna Give You Up,https://youtu.be/dQw4w9WgXcQ\nGangnam Style,https://youtu.be/9bZkp7q19f0"
        let result = ListParser.parse(text)
        XCTAssertEqual(result.entries.map(\.label), ["Never Gonna Give You Up", "Gangnam Style"])
        XCTAssertEqual(result.linkCount, 2)
    }

    func testM3UPlaylist() {
        let text = """
        #EXTM3U
        #EXTINF:354,Queen - Bohemian Rhapsody
        /Users/me/Music/Queen/Bohemian Rhapsody.mp3
        #EXTINF:295,Toto - Africa
        /Users/me/Music/Toto/Africa.mp3
        /Users/me/Music/Oasis%20-%20Wonderwall.m4a
        """
        XCTAssertEqual(queries(text), ["Queen - Bohemian Rhapsody", "Toto - Africa", "Oasis - Wonderwall"])
    }

    func testWindowsLineEndingsEntitiesAndInvisibleCharacters() {
        let text = "Simon &amp; Garfunkel - The Boxer\r\nGuns N&#39; Roses - Patience\r\n\u{FEFF}Toto\u{00A0}Africa\u{200B}\r\n"
        XCTAssertEqual(queries(text), ["Simon & Garfunkel - The Boxer", "Guns N' Roses - Patience", "Toto Africa"])
    }

    func testTitlePrefixesAreRemoved() {
        XCTAssertEqual(queries("Titel: Bohemian Rhapsody\nSong: Africa"), ["Bohemian Rhapsody", "Africa"])
    }

    func testEmptyAndNoiseInput() {
        XCTAssertTrue(ListParser.parse("").entries.isEmpty)
        XCTAssertTrue(ListParser.parse("\n\n  \n---\n***\n1.\n2.\n").entries.isEmpty)
    }

    func testManualLinkDetection() {
        XCTAssertEqual(ListParser.link(from: "  https://youtu.be/dQw4w9WgXcQ  ")?.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(ListParser.link(from: "https://vimeo.com/76979871")?.absoluteString, "https://vimeo.com/76979871")
        XCTAssertNil(ListParser.link(from: "kein link"))
    }
}

final class YouTubeLinkTests: XCTestCase {
    func testVideoIDs() {
        XCTAssertEqual(YouTubeLink.videoID(in: URL(string: "https://youtu.be/dQw4w9WgXcQ?t=10")!), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeLink.videoID(in: URL(string: "https://www.youtube.com/live/jfKfPfyJRdk")!), "jfKfPfyJRdk")
        XCTAssertNil(YouTubeLink.videoID(in: URL(string: "https://www.youtube.com/watch?v=short")!))
        XCTAssertNil(YouTubeLink.videoID(in: URL(string: "https://example.com/watch?v=dQw4w9WgXcQ")!))
    }

    func testChannelsAndPlaylists() {
        XCTAssertTrue(YouTubeLink.isChannel(URL(string: "https://www.youtube.com/@queenofficial")!))
        XCTAssertTrue(YouTubeLink.isChannel(URL(string: "https://www.youtube.com/channel/UCiMhD4jzUqG-IgPzUmmytRQ")!))
        XCTAssertFalse(YouTubeLink.isPlaylist(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL1")!))
        XCTAssertTrue(YouTubeLink.isPlaylist(URL(string: "https://www.youtube.com/playlist?list=PL1")!))
    }
}

final class TextFileLoaderTests: XCTestCase {
    func testEncodings() {
        let text = "Beyoncé – Halo\nMötley Crüe – Kickstart My Heart"
        XCTAssertEqual(TextFileLoader.decode(Data(text.utf8)), text)
        XCTAssertEqual(TextFileLoader.decode(text.data(using: .utf16)!), text)
        XCTAssertEqual(TextFileLoader.decode(text.data(using: .utf16LittleEndian)!), text)
        XCTAssertEqual(TextFileLoader.decode("Beyoncé".data(using: .windowsCP1252)!), "Beyoncé")
    }
}
