import Foundation

/// Ein Suchergebnis bzw. Playlist-Eintrag, den der Nutzer auswählen kann.
struct VideoCandidate: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let channel: String?
    let duration: TimeInterval?
    let viewCount: Int?
    let thumbnailURL: URL?
    let url: URL
    /// YouTube-Kanal – zum Folgen.
    var channelID: String? = nil

    var durationText: String? { Formatters.duration(duration) }
    var viewCountText: String? { Formatters.views(viewCount) }

    /// Interpret, Titel und Version aus dem Videotitel.
    var version: TrackVersion { TrackVersion.parse(title, channel: channel, duration: duration) }
}
