import SwiftUI
import UniformTypeIdentifiers

/// Eine Playlist (oder alle Titel einer Bibliothek) – die Titel verwalten.
/// Neue Titel kommen über „Titel hinzufügen“ in den Bereich „Hinzufügen“.
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

    @State private var selection = Set<Track.ID>()
    @State private var filter = ""
    @State private var sortOrder = [KeyPathComparator(\Track.added, order: .reverse)]
    @State private var renameTrack: Track?
    @State private var pendingDeletion: [Track] = []
    @State private var replaceModel: ReplaceViewModel?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if case let .failed(message) = tools.state {
                ToolFailureBanner(message: message)
                    .padding([.horizontal, .top], 20)
            }
            header
            if !incoming.isEmpty {
                incomingBanner
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
            if library.tracks(in: sourceID, playlistID: playlistID).count > 12 {
                TextField("Filtern", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            Button(action: openAdd) {
                Label("Titel hinzufügen", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            moreMenu
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var moreMenu: some View {
        Menu {
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

    /// Öffnet „Hinzufügen“ mit dieser Playlist als Ziel.
    private func openAdd() {
        settings.addTargetSource = sourceID
        settings.addTargetPlaylist = playlist.map { $0.isRoot ? "" : $0.name } ?? ""
        navigation.selection = .add
        navigation.focusInput = UUID()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, TextFileLoader.isSupported(url) else { return }
                DispatchQueue.main.async {
                    input.load(from: url)
                    openAdd()
                }
            }
        }
        return accepted
    }

    /// Titel, die gerade hierher geladen werden (ohne fertige).
    private var incoming: [DownloadItem] {
        let items: [DownloadItem]
        if let playlist {
            items = queue.items(for: playlist.url)
        } else if let root = source?.rootURL {
            items = queue.items(within: root)
        } else {
            items = []
        }
        return items.filter { $0.status != .completed }
    }

    private var incomingBanner: some View {
        let items = incoming
        let waiting = items.filter { $0.status.needsAttention }.count
        let busy = items.filter { $0.status.isBusy }.count
        var parts: [String] = []
        if busy > 0 { parts.append("\(busy) \(busy == 1 ? "Titel wird" : "Titel werden") geladen") }
        if waiting > 0 { parts.append("\(waiting) \(waiting == 1 ? "wartet" : "warten") auf deine Auswahl") }
        if parts.isEmpty { parts.append(Formatters.count(items.count, "Titel braucht Aufmerksamkeit", "Titel brauchen Aufmerksamkeit")) }
        return HStack(spacing: 10) {
            if busy > 0 {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "hand.tap.fill").foregroundStyle(Color.accentColor)
            }
            Text(parts.joined(separator: " · "))
            Spacer()
            Button("Ansehen") { navigation.selection = .add }
        }
        .bannerStyle()
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: Inhalt

    @ViewBuilder
    private var content: some View {
        let tracks = visibleTracks
        VStack(spacing: 0) {
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
