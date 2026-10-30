import SwiftUI
import UniformTypeIdentifiers

/// Eine Playlist (oder alle Titel einer Bibliothek): oben suchen und hinzufügen, darunter die Titel.
struct PlaylistScreen: View {
    let sourceID: String
    /// `nil` = alle Titel der Bibliothek.
    let playlistID: String?

    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var navigation: AppNavigation
    @EnvironmentObject private var input: InputViewModel

    @StateObject private var quickAdd: QuickAddModel
    @FocusState private var searchFocused: Bool
    @State private var selection = Set<Track.ID>()
    @State private var filter = ""
    @State private var sortOrder = [KeyPathComparator(\Track.added, order: .reverse)]
    @State private var renameTrack: Track?
    @State private var pendingDeletion: [Track] = []
    @State private var replaceModel: ReplaceViewModel?
    /// In „Alle Titel“: wohin neue Titel kommen (`nil` = Hauptordner).
    @State private var targetPlaylistName: String?
    @State private var isDropTargeted = false

    init(sourceID: String, playlistID: String?, quickAdd: QuickAddModel? = nil) {
        self.sourceID = sourceID
        self.playlistID = playlistID
        _quickAdd = StateObject(wrappedValue: quickAdd ?? QuickAddModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            if case let .failed(message) = tools.state {
                ToolFailureBanner(message: message)
                    .padding([.horizontal, .top], 20)
            }
            header
            addField
            if quickAdd.isOpen {
                suggestions
            }
            Divider()
            content
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $renameTrack) { track in
            NameSheet(title: "Titel umbenennen", initial: track.title, confirm: "Umbenennen") { library.rename(track, to: $0) }
        }
        .sheet(item: $replaceModel) { model in
            ReplaceSheet(model: model)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { !pendingDeletion.isEmpty },
            set: { if !$0 { pendingDeletion = [] } }
        )) {
            Button("Löschen", role: .destructive) {
                library.delete(pendingDeletion)
                selection.subtract(pendingDeletion.map(\.id))
                pendingDeletion = []
            }
        } message: {
            Text(source?.isExternal == true
                 ? "Wird endgültig vom Stick gelöscht."
                 : "Kommt in den Papierkorb.")
        }
        .onChange(of: navigation.focusSearch) { _ in searchFocused = true }
        .onAppear { searchFocused = true }
    }

    // MARK: Kopf

    private var source: LibrarySource? { library.source(id: sourceID) }

    private var playlist: Playlist? {
        playlistID.flatMap { library.playlist(id: $0, in: sourceID) }
    }

    private var title: String {
        playlist?.displayName ?? "Alle Titel"
    }

    private var subtitle: String {
        let tracks = library.tracks(in: sourceID, playlistID: playlistID)
        let size = tracks.reduce(Int64(0)) { $0 + $1.size }
        var parts = [source?.name ?? "", Formatters.count(tracks.count, "Titel", "Titel")]
        if size > 0 { parts.append(Formatters.bytes(size)) }
        if let free = source?.volume?.availableBytes { parts.append("\(Formatters.bytes(free)) frei") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title.weight(.bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let notice = library.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .lineLimit(1)
            }
            Picker("Format", selection: $settings.format) {
                Text("MP3").tag(MediaFormat.audio)
                Text("MP4").tag(MediaFormat.video)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Format für neue Titel")
            moreMenu
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var moreMenu: some View {
        Menu {
            Button("Mehrere Titel hinzufügen …") { navigation.showAddSeveral = true }
            Divider()
            if let playlist {
                Button("Im Finder zeigen") { library.reveal([playlist.url]) }
            } else {
                Button("Im Finder zeigen") { library.open(sourceID) }
            }
            if source?.isExternal == true {
                Button("Für das Auto aufräumen") { Task { await library.cleanForCar(sourceID) } }
                    .help("Entfernt Mac-Begleitdateien (._*), die Autoradios als kaputte Titel zeigen")
                Button("Auswerfen") { Task { await library.eject(sourceID) } }
                    .disabled(source.map { queue.isWriting(to: $0.rootURL) } ?? true)
            } else {
                Button("Musikordner wählen …") { library.chooseMacFolder() }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Hinzufügen

    private var addField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Titel oder YouTube-Link hinzufügen", text: $quickAdd.text)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit(submit)
                .onExitCommand { quickAdd.close() }
            if !quickAdd.text.isEmpty {
                Button {
                    quickAdd.text = ""
                    quickAdd.close()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
            if playlistID == nil {
                targetMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(searchFocused ? Color.accentColor.opacity(0.6) : Theme.border, lineWidth: searchFocused ? 2 : 1)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .onChange(of: quickAdd.text) { text in
            // Mehrere Zeilen eingefügt: das ist eine Liste.
            if text.contains("\n") {
                openAddSeveral(with: text)
                quickAdd.text = ""
            }
        }
    }

    /// In „Alle Titel“: Ziel-Playlist für neue Titel.
    private var targetMenu: some View {
        Menu {
            Button("Hauptordner") { targetPlaylistName = nil }
            let folders = library.playlists(in: sourceID).filter { !$0.isRoot }
            if !folders.isEmpty { Divider() }
            ForEach(folders) { playlist in
                Button(playlist.name) { targetPlaylistName = playlist.name }
            }
        } label: {
            Label(targetPlaylistName ?? "Hauptordner", systemImage: "arrow.down.to.line")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Ziel für neue Titel")
    }

    /// Ordner, in den neue Titel geladen werden.
    private var targetFolder: URL? {
        if let playlist { return playlist.url }
        guard let root = source?.rootURL else { return nil }
        guard let name = targetPlaylistName else { return root }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    private func submit() {
        let text = quickAdd.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let folder = targetFolder else { return }
        let parsed = ListParser.parse(text)
        if parsed.entries.count > 1 {
            openAddSeveral(with: text)
            quickAdd.text = ""
            return
        }
        guard let entry = parsed.entries.first else { return }
        if entry.isLink {
            queue.add(entries: [entry], to: folder)
            quickAdd.text = ""
            quickAdd.close()
        } else {
            quickAdd.search(entry.displayText, tools: tools.paths, cookies: settings.cookieBrowser)
        }
    }

    private var suggestions: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(quickAdd.query)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Weitere Vorschläge") {
                    quickAdd.loadMore(tools: tools.paths, cookies: settings.cookieBrowser)
                }
                .disabled(quickAdd.phase == .searching)
                Button {
                    quickAdd.close()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            suggestionContent
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border.opacity(0.7)))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var suggestionContent: some View {
        switch quickAdd.phase {
        case .searching:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 90)
        case .empty:
            Text("Keine Treffer")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        case let .failed(message):
            Text(message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        case .results, .idle:
            let checker = DuplicateChecker(library: library, history: history, sourceID: sourceID)
            VStack(spacing: 0) {
                ForEach(quickAdd.results) { candidate in
                    SuggestionRow(
                        candidate: candidate,
                        existing: checker.existingLocation(of: candidate),
                        isAdded: quickAdd.added.contains(candidate.id)
                    ) {
                        add(candidate)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func add(_ candidate: VideoCandidate) {
        guard let folder = targetFolder else { return }
        queue.add(candidate: candidate, query: quickAdd.query, to: folder)
        quickAdd.markAdded(candidate)
        quickAdd.text = ""
    }

    private func openAddSeveral(with text: String) {
        let current = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        input.text = current.isEmpty ? text : current + "\n" + text
        navigation.showAddSeveral = true
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, TextFileLoader.isSupported(url) else { return }
                DispatchQueue.main.async {
                    input.load(from: url)
                    navigation.showAddSeveral = true
                }
            }
        }
        return accepted
    }

    // MARK: Inhalt

    private var pending: [DownloadItem] {
        if let playlist { return queue.items(for: playlist.url) }
        guard let root = source?.rootURL else { return [] }
        return queue.items(within: root)
    }

    @ViewBuilder
    private var content: some View {
        let incoming = pending
        let tracks = visibleTracks
        VStack(spacing: 0) {
            if !incoming.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(incoming) { item in
                            PendingRow(item: item, queue: queue, location: playlistID == nil ? library.locationText(forFolder: item.destination) : nil)
                            Divider().padding(.leading, 84)
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(incoming.count) * 58 + 4, 300))
                Divider()
            }
            if tracks.isEmpty {
                emptyState
            } else {
                trackTable(tracks)
            }
            if !selection.isEmpty {
                Divider()
                selectionBar
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(filter.isEmpty ? "Noch keine Titel" : "Keine Treffer für „\(filter)“")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func trackTable(_ tracks: [Track]) -> some View {
        Table(tracks, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Titel", value: \.title) { track in
                HStack(spacing: 8) {
                    Image(systemName: track.isAudio ? "music.note" : "film")
                        .foregroundStyle(.secondary)
                    Text(track.title)
                }
            }
            TableColumn("Playlist", value: \.playlistDisplayName)
                .width(min: 80, ideal: 140, max: 240)
            TableColumn("Format", value: \.format)
                .width(min: 46, ideal: 56, max: 70)
            TableColumn("Größe", value: \.size) { track in
                Text(Formatters.bytes(track.size)).monospacedDigit()
            }
            .width(min: 60, ideal: 75, max: 90)
            TableColumn("Hinzugefügt", value: \.added) { track in
                Text(Formatters.date(track.added))
            }
            .width(min: 80, ideal: 110, max: 140)
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            trackMenu(for: library.trackIndex.map(\.track).filter { ids.contains($0.id) })
        } primaryAction: { ids in
            library.trackIndex.first { ids.contains($0.track.id) }.map { library.play($0.track) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if library.tracks(in: sourceID, playlistID: playlistID).count > 12 {
                HStack {
                    Spacer()
                    TextField("Filtern", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }
        }
    }

    private var visibleTracks: [Track] {
        let base = library.tracks(in: sourceID, playlistID: playlistID)
        let words = filter.lowercased().split(separator: " ")
        let filtered = words.isEmpty ? base : base.filter { track in
            let haystack = "\(track.title) \(track.playlistName)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return filtered.sorted(using: sortOrder)
    }

    // MARK: Titel-Aktionen

    @ViewBuilder
    private func trackMenu(for selected: [Track]) -> some View {
        if selected.count == 1, let track = selected.first {
            Button("Abspielen") { library.play(track) }
            Button("Andere Version …") { startReplace(track) }
                .disabled(!tools.isReady)
            Button("Umbenennen …") { renameTrack = track }
            Divider()
        }
        if !selected.isEmpty {
            moveMenu(for: selected)
            copyMenu(for: selected)
            Button("Im Finder zeigen") { library.reveal(selected.map(\.url)) }
            Divider()
            Button("Löschen …", role: .destructive) { pendingDeletion = selected }
        }
    }

    private func moveMenu(for selected: [Track]) -> some View {
        Menu("Verschieben nach") {
            ForEach(library.playlists(in: sourceID)) { target in
                Button(target.displayName) { library.move(selected, to: target) }
                    .disabled(selected.allSatisfy { $0.folderID == target.id })
            }
        }
    }

    /// Kopieren in eine andere Bibliothek – z. B. vom Mac auf den Stick.
    @ViewBuilder
    private func copyMenu(for selected: [Track]) -> some View {
        let others = library.sources.filter { $0.id != sourceID }
        if !others.isEmpty {
            Menu("Kopieren nach") {
                ForEach(others) { other in
                    Section(other.name) {
                        ForEach(library.playlists(in: other.id)) { target in
                            Button(target.displayName) { library.copy(selected, to: target) }
                        }
                    }
                }
            }
        }
    }

    private var selectionBar: some View {
        let selected = library.trackIndex.map(\.track).filter { selection.contains($0.id) }
        return HStack(spacing: 10) {
            Text("\(Formatters.count(selected.count, "Titel", "Titel")) ausgewählt")
                .foregroundStyle(.secondary)
            Spacer()
            if selected.count == 1, let track = selected.first {
                Button("Andere Version …") { startReplace(track) }
                    .disabled(!tools.isReady)
            }
            moveMenu(for: selected)
                .fixedSize()
            Button(role: .destructive) {
                pendingDeletion = selected
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var deleteTitle: String {
        pendingDeletion.count == 1
            ? "„\(pendingDeletion[0].title)“ löschen?"
            : "\(pendingDeletion.count) Titel löschen?"
    }

    private func startReplace(_ track: Track) {
        guard let paths = tools.paths else { return }
        let model = ReplaceViewModel(track: track, tools: paths, settings: settings, library: library, history: history)
        replaceModel = model
        model.search()
    }
}
