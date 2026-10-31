import Foundation

/// Der Set-Builder: Aus einem Song (oder einem ganzen Ordner) wird eine Liste passender Titel –
/// gefiltert nach Version, Tempo und Tonart, harmonisch sortiert und mit einem Klick auf dem Stick.
@MainActor
final class SetBuilderViewModel: ObservableObject, Identifiable {
    enum Source {
        case query(String)
        case candidate(VideoCandidate)
        case track(Track)
        /// „Passende ergänzen“ für einen vorhandenen Ordner.
        case folder(LibraryFolder)
    }

    enum Phase: Equatable {
        case findingSeed
        case collecting(String)
        case ready
        case failed(String)
    }

    enum Order: String, CaseIterable, Identifiable {
        case recommended
        case tempo
        case harmonic

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recommended: return "Empfehlung"
            case .tempo: return "Tempo aufsteigend"
            case .harmonic: return "Harmonisch (Camelot)"
            }
        }
    }

    /// Wohin das Set geladen wird.
    enum Target: Hashable {
        case existing(URL)
        /// Neuer Ordner in einer Bibliothek (Stick oder Mac).
        case newFolder(sourceID: String)
    }

    let id = UUID()
    let source: Source

    @Published private(set) var phase: Phase = .findingSeed
    @Published private(set) var title: String
    @Published private(set) var seed: VideoCandidate?
    /// Andere Treffer der Suche – falls der Ausgangstitel nicht passt.
    @Published private(set) var alternatives: [VideoCandidate] = []
    @Published private(set) var seedAnalysis: TrackAnalysis?
    @Published private(set) var isAnalyzingSeed = false
    @Published private(set) var pool: [Suggestion] = []
    @Published private(set) var analyses: [String: TrackAnalysis] = [:]
    @Published private(set) var analyzing: Set<String> = []
    @Published private(set) var committed: (count: Int, folder: URL)?

    @Published var count = 20 { didSet { scheduleAnalysis() } }
    @Published var onlyLong: Bool { didSet { scheduleAnalysis() } }
    @Published var hideExisting = true { didSet { scheduleAnalysis() } }
    @Published var matchTempo = false { didSet { scheduleAnalysis() } }
    @Published var tempoTolerance: Double = 6 { didSet { scheduleAnalysis() } }
    @Published var matchKey = false { didSet { scheduleAnalysis() } }
    @Published var order: Order = .recommended { didSet { scheduleAnalysis() } }
    @Published var deselected: Set<String> = []
    @Published var target: Target
    @Published var folderName: String

    private weak var discover: DiscoverViewModel?
    private var existingSongs: Set<String> = []
    private var seedIDs: Set<String> = []
    private var task: Task<Void, Never>?
    private var analysisTasks: [String: Task<Void, Never>] = [:]
    /// Wie viele Titel bei aktiven Tempo-/Tonart-Filtern geprüft werden – wächst, bis das Set voll ist.
    private var analysisDepth = 0

    static let countOptions = [10, 20, 30, 50]

    init(source: Source, discover: DiscoverViewModel) {
        self.source = source
        self.discover = discover
        onlyLong = discover.settings.preferredVersion == .extended

        let library = discover.library
        switch source {
        case let .folder(folder):
            title = "„\(folder.name)“ ergänzen"
            target = .existing(folder.url)
            folderName = folder.name
            count = 10
        default:
            title = "Set bauen"
            // Neuer Ordner dort, wo zuletzt hingeladen wurde – sonst auf dem ersten Stick.
            let preferred = discover.target.flatMap { library.source(containing: $0)?.id }
                ?? library.sources.first(where: \.isExternal)?.id
                ?? LibrarySource.macID
            target = .newFolder(sourceID: preferred)
            folderName = "Set"
        }
    }

    // MARK: Ablauf

    func start() {
        task?.cancel()
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        task?.cancel()
        analysisTasks.values.forEach { $0.cancel() }
        analysisTasks = [:]
    }

    /// Anderen Ausgangstitel wählen (aus den Suchtreffern).
    func useSeed(_ candidate: VideoCandidate) {
        cancel()
        pool = []
        deselected = []
        task = Task { [weak self] in await self?.collect(from: [candidate], single: true) }
    }

    private var isFolderSource: Bool {
        if case .folder = source { return true }
        return false
    }

    private func run() async {
        guard let discover, let manager = discover.tools.downloadManager else {
            phase = .failed("Die Werkzeuge sind noch nicht bereit.")
            return
        }
        let cookies = discover.settings.cookieBrowser
        phase = .findingSeed
        var seeds: [VideoCandidate] = []
        do {
            switch source {
            case let .candidate(candidate):
                seeds = [candidate]
            case let .query(text):
                if let url = ListParser.link(from: text), YouTubeLink.videoID(in: url) != nil {
                    seeds = [try await manager.videoInfo(url, cookies: cookies)]
                } else {
                    // Ausgangstitel: die normale Version (YouTubes Reihenfolge) – Extended gilt fürs Set.
                    let results = try await manager.search(text, cookies: cookies)
                    alternatives = results
                    if !results.isEmpty { seeds = [QueueViewModel.bestPick(results, expectedDuration: nil)] }
                }
            case let .track(track):
                if let id = await discover.videoID(for: track, manager: manager, cookies: cookies) {
                    seeds = [Self.candidate(id: id, title: track.title)]
                }
            case let .folder(folder):
                let tracks = discover.library.trackIndex.map(\.track)
                    .filter { $0.folderID == folder.id && $0.isAudio }
                    .sorted { $0.added > $1.added }
                for track in tracks.prefix(5) {
                    guard !Task.isCancelled else { return }
                    phase = .collecting("Titel aus „\(folder.name)“ werden zugeordnet …")
                    if let id = await discover.videoID(for: track, manager: manager, cookies: cookies) {
                        seeds.append(Self.candidate(id: id, title: track.title))
                    }
                }
                // Tempo und Tonart des Ordners: Median bzw. häufigste Tonart der Titel.
                let known = tracks.compactMap { discover.analysis.analysis(for: $0) }
                seedAnalysis = Self.summary(of: known)
            }
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed((error as? DownloadFailure)?.message ?? error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { return }
        guard !seeds.isEmpty else {
            phase = .failed("Dazu wurde nichts gefunden. Versuch es mit „Interpret - Titel“.")
            return
        }
        await collect(from: seeds, single: seeds.count == 1 && !isFolderSource)
    }

    private func collect(from seeds: [VideoCandidate], single: Bool) async {
        guard let discover, let manager = discover.tools.downloadManager else { return }
        let cookies = discover.settings.cookieBrowser
        if single, let first = seeds.first {
            seed = first
            let song = first.version.song
            title = "Set aus „\(song)“"
            folderName = LibraryFiles.sanitizedName("Set – \(song)")
            // Tempo und Tonart des Ausgangstitels – parallel zum Lesen der Mixe.
            seedAnalysis = nil
            Task { [weak self] in await self?.analyzeSeed(first) }
        }
        seedIDs = Set(seeds.map(\.id))

        phase = .collecting("YouTube-Mixe werden gelesen …")
        var pools: [[VideoCandidate]] = []
        for candidate in seeds.prefix(5) {
            guard !Task.isCancelled else { return }
            pools.append(await discover.cachedMix(candidate.id, limit: single ? 40 : 25, manager: manager, cookies: cookies))
        }

        var context = discover.makeContext()
        existingSongs = context.excludedSongs
        context.excludedSongs = Set(seeds.map { $0.version.baseKey })
        context.excludedIDs = discover.taste.hiddenVideoIDs.union(seedIDs)

        // Zweite Runde: die Mixe der drei besten Treffer – so entsteht ein dichteres Netz ähnlicher Titel.
        if single {
            let first = Recommender.rank(pools, context: context, limit: 10)
            for suggestion in first.prefix(3) {
                guard !Task.isCancelled else { return }
                phase = .collecting("Ähnliche Titel zu „\(suggestion.version.song)“ …")
                pools.append(await discover.cachedMix(suggestion.id, limit: 25, manager: manager, cookies: cookies))
            }
        }
        guard !Task.isCancelled else { return }
        pool = Recommender.rank(pools, context: context, limit: 120)
        phase = pool.isEmpty ? .failed("YouTube hat keine ähnlichen Titel geliefert. Versuch es mit einem anderen Song.") : .ready
        scheduleAnalysis()
    }

    private func analyzeSeed(_ candidate: VideoCandidate) async {
        guard let discover else { return }
        isAnalyzingSeed = true
        let result = await discover.analysis.analyzeVideo(candidate)
        guard seed?.id == candidate.id else { return }
        isAnalyzingSeed = false
        if let result {
            seedAnalysis = result
            scheduleAnalysis()
        }
    }

    // MARK: Liste

    /// Tempo- oder Tonart-Filter aktiv (und der Ausgangstitel hat die nötigen Werte)?
    var filtersByAnalysis: Bool {
        (matchTempo && seedAnalysis?.bpm != nil) || (matchKey && seedAnalysis?.key != nil)
    }

    /// Vor den Tempo-/Tonart-Filtern.
    private var prefiltered: [Suggestion] {
        pool.filter { suggestion in
            if hideExisting, existingSongs.contains(suggestion.version.baseKey) { return false }
            if onlyLong, !suggestion.version.isLong(duration: suggestion.candidate.duration) { return false }
            return true
        }
    }

    /// Das Set, wie es geladen würde.
    var entries: [Suggestion] {
        var list = prefiltered
        if filtersByAnalysis {
            list = list.filter { suggestion in
                guard let analysis = analyses[suggestion.id] else { return false }
                if matchTempo, let reference = seedAnalysis?.bpm {
                    guard let bpm = analysis.bpm, SetPlanner.tempoDistance(bpm, reference) <= tempoTolerance else { return false }
                }
                if matchKey, let reference = seedAnalysis?.key {
                    guard let key = analysis.key, key.isCompatible(with: reference) else { return false }
                }
                return true
            }
        }
        list = Array(list.prefix(count))
        switch order {
        case .recommended:
            return list
        case .tempo:
            return SetPlanner.tempoOrder(list) { analyses[$0.id] }
        case .harmonic:
            return SetPlanner.harmonicOrder(list, start: seedAnalysis) { analyses[$0.id] }
        }
    }

    var selectedEntries: [Suggestion] {
        entries.filter { !deselected.contains($0.id) }
    }

    /// „Lieder werden geprüft: 12 von 40“
    var analysisProgress: (done: Int, total: Int)? {
        let wanted = analysisCandidates.map(\.id)
        guard !wanted.isEmpty else { return nil }
        let done = wanted.filter { analysisTasks[$0] == nil }.count
        return done < wanted.count ? (done, wanted.count) : nil
    }

    func isExisting(_ suggestion: Suggestion) -> Bool {
        existingSongs.contains(suggestion.version.baseKey)
    }

    func toggle(_ suggestion: Suggestion) {
        if deselected.contains(suggestion.id) {
            deselected.remove(suggestion.id)
        } else {
            deselected.insert(suggestion.id)
        }
    }

    // MARK: Tempo und Tonart

    /// Welche Titel geprüft werden: bei aktiven Filtern deutlich mehr als gebraucht, sonst die sichtbaren.
    private var analysisCandidates: [Suggestion] {
        filtersByAnalysis ? Array(prefiltered.prefix(max(count * 3, analysisDepth))) : Array(prefiltered.prefix(count))
    }

    private func scheduleAnalysis() {
        guard phase == .ready, let discover else { return }
        for suggestion in analysisCandidates where analyses[suggestion.id] == nil && analysisTasks[suggestion.id] == nil {
            if let known = discover.analysis.analysis(forVideo: suggestion.id) {
                analyses[suggestion.id] = known
                continue
            }
            let id = suggestion.id
            analysisTasks[id] = Task { [weak self] in
                self?.analyzing.insert(id)
                let result = await discover.analysis.analyzeVideo(suggestion.candidate)
                guard let self, !Task.isCancelled else { return }
                self.analyzing.remove(id)
                if let result { self.analyses[id] = result }
                self.analysisTasks[id] = nil
                self.deepenIfNeeded()
            }
        }
    }

    /// Strenge Filter lassen zu wenig übrig: weitere Titel prüfen, solange der Vorrat reicht.
    private func deepenIfNeeded() {
        guard filtersByAnalysis, analysisTasks.isEmpty, entries.count < count else { return }
        let checked = analysisCandidates.count
        guard checked < prefiltered.count else { return }
        analysisDepth = checked + count * 2
        scheduleAnalysis()
    }

    // MARK: Laden

    /// Lädt das Set in den Zielordner. Gibt den Ordner zurück.
    @discardableResult
    func commit() -> URL? {
        guard let discover else { return nil }
        let selected = selectedEntries.map(\.candidate)
        guard !selected.isEmpty else { return nil }
        let library = discover.library
        let folder: URL
        switch target {
        case let .existing(url):
            folder = url
        case let .newFolder(sourceID):
            let parent: URL
            if let volume = library.source(id: sourceID)?.volume {
                parent = volume.url
            } else {
                parent = library.macFolders.last?.deletingLastPathComponent()
                    ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser
            }
            let name = LibraryFiles.sanitizedName(folderName.isEmpty ? "Set" : folderName)
            let unique = LibraryFiles.uniqueURL(parent.appendingPathComponent(name, isDirectory: true)).lastPathComponent
            guard let created = library.createFolder(named: unique, in: parent) else { return nil }
            folder = created.url
        }
        discover.queue.add(candidates: selected, to: folder)
        selected.forEach(discover.taste.recordAdd)
        discover.markAdded(selected)
        committed = (selected.count, folder)
        return folder
    }

    // MARK: Hilfen

    private static func candidate(id: String, title: String) -> VideoCandidate {
        VideoCandidate(id: id, title: title, channel: nil, duration: nil, viewCount: nil,
                       thumbnailURL: YouTubeLink.thumbnailURL(id), url: YouTubeLink.watchURL(id))
    }

    /// Median-Tempo und häufigste Tonart mehrerer Titel.
    nonisolated static func summary(of analyses: [TrackAnalysis]) -> TrackAnalysis? {
        let tempos = analyses.compactMap(\.bpm).sorted()
        let keys = analyses.compactMap(\.key)
        guard !tempos.isEmpty || !keys.isEmpty else { return nil }
        let median = tempos.isEmpty ? nil : tempos[tempos.count / 2]
        let common = Dictionary(grouping: keys, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        return TrackAnalysis(bpm: median, key: common)
    }
}
