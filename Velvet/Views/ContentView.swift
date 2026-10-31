import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var navigation: AppNavigation
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var player: PreviewPlayer

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            detail
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if player.isActive { PlayerBar() }
                }
        }
        .frame(minWidth: 980, minHeight: 640)
        .sheet(item: Binding(
            get: { stickForNewFolder.map(SheetID.init) },
            set: { navigation.newFolderSource = $0?.id }
        )) { sheet in
            NameSheet(title: "Neuer Ordner", initial: "", confirm: "Erstellen") { name in
                if let root = library.source(id: sheet.id)?.volume?.url,
                   let folder = library.createFolder(named: name, in: root) {
                    navigation.selection = .folder(source: sheet.id, id: folder.id)
                }
            }
        }
        .onChange(of: navigation.newFolderSource) { source in
            // Auf dem Mac gibt es keinen festen Ort – dort fragt ein Fenster nach Ort und Namen.
            guard source == LibrarySource.macID else { return }
            navigation.newFolderSource = nil
            if let url = library.createMacFolder() {
                navigation.selection = .folder(source: LibrarySource.macID, id: url.standardizedFileURL.path)
            }
        }
        .onChange(of: library.newlyMountedSourceID) { id in
            // Beim Hinzufügen und Entdecken nicht wegspringen.
            if let id, navigation.selection != .add, navigation.selection != .discover { navigation.selection = .allTracks(source: id) }
        }
        .onChange(of: library.sources) { sources in
            // Ausgeworfener Stick: zurück zu „Hinzufügen“.
            if let source = navigation.sourceID, !sources.contains(where: { $0.id == source }) {
                navigation.selection = .add
            }
        }
        .onChange(of: library.macFolders) { _ in
            // Ordner aus der Seitenleiste genommen.
            if navigation.sourceID == LibrarySource.macID, let id = navigation.folderID,
               !library.isMacFolder(URL(fileURLWithPath: id)) {
                navigation.selection = .add
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

    private var stickForNewFolder: String? {
        navigation.newFolderSource == LibrarySource.macID ? nil : navigation.newFolderSource
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .discover, .none:
            DiscoverScreen()
                .navigationTitle("Entdecken")
        case .add:
            AddScreen()
                .navigationTitle("Hinzufügen")
        case .history:
            HistoryScreen()
                .navigationTitle("Verlauf")
        case let .folder(source, id):
            FolderScreen(sourceID: source, folderID: id)
                .id(navigation.selection)
        case let .allTracks(source):
            FolderScreen(sourceID: source, folderID: nil)
                .id(navigation.selection)
        }
    }

    private struct SheetID: Identifiable {
        let id: String
    }
}

/// Seitenleiste: deine Ordner auf dem Mac, jeder Stick mit seinen Ordnern, dazu der Verlauf.
struct Sidebar: View {
    @EnvironmentObject private var navigation: AppNavigation
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var discover: DiscoverViewModel

    @State private var renameTarget: LibraryFolder?
    @State private var deleteTarget: LibraryFolder?

