import Foundation

/// Erkennt und vereinheitlicht YouTube-Links (watch, youtu.be, shorts, music, embed, playlists).
enum YouTubeLink {
    private static let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtu.be"
            || host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
    }

    static func isValidVideoID(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy { idCharacters.contains($0) }
    }

    static func videoID(in url: URL) -> String? {
        guard isYouTube(url), let host = url.host?.lowercased() else { return nil }
        let pathParts = url.path.split(separator: "/").map(String.init)
        var candidate: String?

        if host == "youtu.be" {
            candidate = pathParts.first
        } else if pathParts.first == "watch" {
            candidate = queryValue("v", in: url)
        } else if pathParts.count >= 2, ["shorts", "embed", "live", "v", "e"].contains(pathParts[0].lowercased()) {
            candidate = pathParts[1]
        }

        guard let id = candidate, isValidVideoID(id) else { return nil }
        return id
    }

    static func playlistID(in url: URL) -> String? {
        guard isYouTube(url), let list = queryValue("list", in: url), !list.isEmpty else { return nil }
        return list
    }

    /// Reiner Playlist-Link ohne bestimmtes Video.
    static func isPlaylist(_ url: URL) -> Bool {
        isYouTube(url) && videoID(in: url) == nil && playlistID(in: url) != nil
    }

    /// Kanal-Links (@name, /channel/…) würden ganze Kanäle laden – die unterstützt Velvet bewusst nicht.
    static func isChannel(_ url: URL) -> Bool {
        guard isYouTube(url), videoID(in: url) == nil, playlistID(in: url) == nil else { return false }
        guard let first = url.path.split(separator: "/").first.map(String.init) else { return false }
        return first.hasPrefix("@") || ["channel", "c", "user"].contains(first.lowercased())
    }

    /// Entfernt Zeitmarken, Playlist-Anhängsel u. Ä. – aus jedem Video-Link wird `watch?v=ID`.
    static func normalized(_ url: URL) -> URL {
        if let id = videoID(in: url) {
            return watchURL(id)
        }
        if isPlaylist(url), let list = playlistID(in: url),
           let encoded = list.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let playlist = URL(string: "https://www.youtube.com/playlist?list=\(encoded)") {
            return playlist
        }
        return url
    }

    static func watchURL(_ id: String) -> URL {
        URL(string: "https://www.youtube.com/watch?v=\(id)")!
    }

    static func thumbnailURL(_ id: String) -> URL {
        URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")!
    }

    /// Schlüssel zum Erkennen doppelter Links.
    static func dedupeKey(_ url: URL) -> String {
        if let id = videoID(in: url) { return "yt:\(id)" }
        if isPlaylist(url), let list = playlistID(in: url) { return "ytpl:\(list)" }
        return url.absoluteString.lowercased()
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}
