import Foundation

/// Eine Reihe in „Entdecken“.
struct DiscoverShelf: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        /// „Weil du … geladen hast“ – der YouTube-Mix eines geladenen Titels.
        case because
        /// „Mix für Ordner“ – aus mehreren Titeln eines Ordners, „+“ lädt direkt dorthin.
        case folder
        /// Neue Uploads von Labels und Kanälen, denen du folgst.
        case channels
        /// Beliebte Titel von Künstlern, die schon auf deinem Stick sind (Deezer → YouTube).
        case artists
    }

    let id: String
    var kind: Kind
    var title: String
    var subtitle: String?
    var items: [Suggestion]
    /// Zielordner (bei „Mix für Ordner“).
    var folderPath: String?

    var folder: URL? { folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
}

/// Zustand einer verknüpften Spotify-Playlist.
struct SpotifyLinkState: Equatable {
    var isChecking = false
    var total = 0
    var missing: [SpotifyEmbed.Track] = []
    var mayBeTruncated = false
    var error: String?
    /// Der Stick mit dem Zielordner ist nicht eingesteckt.
    var isOffline = false
}

/// „Entdecken“ – Spotify-Gefühl für den Stick: Reihen mit Vorschlägen aus dem, was du schon geladen hast,
/// neuen Titeln deiner Labels, Spotify-Playlists, die Velvet abgleicht, und dem Set-Builder.
@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published private(set) var shelves: [DiscoverShelf] = []
    @Published private(set) var relatedArtists: [String] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var status: String?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var spotifyStates: [String: SpotifyLinkState] = [:]
    /// In dieser Sitzung geladene Vorschläge – zeigen „Geladen“ statt „+“, auch wenn die Liste aufgeräumt ist.
    @Published private(set) var addedIDs: Set<String> = []
    /// Der geöffnete Set-Builder (ersetzt die Startseite von „Entdecken“).
    @Published var setBuilder: SetBuilderViewModel?

    let settings: AppSettings
    let tools: ToolManager
    let history: HistoryStore
    let library: LibraryViewModel
    let queue: QueueViewModel
    let taste: TasteStore
    let analysis: AnalysisCenter

    private var refreshTask: Task<Void, Never>?
    private var mixCache: [String: (date: Date, entries: [VideoCandidate])] = [:]
    private let limiter = AsyncLimiter(limit: 2)
    private let cacheURL: URL

    nonisolated static var defaultCacheURL: URL {
        #if DEBUG
        let name = "discover-cache-dev.json"
        #else
        let name = "discover-cache.json"
        #endif
        let root = (try? YtDlpInstaller.supportRoot()) ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(name)
    }

    init(settings: AppSettings, tools: ToolManager, history: HistoryStore, library: LibraryViewModel,
         queue: QueueViewModel, taste: TasteStore, analysis: AnalysisCenter, cacheURL: URL = DiscoverViewModel.defaultCacheURL) {
        self.settings = settings
        self.tools = tools
        self.history = history
        self.library = library
        self.queue = queue
        self.taste = taste
        self.analysis = analysis
        self.cacheURL = cacheURL
        loadCache()
    }

    /// Neue Titel in verknüpften Spotify-Playlists – für die Zahl in der Seitenleiste.
    var newSpotifyTrackCount: Int {
        spotifyStates.values.reduce(0) { $0 + $1.missing.count }
    }

    var hasHistory: Bool {
        history.entries.contains { $0.state == .downloaded && $0.videoID != nil } || !library.trackIndex.isEmpty
    }

    // MARK: - Auf den Stick

    /// Wohin „+“ lädt, wenn die Reihe keinen eigenen Ordner hat.
    var target: URL? { settings.addTarget }

    /// Lädt einen Vorschlag – in den Ordner der Reihe oder das gewählte Ziel. Fragt, wenn noch keins gewählt ist.
    @discardableResult
    func add(_ candidate: VideoCandidate, to folder: URL? = nil) -> Bool {
        guard let destination = folder ?? target ?? chooseTarget() else { return false }
        guard !queue.isQueued(candidate.id, to: destination) else { return true }
        queue.add(candidate: candidate, query: nil, to: destination)
        taste.recordAdd(candidate)
        addedIDs.insert(candidate.id)
        return true
    }

    /// Alle Vorschläge einer Reihe.
    func addAll(_ shelf: DiscoverShelf) {
        guard let destination = shelf.folder ?? target ?? chooseTarget() else { return }
        let candidates = shelf.items.map(\.candidate).filter { !queue.isQueued($0.id, to: destination) }
        queue.add(candidates: candidates, to: destination)
        candidates.forEach(taste.recordAdd)
        addedIDs.formUnion(candidates.map(\.id))
        library.showNotice("\(Formatters.count(candidates.count, "Titel wird", "Titel werden")) in „\(library.locationText(forFolder: destination))“ geladen")
    }

    func chooseTarget() -> URL? {
        guard let url = library.chooseFolder(title: "Wohin sollen die Titel?", startingAt: target) else { return nil }
        settings.addTarget = url
        return url
    }

    /// „Nicht interessiert“
    func hide(_ candidate: VideoCandidate) {
        taste.hide(candidate)
        for index in shelves.indices {
            shelves[index].items.removeAll { $0.id == candidate.id }
        }
        shelves.removeAll { $0.items.isEmpty }
        saveCache()
    }

    // MARK: - Set-Builder

    func startSet(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        openSet(.query(trimmed))
    }

    func startSet(from candidate: VideoCandidate) {
        openSet(.candidate(candidate))
    }

    func startSet(from track: Track) {
        openSet(.track(track))
    }

    /// „Passende ergänzen“: ein Ordner wird um ähnliche Titel erweitert.
    func extend(_ folder: LibraryFolder) {
        openSet(.folder(folder))
    }

    private func openSet(_ source: SetBuilderViewModel.Source) {
        setBuilder?.cancel()
        let model = SetBuilderViewModel(source: source, discover: self)
        setBuilder = model
        model.start()
    }

    func markAdded(_ candidates: [VideoCandidate]) {
        addedIDs.formUnion(candidates.map(\.id))
    }

    func closeSet() {
        setBuilder?.cancel()
        setBuilder = nil
    }

    // MARK: - Aktualisieren

    /// Beim Öffnen: nur neu laden, wenn die Vorschläge älter als sechs Stunden sind.
    func refreshIfNeeded() {
        guard tools.isReady, !isRefreshing else { return }
        if shelves.isEmpty || lastRefresh.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true {
            refresh()
        } else {
            checkSpotifyLinks()
        }
    }

    func refresh() {
        guard tools.downloadManager != nil else { return }
        refreshTask?.cancel()
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
            guard !Task.isCancelled else { return }
            self.isRefreshing = false
            self.status = nil
            self.lastRefresh = Date()
            self.saveCache()
        }
        checkSpotifyLinks()
    }

    private func performRefresh() async {
        guard let manager = tools.downloadManager else { return }
        let cookies = settings.cookieBrowser
        let context = makeContext()
        var keep = Set<String>()

        // 1. „Weil du … geladen hast“
        status = "Velvet hört sich um …"
        let seeds = recentSeeds(limit: 3)
        for seed in seeds {
            guard !Task.isCancelled else { return }
            let mix = await cachedMix(seed.videoID, manager: manager, cookies: cookies)
            var seedContext = context
            seedContext.excludedIDs.insert(seed.videoID)
            seedContext.excludedSongs.insert(TrackVersion.parse(seed.title).baseKey)
            let items = Recommender.rank([mix], context: seedContext, limit: 14)
            guard items.count >= 3 else { continue }
            let id = "because-\(seed.videoID)"
            keep.insert(id)
            publish(DiscoverShelf(id: id, kind: .because, title: "Weil du „\(TrackVersion.parse(seed.title).song)“ geladen hast",
                                  subtitle: "Ähnlich klingende Titel aus dem YouTube-Mix", items: items))
        }

        // 2. „Mix für Ordner“
        for folder in candidateFolders(limit: 3) {
            guard !Task.isCancelled else { return }
            status = "Mix für „\(folder.name)“ …"
            let tracks = library.trackIndex.map(\.track).filter { $0.folderID == folder.id }.sorted { $0.added > $1.added }
            var pools: [[VideoCandidate]] = []
            var seedIDs = Set<String>()
            for track in tracks.prefix(4) {
                guard let id = await videoID(for: track, manager: manager, cookies: cookies) else { continue }
                seedIDs.insert(id)
                pools.append(await cachedMix(id, manager: manager, cookies: cookies))
            }
            guard !pools.isEmpty else { continue }
            var folderContext = context
            folderContext.excludedIDs.formUnion(seedIDs)
            let items = Recommender.rank(pools, context: folderContext, limit: 14)
            guard items.count >= 3 else { continue }
            let id = "folder-\(folder.id)"
            keep.insert(id)
            publish(DiscoverShelf(id: id, kind: .folder, title: "Mix für „\(folder.name)“",
                                  subtitle: "Passt zu \(library.locationText(forFolder: folder.url)) – „+“ lädt direkt dorthin",
                                  items: items, folderPath: folder.url.standardizedFileURL.path))
        }

        // 3. Labels und Kanäle
        if !taste.followedChannels.isEmpty {
            status = "Neues von deinen Labels …"
            var pools: [[VideoCandidate]] = []
            for channel in taste.followedChannels.prefix(10) {
                guard !Task.isCancelled else { return }
                if let uploads = try? await limiter.run({ try await manager.channelUploads(channel.id, limit: 10, cookies: cookies) }) {
                    pools.append(uploads)
                }
            }
            let items = Recommender.rank(pools, context: context, limit: 18)
            if !items.isEmpty {
                keep.insert("channels")
                publish(DiscoverShelf(id: "channels", kind: .channels, title: "Neu von deinen Labels",
                                      subtitle: taste.followedChannels.prefix(4).map(\.name).joined(separator: ", "), items: items))
            }
        }

        // 4. Künstler auf dem Stick (Deezer) und ähnliche Künstler
        status = "Künstler auf deinem Stick …"
        let artists = topLibraryArtists(limit: 3)
        let preference = settings.preferredVersion
        var artistPool: [VideoCandidate] = []
        var related: [String] = []
        let knownArtists = Set(libraryArtistCounts().keys)
        for artist in artists {
            guard !Task.isCancelled else { return }
            guard let found = try? await DeezerClient.findArtist(artist) else { continue }
            if related.count < 12, let similar = try? await DeezerClient.related(to: found, limit: 8) {
                for name in similar.map(\.name) where !related.contains(name) {
                    guard let key = TrackVersion.primaryArtistKey(name), !knownArtists.contains(key) else { continue }
                    related.append(name)
                }
            }
            guard let songs = try? await DeezerClient.topSongs(of: found, limit: 4) else { continue }
            for song in songs {
                let key = TrackVersion.parse(song.searchText).baseKey
                guard !context.excludedSongs.contains(key) else { continue }
                if let results = try? await limiter.run({
                    try await manager.search(song.searchText, cookies: cookies, preferring: preference)
                }), !results.isEmpty {
                    artistPool.append(QueueViewModel.bestPick(results, expectedDuration: nil))
                }
            }
        }
        relatedArtists = Array(related.prefix(12))
        let artistItems = Recommender.rank([artistPool], context: context, limit: 14)
        if !artistItems.isEmpty {
            keep.insert("artists")
            publish(DiscoverShelf(id: "artists", kind: .artists, title: "Mehr von Künstlern auf deinem Stick",
                                  subtitle: artists.joined(separator: ", "), items: artistItems))
        }

        // Reihen, die es nicht mehr gibt (z. B. gelöschter Ordner), entfernen.
        if !Task.isCancelled { shelves.removeAll { !keep.contains($0.id) } }
    }

    /// Reihe einfügen oder ersetzen – die Reihenfolge bleibt stabil.
    private func publish(_ shelf: DiscoverShelf) {
        if let index = shelves.firstIndex(where: { $0.id == shelf.id }) {
            shelves[index] = shelf
        } else {
            shelves.append(shelf)
        }
    }

    // MARK: - Bausteine

    func makeContext(onlyLong: Bool = false) -> Recommender.Context {
        var context = Recommender.Context()
        context.preference = settings.preferredVersion
        context.excludedIDs = taste.hiddenVideoIDs
        for entry in history.entries where entry.state == .downloaded {
            if let id = entry.videoID { context.excludedIDs.insert(id) }
        }
        let titles = library.trackIndex.map(\.track.title) + history.entries.filter { $0.state == .downloaded }.map(\.title)
        context.excludedSongs = Recommender.songKeys(of: titles)
        context.artistBias = taste.artistBiases(history: history.entries)
        context.onlyLong = onlyLong
        return context
    }

    /// YouTube-Mix eines Videos – sechs Stunden zwischengespeichert.
    func cachedMix(_ videoID: String, limit: Int = 25, manager: DownloadManager, cookies: CookieBrowser) async -> [VideoCandidate] {
        if let cached = mixCache[videoID], Date().timeIntervalSince(cached.date) < 6 * 3600, cached.entries.count >= min(limit, 20) {
            return cached.entries
        }
        guard let entries = try? await limiter.run({ try await manager.mix(for: videoID, limit: limit, cookies: cookies) }) else { return [] }
        mixCache[videoID] = (Date(), entries)
        return entries
    }

    /// Video-ID eines Titels der Bibliothek: aus dem Verlauf, einer früheren Suche oder einer neuen Suche.
    func videoID(for track: Track, manager: DownloadManager, cookies: CookieBrowser) async -> String? {
        let path = track.url.standardizedFileURL.path
        if let entry = history.entries.first(where: {
            $0.state == .downloaded && $0.videoID != nil && URL(fileURLWithPath: $0.path).standardizedFileURL.path == path
        }) {
            return entry.videoID
        }
        if let known = taste.resolvedVideoID(forTitle: track.title) { return known }
        let query = TrackVersion.parse(track.title).searchText
        guard let results = try? await limiter.run({ try await manager.search(query, cookies: cookies) }), !results.isEmpty else { return nil }
        let pick = QueueViewModel.bestPick(results, expectedDuration: nil)
        taste.remember(videoID: pick.id, forTitle: track.title)
        return pick.id
    }

    /// Zuletzt geladene Titel – je Künstler einer.
    private func recentSeeds(limit: Int) -> [(videoID: String, title: String)] {
        var seenArtists = Set<String>()
        var seeds: [(String, String)] = []
        for entry in history.entries where entry.state == .downloaded {
            guard let id = entry.videoID, !taste.isHidden(id) else { continue }
            let artist = TrackVersion.parse(entry.title).artistKey ?? entry.title
            guard seenArtists.insert(artist).inserted else { continue }
            seeds.append((id, entry.title))
            if seeds.count == limit { break }
        }
        return seeds
    }

    /// Ordner mit mindestens drei Titeln, zuletzt befüllte zuerst – Sticks vor dem Mac.
    private func candidateFolders(limit: Int) -> [LibraryFolder] {
        let tracks = library.trackIndex
        var newest: [String: Date] = [:]
        var counts: [String: Int] = [:]
        for indexed in tracks where indexed.track.isAudio {
            counts[indexed.track.folderID, default: 0] += 1
            newest[indexed.track.folderID] = max(newest[indexed.track.folderID] ?? .distantPast, indexed.track.added)
        }
        let folders = library.sources.flatMap { library.folders(in: $0.id) }
        return folders
            .filter { (counts[$0.id] ?? 0) >= 3 }
            .sorted { (newest[$0.id] ?? .distantPast) > (newest[$1.id] ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// Wie oft jeder Künstler in der Bibliothek vorkommt (Schlüssel → Anzahl).
    private func libraryArtistCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for indexed in library.trackIndex {
            if let key = TrackVersion.parse(indexed.track.title).artistKey { counts[key, default: 0] += 1 }
        }
        return counts
    }

    /// Die häufigsten Künstler (Anzeigename), mindestens zwei Titel.
    private func topLibraryArtists(limit: Int) -> [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for indexed in library.trackIndex {
            let version = TrackVersion.parse(indexed.track.title)
            guard let key = version.artistKey, let artist = version.artist else { continue }
            let name = artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?
                .trimmingCharacters(in: .whitespaces) ?? artist
            counts[key, default: (name, 0)].count += 1
        }
        let bias = taste.artistScores
        return counts
            .filter { $0.value.count >= 2 && (bias[$0.key] ?? 0) > -2 }
            .sorted { $0.value.count > $1.value.count }
            .prefix(limit)
            .map(\.value.name)
    }

    // MARK: - Spotify

    func key(for link: SpotifyLink) -> String { "\(link.id)|\(link.folderPath)" }

    /// Der Zielordner – auf einem Stick auch dann, wenn er unter anderem Pfad eingehängt ist.
    func folderURL(for link: SpotifyLink) -> URL? {
        if let uuid = link.volumeUUID, let relative = link.relativeFolder {
            guard let volume = library.volumes.first(where: { $0.uuid == uuid }) else { return nil }
            return relative.isEmpty ? volume.url : volume.url.appendingPathComponent(relative, isDirectory: true)
        }
        return URL(fileURLWithPath: link.folderPath, isDirectory: true)
    }

    /// Spotify-Playlist mit einem Ordner verknüpfen.
    func linkSpotify(url: URL, to folder: URL) async throws {
        guard let reference = SpotifyEmbed.reference(in: url) else { throw SpotifyEmbed.ReadError.notFound }
        let playlist = try await SpotifyEmbed.load(url)
        var link = SpotifyLink(
            id: reference.id,
            url: SpotifyEmbed.canonicalURL(kind: reference.kind, id: reference.id).absoluteString,
            name: playlist.name,
            folderPath: folder.standardizedFileURL.path,
            folderName: library.locationText(forFolder: folder)
        )
        if let volume = VolumeService.volume(containing: folder), volume.isExternal {
            link.volumeUUID = volume.uuid
            link.relativeFolder = VolumeService.relativePath(of: folder, in: volume)
        }
        taste.addSpotifyLink(link)
        check(link, playlist: playlist)
    }

    /// Höchstens alle zehn Minuten je Playlist bei Spotify nachfragen (↻ in der Zeile geht immer).
    func checkSpotifyLinks() {
        for link in taste.spotifyLinks {
            let recent = link.lastChecked.map { Date().timeIntervalSince($0) < 600 } ?? false
            if spotifyStates[key(for: link)] == nil || !recent { check(link) }
        }
    }

    func check(_ link: SpotifyLink, playlist known: SpotifyEmbed.Playlist? = nil) {
        let key = key(for: link)
        guard let folder = folderURL(for: link), FileManager.default.fileExists(atPath: folder.path) else {
            spotifyStates[key] = SpotifyLinkState(isOffline: true)
            return
        }
        var state = spotifyStates[key] ?? SpotifyLinkState()
        state.isChecking = true
        state.isOffline = false
        spotifyStates[key] = state
        Task { [weak self] in
            do {
                let playlist: SpotifyEmbed.Playlist
                if let known {
                    playlist = known
                } else {
                    playlist = try await SpotifyEmbed.load(URL(string: link.url)!)
                }
                guard let self else { return }
                self.spotifyStates[key] = SpotifyLinkState(
                    total: playlist.tracks.count,
                    missing: self.missingTracks(of: playlist, link: link, folder: folder),
                    mayBeTruncated: playlist.mayBeTruncated
                )
                var updated = link
                updated.name = playlist.name
                updated.lastChecked = Date()
                self.taste.updateSpotifyLink(updated)
            } catch {
                self?.spotifyStates[key] = SpotifyLinkState(error: error.localizedDescription)
            }
        }
    }

    /// Titel, die weder im Ordner liegen noch schon einmal über diese Verknüpfung geladen wurden.
    func missingTracks(of playlist: SpotifyEmbed.Playlist, link: SpotifyLink, folder: URL) -> [SpotifyEmbed.Track] {
        let folderID = folder.standardizedFileURL.path
        let present = library.trackIndex.filter { $0.track.folderID == folderID }.map(\.tokens)
        let queued = queue.items(for: folder).map { TitleMatcher.tokens($0.query) }
        return playlist.tracks.filter { track in
            guard !link.loadedTrackIDs.contains(track.id) else { return false }
            let tokens = TitleMatcher.tokens(track.searchText)
            return !(present + queued).contains { TitleMatcher.compare(tokens, $0) != nil }
        }
    }

    /// Fehlende Titel einer verknüpften Playlist laden.
    func loadMissing(_ link: SpotifyLink) {
        let key = key(for: link)
        guard let folder = folderURL(for: link), let state = spotifyStates[key], !state.missing.isEmpty else { return }
        queue.add(spotifyTracks: state.missing, to: folder)
        var updated = link
        updated.loadedTrackIDs.formUnion(state.missing.map(\.id))
        taste.updateSpotifyLink(updated)
        spotifyStates[key]?.missing = []
        library.showNotice("\(Formatters.count(state.missing.count, "Titel wird", "Titel werden")) in „\(link.folderName)“ geladen")
    }

    func unlink(_ link: SpotifyLink) {
        taste.removeSpotifyLink(link)
        spotifyStates[key(for: link)] = nil
    }

    // MARK: - Zwischenspeicher

    private struct Cache: Codable {
        var date: Date
        var shelves: [DiscoverShelf]
        var relatedArtists: [String]
    }

    private func loadCache() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: cacheURL), let cache = try? decoder.decode(Cache.self, from: data) else { return }
        shelves = cache.shelves
        relatedArtists = cache.relatedArtists
        lastRefresh = cache.date
    }

    private func saveCache() {
        let cache = Cache(date: lastRefresh ?? Date(), shelves: shelves, relatedArtists: relatedArtists)
        let url = cacheURL
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(cache) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
