import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var navigation: AppNavigation
    @EnvironmentObject private var library: LibraryViewModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 980, minHeight: 640)
        .sheet(item: Binding(
            get: { navigation.newPlaylistSource.map(SheetID.init) },
            set: { navigation.newPlaylistSource = $0?.id }
        )) { sheet in
            NameSheet(title: "Neue Playlist", initial: "", confirm: "Erstellen") { name in
                if let playlist = library.createPlaylist(named: name, in: sheet.id) {
                    navigation.selection = .playlist(source: sheet.id, id: playlist.id)
                }
            }
        }
        .onChange(of: library.newlyMountedSourceID) { id in
            // Beim Hinzufügen nicht wegspringen.
            if let id, navigation.selection != .add { navigation.selection = .allTracks(source: id) }
        }
        .onChange(of: library.sources) { sources in
            // Ausgeworfener Stick: zurück zum Mac.
            if let source = navigation.sourceID, !sources.contains(where: { $0.id == source }) {
                navigation.selection = .allTracks(source: LibrarySource.macID)
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

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .add, .none:
            AddScreen()
                .navigationTitle("Hinzufügen")
        case .history:
            HistoryScreen()
                .navigationTitle("Verlauf")
        case let .playlist(source, id):
            PlaylistScreen(sourceID: source, playlistID: id)
                .id(navigation.selection)
        case let .allTracks(source):
            PlaylistScreen(sourceID: source, playlistID: nil)
                .id(navigation.selection)
        }
    }

    private struct SheetID: Identifiable {
        let id: String
    }
}

/// Seitenleiste: jede Bibliothek (Mac, Sticks) mit ihren Playlists, dazu der Verlauf.
struct Sidebar: View {
    @EnvironmentObject private var navigation: AppNavigation
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var queue: QueueViewModel

    @State private var renameTarget: Playlist?
    @State private var deleteTarget: Playlist?

    var body: some View {
        List(selection: $navigation.selection) {
            Section {
                Label {
                    HStack(spacing: 6) {
                        Text("Hinzufügen")
                        if queue.activity.busy > 0 {
                            ProgressView().controlSize(.mini)
                        }
                    }
                } icon: {
                    Image(systemName: "plus.circle")
                }
                .badge(queue.activity.needsAttention)
                .tag(AppNavigation.Item.add)
            }
            ForEach(library.sources) { source in
                Section {
                    Label("Alle Titel", systemImage: "music.note")
                        .badge(library.tracks(in: source.id).count)
                        .tag(AppNavigation.Item.allTracks(source: source.id))
                    ForEach(visiblePlaylists(in: source)) { playlist in
                        Label(playlist.displayName, systemImage: playlist.isRoot ? "folder" : "music.note.list")
                            .badge(playlist.trackCount)
                            .tag(AppNavigation.Item.playlist(source: source.id, id: playlist.id))
                            .contextMenu { playlistMenu(playlist) }
                    }
                } header: {
                    SourceHeader(source: source)
                }
            }
            Section {
                Label("Verlauf", systemImage: "clock.arrow.circlepath")
                    .tag(AppNavigation.Item.history)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ToolStatusBadge()
                #if DEBUG
                Text("Entwicklungsversion")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                #endif
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .sheet(item: $renameTarget) { playlist in
            NameSheet(title: "Playlist umbenennen", initial: playlist.name, confirm: "Umbenennen") { name in
                let wasSelected = navigation.playlistID == playlist.id
                if let newID = library.rename(playlist, to: name), wasSelected, let source = library.source(containing: playlist.url) {
                    navigation.selection = .playlist(source: source.id, id: newID)
                }
            }
        }
        .confirmationDialog("„\(deleteTarget?.name ?? "")“ löschen?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Löschen", role: .destructive) {
                if let playlist = deleteTarget { library.delete(playlist) }
                deleteTarget = nil
            }
        } message: {
            if let playlist = deleteTarget {
                Text(library.deletesPermanently(at: playlist.url)
                     ? "Der Ordner und \(Formatters.count(playlist.trackCount, "Titel", "Titel")) werden endgültig vom Stick gelöscht."
                     : "Der Ordner und \(Formatters.count(playlist.trackCount, "Titel", "Titel")) kommen in den Papierkorb.")
            }
        }
    }

    /// Der Hauptordner erscheint nur, wenn dort auch Titel liegen.
    private func visiblePlaylists(in source: LibrarySource) -> [Playlist] {
        library.playlists(in: source.id).filter { !$0.isRoot || $0.trackCount > 0 }
    }

    @ViewBuilder
    private func playlistMenu(_ playlist: Playlist) -> some View {
        Button("Im Finder zeigen") { library.reveal([playlist.url]) }
        if !playlist.isRoot {
            Button("Umbenennen …") { renameTarget = playlist }
            Divider()
            Button("Löschen …", role: .destructive) { deleteTarget = playlist }
        }
    }
}

/// Abschnittskopf einer Bibliothek: Name, „+“ für neue Playlists, Auswerfen bei Sticks.
private struct SourceHeader: View {
    @EnvironmentObject private var navigation: AppNavigation
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var queue: QueueViewModel
    let source: LibrarySource

    var body: some View {
        HStack(spacing: 6) {
            Text(source.name)
            if library.isScanning(source.id) {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            Button {
                navigation.newPlaylistSource = source.id
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Neue Playlist")

            if source.isExternal {
                Button {
                    Task { await library.eject(source.id) }
                } label: {
                    Image(systemName: "eject")
                }
                .buttonStyle(.borderless)
                .disabled(queue.isWriting(to: source.rootURL))
                .help(queue.isWriting(to: source.rootURL) ? "Es werden noch Titel auf diesen Stick geladen" : "Auswerfen")
            }
        }
    }
}
