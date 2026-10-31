import Foundation

/// Ein YouTube-Kanal, dem du folgst – meist ein Label (Defected, Toolroom …).
struct FollowedChannel: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
}

/// Eine Spotify-Playlist, die mit einem Ordner verknüpft ist: Neue Titel landen auf Klick im Ordner.
struct SpotifyLink: Codable, Hashable, Identifiable, Sendable {
    /// Spotify-ID der Playlist bzw. des Albums.
    let id: String
    var url: String
    var name: String
    /// Zielordner – auf einem Stick über Laufwerks-ID und Pfad, damit er nach dem Umstecken wiedergefunden wird.
    var folderPath: String
    var volumeUUID: String?
    var relativeFolder: String?
    var folderName: String
    /// Spotify-Titel, die Velvet schon einmal geladen hat – bewusst gelöschte kommen nicht wieder.
    var loadedTrackIDs: Set<String> = []
    var lastChecked: Date?
}

/// Was Velvet über deinen Geschmack weiß – lokal in `discover.json`.
/// Gelernt wird aus dem, was du lädst, länger vorhörst, ausblendest oder schnell wieder löschst.
@MainActor
final class TasteStore: ObservableObject {
    private struct Stored: Codable {
        var hiddenVideoIDs: Set<String> = []
        var artistScores: [String: Double] = [:]
        var listenedVideoIDs: Set<String> = []
        var followedChannels: [FollowedChannel] = []
        var spotifyLinks: [SpotifyLink] = []
        /// Titel ohne bekannte Video-ID (z. B. von Hand auf den Stick kopiert) → gefundenes Video.
        var resolvedVideoIDs: [String: String] = [:]
    }

    @Published private(set) var hiddenVideoIDs: Set<String> = []
    @Published private(set) var artistScores: [String: Double] = [:]
    @Published private(set) var followedChannels: [FollowedChannel] = []
    @Published private(set) var spotifyLinks: [SpotifyLink] = []
    private(set) var listenedVideoIDs: Set<String> = []
    private(set) var resolvedVideoIDs: [String: String] = [:]

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    /// Bekannte Labels zum schnellen Folgen.
    static let suggestedLabels: [FollowedChannel] = [
        FollowedChannel(id: "UCnOxaDXBiBXg9Nn9hKWu6aw", name: "Defected Records"),
        FollowedChannel(id: "UCpiZh3AGeTygzfmUgioOFFg", name: "Toolroom Records"),
        FollowedChannel(id: "UCFZ75Bg73NJnJgmeUX9l62g", name: "Selected."),
        FollowedChannel(id: "UCpDJl2EmP7Oh90Vylx0dZtA", name: "Spinnin' Records"),
        FollowedChannel(id: "UCbDgBFAketcO26wz-pR6OKA", name: "Anjunadeep"),
        FollowedChannel(id: "UC8eXqFK48M3bBSmMO1FRgIA", name: "Drumcode"),
        FollowedChannel(id: "UCBamg4BvhCkztN7bPmR14bg", name: "Hot Creations"),
        FollowedChannel(id: "UCYt3m8rbcXjmWbEei8xGBNA", name: "Repopulate Mars"),
        FollowedChannel(id: "UCGZXYc32ri4D0gSLPf2pZXQ", name: "Armada Music"),
    ]

    nonisolated static var defaultFileURL: URL {
        #if DEBUG
        let name = "discover-dev.json"
        #else
        let name = "discover.json"
        #endif
        let root = (try? YtDlpInstaller.supportRoot()) ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(name)
    }

