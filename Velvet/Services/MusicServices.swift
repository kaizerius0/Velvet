import Foundation

// MARK: - Spotify

/// Liest öffentliche Spotify-Playlists und -Alben über die Einbettungsseite – ohne Anmeldung.
///
/// Die Seite ist nicht offiziell dokumentiert und zeigt höchstens 100 Titel.
enum SpotifyEmbed {
    struct Track: Hashable, Sendable {
        /// „spotify:track:…“
        let id: String
        let title: String
        let artists: String
        let duration: TimeInterval?

        /// „Fred again.. - Marea (We've Lost Dancing)“ – der Suchbegriff für YouTube.
        var searchText: String {
            let version = TrackVersion.parse("\(artists) - \(title)")
            var text = "\(artists) - \(version.song)"
            if let mix = version.mix, !version.badges.isEmpty { text += " (\(mix))" }
            return text
        }
    }

    struct Playlist: Sendable {
        let id: String
        let name: String
        let tracks: [Track]

        /// Die Einbettung zeigt höchstens 100 Titel.
        var mayBeTruncated: Bool { tracks.count >= 100 }
    }

    enum Kind: String, Sendable {
        case playlist
        case album
    }

    enum ReadError: LocalizedError {
        case notFound
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notFound: return "Die Spotify-Playlist wurde nicht gefunden. Ist sie öffentlich?"
            case .unreadable: return "Die Spotify-Seite konnte nicht gelesen werden."
            }
        }
    }

    /// `open.spotify.com/playlist/…`, `/album/…` (auch mit Sprachpräfix wie `/intl-de/`) oder `spotify:playlist:…`.
    static func reference(in url: URL) -> (kind: Kind, id: String)? {
        if url.scheme == "spotify" {
            let parts = url.absoluteString.split(separator: ":").map(String.init)
            guard parts.count >= 3, let kind = Kind(rawValue: parts[1]) else { return nil }
            return (kind, parts[2])
        }
        guard let host = url.host?.lowercased(), host == "open.spotify.com" || host == "play.spotify.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init).filter { !$0.hasPrefix("intl-") && $0 != "embed" }
        guard parts.count >= 2, let kind = Kind(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        return (kind, parts[1])
    }

    static func isSupported(_ url: URL) -> Bool { reference(in: url) != nil }

    static func canonicalURL(kind: Kind, id: String) -> URL {
        URL(string: "https://open.spotify.com/\(kind.rawValue)/\(id)")!
    }

    static func load(_ url: URL) async throws -> Playlist {
        guard let reference = reference(in: url),
              let embed = URL(string: "https://open.spotify.com/embed/\(reference.kind.rawValue)/\(reference.id)") else {
            throw ReadError.notFound
        }
        var request = URLRequest(url: embed, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("de-DE,de;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { throw ReadError.notFound }
        return try parse(html: String(decoding: data, as: UTF8.self), id: reference.id)
    }

    /// Wertet das eingebettete JSON (`__NEXT_DATA__`) aus.
    static func parse(html: String, id: String) throws -> Playlist {
        guard let start = html.range(of: #"<script id="__NEXT_DATA__" type="application/json">"#),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else {
            throw ReadError.unreadable
        }
        let json = Data(html[start.upperBound..<end.lowerBound].utf8)
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let props = root["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let state = pageProps["state"] as? [String: Any],
              let dataNode = state["data"] as? [String: Any],
              let entity = dataNode["entity"] as? [String: Any] else {
            throw ReadError.unreadable
        }
        let name = (entity["name"] as? String) ?? (entity["title"] as? String) ?? "Spotify-Playlist"
        let list = entity["trackList"] as? [[String: Any]] ?? []
        let tracks: [Track] = list.compactMap { item in
            guard let title = item["title"] as? String, !title.isEmpty else { return nil }
            let artists = (item["subtitle"] as? String)?.replacingOccurrences(of: "\u{00a0}", with: " ") ?? ""
            let uri = (item["uri"] as? String) ?? "\(artists)|\(title)"
            let duration = (item["duration"] as? NSNumber).map { $0.doubleValue / 1000 }
            return Track(id: uri, title: title, artists: artists, duration: duration)
        }
        if tracks.isEmpty, entity["trackList"] == nil { throw ReadError.unreadable }
        return Playlist(id: id, name: name, tracks: tracks)
    }
}

// MARK: - Deezer

/// Die öffentliche Deezer-Schnittstelle (ohne Schlüssel): ähnliche Künstler und deren beliebteste Titel.
enum DeezerClient {
    struct Artist: Hashable, Sendable {
        let id: Int
        let name: String
        let pictureURL: URL?
    }

    struct Song: Hashable, Sendable {
        let title: String
        let artist: String
        let duration: TimeInterval?
        let coverURL: URL?

        var searchText: String { "\(artist) - \(title)" }
    }

    static func findArtist(_ name: String) async throws -> Artist? {
        let items = try await fetch("search/artist", query: ["q": name, "limit": "3"])
        let wanted = TrackVersion.primaryArtistKey(name)
        let artists = items.compactMap(artist(from:))
        return artists.first { TrackVersion.primaryArtistKey($0.name) == wanted } ?? artists.first
    }

    static func related(to artist: Artist, limit: Int = 10) async throws -> [Artist] {
        try await fetch("artist/\(artist.id)/related", query: ["limit": "\(limit)"]).compactMap(artist(from:))
    }

    static func topSongs(of artist: Artist, limit: Int = 5) async throws -> [Song] {
        try await fetch("artist/\(artist.id)/top", query: ["limit": "\(limit)"]).compactMap(song(from:))
    }

    // MARK: Intern

    private static func fetch(_ path: String, query: [String: String]) async throws -> [[String: Any]] {
        var components = URLComponents(string: "https://api.deezer.com/\(path)")!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: components.url!, timeoutInterval: 20))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return root["data"] as? [[String: Any]] ?? []
    }

    private static func artist(from item: [String: Any]) -> Artist? {
        guard let id = (item["id"] as? NSNumber)?.intValue, let name = item["name"] as? String else { return nil }
        return Artist(id: id, name: name, pictureURL: (item["picture_medium"] as? String).flatMap(URL.init(string:)))
    }

    private static func song(from item: [String: Any]) -> Song? {
        guard let title = item["title"] as? String,
              let artist = (item["artist"] as? [String: Any])?["name"] as? String else { return nil }
        let album = item["album"] as? [String: Any]
        return Song(
            title: title,
            artist: artist,
            duration: (item["duration"] as? NSNumber)?.doubleValue,
            coverURL: (album?["cover_medium"] as? String).flatMap(URL.init(string:))
        )
    }
}
