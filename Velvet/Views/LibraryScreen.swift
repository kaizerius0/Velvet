import SwiftUI

/// Die Bibliothek: Playlists (Ordner) links, Titel rechts – umbenennen, verschieben, austauschen, löschen.
struct LibraryScreen: View {
    @EnvironmentObject private var library: LibraryViewModel

    var body: some View {
        Group {
            switch library.status {
            case .none:
                LibraryChooser()
            case let .offline(name):
                OfflineView(name: name)
            case .ready:
                LibraryContent()
            }
        }
        .alert("Hinweis", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        }
    }
}

// MARK: - Laufwerk wählen

private struct LibraryChooser: View {
    @EnvironmentObject private var library: LibraryViewModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
            Text("Wähle deinen Stick")
                .font(.title.weight(.bold))
            Text("Velvet verwaltet die Musik darauf wie eine Musik-App: Ordner sind Playlists, die Dateien darin deine Titel. Den Stick erkennt Velvet beim nächsten Einstecken automatisch wieder.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)

            VStack(spacing: 10) {
                if library.volumes.isEmpty {
                    Label("Kein Stick gefunden – steck ihn ein, er erscheint dann hier.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.volumes) { volume in
                    Button {
                        library.use(volume: volume)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive.fill")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(volume.name).font(.headline)
                                Text([volume.freeSpaceText, volume.fileSystem].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .frame(width: 380)
                    }
                    .controlSize(.large)
                }
            }

            Button("Stattdessen einen Ordner auf diesem Mac wählen …") {
                library.chooseFolder()
            }
            .buttonStyle(.link)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OfflineView: View {
    @EnvironmentObject private var library: LibraryViewModel
    let name: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
            Text("„\(name)“ ist nicht verbunden")
                .font(.title2.weight(.bold))
            Text("Steck den Stick ein – Velvet öffnet ihn dann automatisch.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Erneut suchen") { library.refreshVolumes() }
                Button("Anderes Laufwerk wählen …") { library.chooseFolder() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Inhalt

private struct LibraryContent: View {
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore

    @State private var selection = Set<Track.ID>()
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\Track.title)]
    @State private var renameTrack: Track?
    @State private var renamePlaylist: Playlist?
    @State private var showNewPlaylist = false
    @State private var pendingTrackDeletion: [Track] = []
    @State private var pendingPlaylistDeletion: Playlist?
    @State private var replaceModel: ReplaceViewModel?

    var body: some View {
        HStack(spacing: 0) {
            playlistColumn
                .frame(width: 240)
            Divider()
            trackColumn
        }
        .sheet(item: $renameTrack) { track in
            NameSheet(title: "Titel umbenennen", initial: track.title, confirm: "Umbenennen") { library.rename(track, to: $0) }
        }
        .sheet(item: $renamePlaylist) { playlist in
            NameSheet(title: "Playlist umbenennen", initial: playlist.name, confirm: "Umbenennen") { library.rename(playlist, to: $0) }
        }
        .sheet(isPresented: $showNewPlaylist) {
            NameSheet(title: "Neue Playlist", initial: "", confirm: "Anlegen") { name in
                if let playlist = library.createPlaylist(named: name) { library.selectedPlaylistID = playlist.id }
            }
        }
        .sheet(item: $replaceModel) { model in
            ReplaceSheet(model: model)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { !pendingTrackDeletion.isEmpty },
            set: { if !$0 { pendingTrackDeletion = [] } }
        )) {
            Button(library.deletesPermanently ? "Endgültig löschen" : "In den Papierkorb", role: .destructive) {
                library.delete(pendingTrackDeletion)
                selection.subtract(pendingTrackDeletion.map(\.id))
                pendingTrackDeletion = []
            }
        } message: {
            Text(library.deletesPermanently
                 ? "Die Dateien werden direkt vom Stick gelöscht – ohne Papierkorb."
                 : "Die Dateien landen im Papierkorb.")
        }
        .confirmationDialog("Playlist „\(pendingPlaylistDeletion?.name ?? "")“ löschen?", isPresented: Binding(
            get: { pendingPlaylistDeletion != nil },
            set: { if !$0 { pendingPlaylistDeletion = nil } }
        )) {
            Button(library.deletesPermanently ? "Mit allen Titeln endgültig löschen" : "Mit allen Titeln in den Papierkorb", role: .destructive) {
                if let playlist = pendingPlaylistDeletion { library.delete(playlist) }
                pendingPlaylistDeletion = nil
            }
        } message: {
            Text("Der Ordner und \(Formatters.count(pendingPlaylistDeletion?.trackCount ?? 0, "Titel", "Titel")) darin werden gelöscht.")
        }
    }

    // MARK: Playlists

    private var playlistColumn: some View {
        List(selection: $library.selectedPlaylistID) {
            Label("Alle Titel", systemImage: "music.note")
                .badge(library.tracks.count)
                .tag(LibraryViewModel.allTracksID)

            Section("Playlists") {
                ForEach(library.playlists) { playlist in
                    Label(playlist.displayName, systemImage: playlist.isRoot ? "folder" : "music.note.list")
                        .badge(playlist.trackCount)
                        .tag(playlist.id)
                        .contextMenu {
                            Button("Im Finder zeigen") { library.reveal([playlist.url]) }
                            if !playlist.isRoot {
                                Button("Umbenennen …") { renamePlaylist = playlist }
                                Divider()
                                Button("Playlist löschen …", role: .destructive) { pendingPlaylistDeletion = playlist }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    showNewPlaylist = true
                } label: {
                    Label("Neue Playlist", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                if library.isScanning { ProgressView().controlSize(.small) }
            }
            .padding(10)
        }
    }

    // MARK: Titel

    private var trackColumn: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if visibleTracks.isEmpty {
                emptyTracks
            } else {
                table
            }
            if !selection.isEmpty {
                Divider()
                selectionBar
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(library.selectedPlaylist?.displayName ?? "Alle Titel")
                    .font(.title2.weight(.bold))
                Text(summaryText)
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
            TextField("Suchen", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Button {
                library.rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Neu einlesen")
            Menu {
                Button("Im Finder zeigen") { library.revealRoot() }
                if library.isExternal {
                    Button("Für das Auto aufräumen") { Task { await library.cleanForCar() } }
                }
                Divider()
                Button("Anderes Laufwerk wählen …") { library.chooseFolder() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("„Für das Auto aufräumen“ entfernt Mac-Begleitdateien (._…), die Autoradios als kaputte Titel zeigen.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var table: some View {
        Table(visibleTracks, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Titel", value: \.title) { track in
                HStack(spacing: 8) {
                    Image(systemName: track.isAudio ? "music.note" : "film")
                        .foregroundStyle(.secondary)
                    Text(track.title)
                }
            }
            TableColumn("Playlist", value: \.playlistDisplayName)
                .width(min: 90, ideal: 140, max: 220)
            TableColumn("Format", value: \.format)
                .width(min: 50, ideal: 60, max: 70)
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
            trackMenu(for: tracks(for: ids))
        } primaryAction: { ids in
            tracks(for: ids).first.map(library.play)
        }
    }

    @ViewBuilder
    private func trackMenu(for selected: [Track]) -> some View {
        if selected.count == 1, let track = selected.first {
            Button("Abspielen") { library.play(track) }
            Button("Austauschen (andere Version) …") { startReplace(track) }
                .disabled(!tools.isReady)
            Button("Umbenennen …") { renameTrack = track }
        }
        if !selected.isEmpty {
            moveMenu(for: selected)
            Button("Im Finder zeigen") { library.reveal(selected.map(\.url)) }
            Divider()
            Button(selected.count == 1 ? "Löschen …" : "\(selected.count) Titel löschen …", role: .destructive) {
                pendingTrackDeletion = selected
            }
        }
    }

    private func moveMenu(for selected: [Track]) -> some View {
        Menu("Verschieben nach") {
            ForEach(library.playlists) { playlist in
                Button(playlist.displayName) { library.move(selected, to: playlist) }
                    .disabled(selected.allSatisfy { $0.folderID == playlist.id })
            }
            Divider()
            Button("Neue Playlist …") { showNewPlaylist = true }
        }
    }

    private var selectionBar: some View {
        let selected = tracks(for: selection)
        return HStack(spacing: 10) {
            Text("\(Formatters.count(selected.count, "Titel", "Titel")) ausgewählt")
                .foregroundStyle(.secondary)
            Spacer()
            if selected.count == 1, let track = selected.first {
                Button {
                    startReplace(track)
                } label: {
                    Label("Austauschen …", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!tools.isReady)
                .help("Gegen eine andere Version tauschen – z. B. die Extended Version.")
            }
            moveMenu(for: selected)
                .fixedSize()
            Button(role: .destructive) {
                pendingTrackDeletion = selected
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var emptyTracks: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(search.isEmpty ? "Hier sind noch keine Titel." : "Nichts gefunden für „\(search)“.")
                .font(.headline)
            if search.isEmpty {
                Text("Lade Titel unter „Downloads“ – und wähle dort diese Playlist als Ziel.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Hilfen

    private var visibleTracks: [Track] {
        let base = library.visibleTracks
        let filtered: [Track]
        if search.trimmingCharacters(in: .whitespaces).isEmpty {
            filtered = base
        } else {
            let words = search.lowercased().split(separator: " ")
            filtered = base.filter { track in
                let haystack = "\(track.title) \(track.playlistName)".lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
        }
        return filtered.sorted(using: sortOrder)
    }

    private func tracks(for ids: Set<Track.ID>) -> [Track] {
        library.tracks.filter { ids.contains($0.id) }
    }

    private var summaryText: String {
        let tracks = library.visibleTracks
        let size = tracks.reduce(Int64(0)) { $0 + $1.size }
        var parts = [Formatters.count(tracks.count, "Titel", "Titel"), Formatters.bytes(size)]
        if let location = library.location { parts.append(location.displayName) }
        return parts.joined(separator: " · ")
    }

    private var deleteTitle: String {
        pendingTrackDeletion.count == 1
            ? "„\(pendingTrackDeletion[0].title)“ löschen?"
            : "\(pendingTrackDeletion.count) Titel löschen?"
    }

    private func startReplace(_ track: Track) {
        guard let paths = tools.paths else { return }
        let model = ReplaceViewModel(track: track, tools: paths, settings: settings, library: library, history: history)
        replaceModel = model
        model.search()
    }
}

/// Kleines Fenster für einen Namen (Playlist anlegen, umbenennen).
struct NameSheet: View {
    let title: String
    let initial: String
    let confirm: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirm, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { name = initial }
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
        dismiss()
    }
}