    var body: some View {
        List(selection: $navigation.selection) {
            Section {
                Label {
                    HStack(spacing: 6) {
                        Text("Entdecken")
                        if discover.isRefreshing || discover.setBuilder?.analysisProgress != nil {
                            ProgressView().controlSize(.mini)
                        }
                    }
                } icon: {
                    Image(systemName: "sparkles")
                }
                .badge(discover.newSpotifyTrackCount)
                .tag(AppNavigation.Item.discover)
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
                    if source.isExternal {
                        Label("Alle Titel", systemImage: "music.note")
                            .badge(library.tracks(in: source.id).count)
                            .tag(AppNavigation.Item.allTracks(source: source.id))
                    } else if library.macFolders.isEmpty {
                        Button {
                            selectFolder(library.chooseFolder(title: "Ordner hinzufügen", prompt: "Hinzufügen"))
                        } label: {
                            Label("Ordner hinzufügen …", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    ForEach(visibleFolders(in: source)) { folder in
                        Label(folder.name, systemImage: folder.isVolumeRoot ? "externaldrive" : "folder")
                            .badge(folder.trackCount)
                            .tag(AppNavigation.Item.folder(source: source.id, id: folder.id))
                            .contextMenu { folderMenu(folder, in: source) }
                    }
                } header: {
                    SourceHeader(source: source, onNewMacFolder: { selectFolder(library.createMacFolder()) },
                                 onAddMacFolder: { selectFolder(library.chooseFolder(title: "Ordner hinzufügen", prompt: "Hinzufügen")) })
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
        .sheet(item: $renameTarget) { folder in
            NameSheet(title: "Ordner umbenennen", initial: folder.name, confirm: "Umbenennen") { name in
                let wasSelected = navigation.folderID == folder.id
                if let newID = library.rename(folder, to: name), wasSelected, let source = library.source(containing: URL(fileURLWithPath: newID)) {
                    navigation.selection = .folder(source: source.id, id: newID)
                }
            }
        }
        .confirmationDialog("„\(deleteTarget?.name ?? "")“ löschen?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Löschen", role: .destructive) {
                if let folder = deleteTarget { library.delete(folder) }
                deleteTarget = nil
            }
        } message: {
            if let folder = deleteTarget {
                Text(library.deletesPermanently(at: folder.url)
                     ? "Der Ordner und \(Formatters.count(folder.trackCount, "Titel", "Titel")) werden endgültig vom Stick gelöscht."
                     : "Der Ordner und \(Formatters.count(folder.trackCount, "Titel", "Titel")) kommen in den Papierkorb.")
            }
        }
    }

    /// Direkt auf dem Stick liegende Titel erscheinen unter dem Namen des Sticks – nur, wenn es welche gibt.
    private func visibleFolders(in source: LibrarySource) -> [LibraryFolder] {
        let folders = library.folders(in: source.id)
        return folders.filter { !$0.isVolumeRoot || $0.trackCount > 0 || folders.count == 1 }
    }

    /// Springt zu einem gerade gewählten oder angelegten Ordner.
    private func selectFolder(_ url: URL?) {
        guard let url, let source = library.source(containing: url) else { return }
        navigation.selection = .folder(source: source.id, id: url.standardizedFileURL.path)
    }

    @ViewBuilder
    private func folderMenu(_ folder: LibraryFolder, in source: LibrarySource) -> some View {
        Button("Im Finder zeigen") { library.reveal([folder.url]) }
        if !folder.isVolumeRoot {
            Button("Umbenennen …") { renameTarget = folder }
            Divider()
            if !source.isExternal {
                Button("Aus der Seitenleiste entfernen") { library.removeMacFolder(folder.url) }
            }
            Button(source.isExternal ? "Löschen …" : "In den Papierkorb …", role: .destructive) { deleteTarget = folder }
        }
    }
}

/// Abschnittskopf einer Bibliothek: Name, „+“ für neue Ordner, Auswerfen bei Sticks.
private struct SourceHeader: View {
    @EnvironmentObject private var navigation: AppNavigation
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var analysis: AnalysisCenter
    let source: LibrarySource
    let onNewMacFolder: () -> Void
    let onAddMacFolder: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(source.name)
            if library.isScanning(source.id) {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            if let volume = source.volume {
                Button {
                    navigation.newFolderSource = source.id
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Neuer Ordner auf „\(source.name)“")

                Button {
                    Task { await library.eject(source.id) }
                } label: {
                    Image(systemName: "eject")
                }
                .buttonStyle(.borderless)
                .disabled(queue.isWriting(to: volume.url) || analysis.isBusy(within: volume.url))
                .help(queue.isWriting(to: volume.url) || analysis.isBusy(within: volume.url)
                      ? "Velvet schreibt noch auf diesen Stick" : "Auswerfen")
            } else {
                Menu {
                    Button("Neuer Ordner …", action: onNewMacFolder)
                    Button("Vorhandenen Ordner hinzufügen …", action: onAddMacFolder)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Ordner hinzufügen")
            }
        }
    }
}
