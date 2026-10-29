import Foundation

/// Ein Suchergebnis bzw. Playlist-Eintrag, den der Nutzer auswählen kann.
struct VideoCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let channel: String?
    let duration: TimeInterval?
    let viewCount: Int?
    let thumbnailURL: URL?
    let url: URL

    var durationText: String? { Formatters.duration(duration) }
    var viewCountText: String? { Formatters.views(viewCount) }
}