    init(fileURL: URL = TasteStore.defaultFileURL) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let stored = try? decoder.decode(Stored.self, from: data) {
            hiddenVideoIDs = stored.hiddenVideoIDs
            artistScores = stored.artistScores
            listenedVideoIDs = stored.listenedVideoIDs
            followedChannels = stored.followedChannels
            spotifyLinks = stored.spotifyLinks
            resolvedVideoIDs = stored.resolvedVideoIDs
        }
    }

    // MARK: Signale

    /// „Nicht interessiert“ – das Video verschwindet, der Künstler rutscht etwas nach hinten.
    func hide(_ candidate: VideoCandidate) {
        hiddenVideoIDs.insert(candidate.id)
        adjust(candidate, by: -1.5)
        save()
    }

    /// Länger als 30 Sekunden vorgehört.
    func recordListen(_ candidate: VideoCandidate) {
        guard listenedVideoIDs.insert(candidate.id).inserted else { return }
        adjust(candidate, by: 0.5)
        save()
    }

    /// Aus „Entdecken“ oder einem Set geladen.
    func recordAdd(_ candidate: VideoCandidate) {
        adjust(candidate, by: 1)
        save()
    }

    func isHidden(_ videoID: String) -> Bool { hiddenVideoIDs.contains(videoID) }

    func unhideAll() {
        hiddenVideoIDs.removeAll()
        save()
    }

    /// Vorliebe je Künstler – aus Signalen und dem Verlauf (geladen = +, schnell wieder gelöscht = −).
    /// Einmal pro Durchlauf berechnen, nicht pro Vorschlag.
    func artistBiases(history: [HistoryEntry]) -> [String: Double] {
        var scores = artistScores
        for entry in history {
            guard let key = TrackVersion.parse(entry.title).artistKey else { continue }
            switch entry.state {
            case .downloaded:
                scores[key, default: 0] += 1
            case .deleted:
                if let removed = entry.stateDate, removed.timeIntervalSince(entry.date) < 3 * 24 * 3600 {
                    scores[key, default: 0] -= 1.5
                }
            case .replaced:
                break
            }
        }
        return scores.mapValues { min(max($0, -4), 4) }
    }

    private func adjust(_ candidate: VideoCandidate, by delta: Double) {
        guard let key = candidate.version.artistKey else { return }
        artistScores[key, default: 0] += delta
    }

    // MARK: Kanäle

    func isFollowing(_ channelID: String) -> Bool {
        followedChannels.contains { $0.id == channelID }
    }

    func follow(_ channel: FollowedChannel) {
        guard !isFollowing(channel.id) else { return }
        followedChannels.append(channel)
        save()
    }

    func unfollow(_ channelID: String) {
        followedChannels.removeAll { $0.id == channelID }
        save()
    }

    // MARK: Spotify

    func addSpotifyLink(_ link: SpotifyLink) {
        spotifyLinks.removeAll { $0.id == link.id && $0.folderPath == link.folderPath }
        spotifyLinks.append(link)
        save()
    }

    func updateSpotifyLink(_ link: SpotifyLink) {
        guard let index = spotifyLinks.firstIndex(where: { $0.id == link.id && $0.folderPath == link.folderPath }) else { return }
        spotifyLinks[index] = link
        save()
    }

    func removeSpotifyLink(_ link: SpotifyLink) {
        spotifyLinks.removeAll { $0.id == link.id && $0.folderPath == link.folderPath }
        save()
    }

    // MARK: Zuordnungen

    func resolvedVideoID(forTitle title: String) -> String? {
        resolvedVideoIDs[ListParser.searchKey(title)]
    }

    func remember(videoID: String, forTitle title: String) {
        resolvedVideoIDs[ListParser.searchKey(title)] = videoID
        save()
    }

    // MARK: Speichern

    private func save() {
        saveTask?.cancel()
        let stored = Stored(
            hiddenVideoIDs: hiddenVideoIDs,
            artistScores: artistScores,
            listenedVideoIDs: listenedVideoIDs,
            followedChannels: followedChannels,
            spotifyLinks: spotifyLinks,
            resolvedVideoIDs: resolvedVideoIDs
        )
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(stored) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let stored = Stored(
            hiddenVideoIDs: hiddenVideoIDs, artistScores: artistScores, listenedVideoIDs: listenedVideoIDs,
            followedChannels: followedChannels, spotifyLinks: spotifyLinks, resolvedVideoIDs: resolvedVideoIDs
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
