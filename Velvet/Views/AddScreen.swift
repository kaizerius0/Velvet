import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Titel hinzufügen: einen oder eine ganze Liste eingeben, rechts sehen, was erkannt wurde,
/// Ziel wählen – darunter laufen die Titel durch, Versionen wählt man per Wischen aus.
struct AddScreen: View {
    @EnvironmentObject private var input: InputViewModel
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var navigation: AppNavigation

    @State private var hits: [Int: DuplicateHit] = [:]
    @State private var isDropTargeted = false

    private static let placeholder = """
    Queen – Bohemian Rhapsody
    Toto – Africa
    https://youtu.be/dQw4w9WgXcQ
    """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if case let .failed(message) = tools.state {
                    ToolFailureBanner(message: message)
                }

                Text("Hinzufügen")
                    .font(.title.weight(.bold))

                HStack(alignment: .top, spacing: 16) {
                    editor
                    preview
                        .frame(width: 320)
                }
                .frame(height: 260)

                actionBar

                if !queue.items.isEmpty {
                    queueSection
                }
            }
            .padding(20)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .onAppear(perform: updateHits)
        .onChange(of: input.parsed) { _ in updateHits() }
        .onChange(of: library.revision) { _ in updateHits() }
        .onChange(of: history.revision) { _ in updateHits() }
        .onChange(of: settings.addTargetPath) { _ in updateHits() }
    }

    // MARK: Eingabe

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            ListTextEditor(text: $input.text, isDropTargeted: $isDropTargeted, focusTrigger: navigation.focusInput, onFileDrop: input.load)
            if input.text.isEmpty {
                Text(Self.placeholder)
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTargeted ? Color.accentColor : Theme.border, lineWidth: isDropTargeted ? 2 : 1)
        )
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Erkannt")
                    .font(.headline)
                Spacer()
                Text("\(input.parsed.entries.count)")
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
            if input.parsed.entries.isEmpty {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let summary = duplicateSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(input.parsed.entries.enumerated()), id: \.element.id) { index, entry in
                            PreviewRow(number: index + 1, entry: entry, hit: hits[entry.id])
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border.opacity(0.6)))
    }

    private var duplicateSummary: String? {
        guard !hits.isEmpty else { return nil }
        let exact = hits.values.filter { $0.strength == .exact }.count
        let similar = hits.count - exact
        var parts: [String] = []
        if exact > 0 { parts.append("\(exact) schon vorhanden") }
        if similar > 0 { parts.append("\(similar) ähnlich") }
        return parts.joined(separator: " · ")
    }

    // MARK: Ziel und Start

    private var actionBar: some View {
        HStack(spacing: 12) {
            TargetFolderMenu()
            Picker("Format", selection: $settings.format) {
                Text(settings.audioQuality.fileType).tag(MediaFormat.audio)
                Text("MP4").tag(MediaFormat.video)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Version", selection: $settings.preferredVersion) {
                ForEach(PreferredVersion.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .help(settings.preferredVersion.explanation)
            Button("Aus Datei …") { input.chooseFile() }
            if !hits.isEmpty {
                Toggle("Vorhandene überspringen", isOn: $settings.skipExisting)
                    .toggleStyle(.checkbox)
            }
            Spacer()
            Button(action: add) {
                Text(addTitle)
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(entriesToAdd.isEmpty || !tools.isReady)
        }
    }

    private var target: URL? { settings.addTarget }

    private var targetSourceID: String? {
        target.flatMap { library.source(containing: $0)?.id }
    }

    @discardableResult
    private func chooseTarget() -> URL? {
        guard let url = library.chooseFolder(title: "Wohin sollen die Titel?", startingAt: target) else { return nil }
        settings.addTarget = url
        return url
    }

    private var entriesToAdd: [ParsedEntry] {
        let entries = input.parsed.entries
        guard settings.skipExisting else { return entries }
        return entries.filter { entry in
            guard let hit = hits[entry.id] else { return true }
            return !(hit.strength == .exact && hit.inCurrentLibrary)
        }
    }

    private var addTitle: String {
        let count = entriesToAdd.count
        return count == 0 ? "Hinzufügen" : "\(Formatters.count(count, "Titel", "Titel")) hinzufügen"
    }

    private func updateHits() {
        hits = DuplicateChecker(library: library, history: history, sourceID: targetSourceID).hits(for: input.parsed.entries)
    }

    private func add() {
        input.parseNow()
        let entries = entriesToAdd
        // Noch kein Ordner gewählt (oder der Stick ist abgezogen): erst fragen.
        guard !entries.isEmpty, let folder = target ?? chooseTarget() else { return }
        queue.add(entries: entries, to: folder)
        input.clear()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, TextFileLoader.isSupported(url) else { return }
                DispatchQueue.main.async { input.load(from: url) }
            }
        }
        return accepted
    }

    // MARK: Laufende Titel

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Wird hinzugefügt")
                    .font(.title2.weight(.bold))
                Text(queueSummary)
                    .foregroundStyle(.secondary)
                Spacer()
                if queue.activity.completed > 0 || queue.items.contains(where: { $0.status == .ignored || $0.status == .cancelled }) {
                    Button("Erledigte ausblenden") { queue.clearFinished() }
                }
                if queue.activity.problems > 0 {
                    Button("Alle erneut versuchen") { queue.retryAllProblems() }
                }
                if queue.hasBusyItems {
                    Button("Alle abbrechen", role: .destructive) { queue.removeAll() }
                }
            }
            ProgressView(value: queue.overallProgress)
                .progressViewStyle(.linear)

            ForEach(queue.items) { item in
                AddItemCard(item: item)
            }
        }
        .padding(.top, 8)
    }

    private var queueSummary: String {
        let activity = queue.activity
        var parts: [String] = []
        if activity.completed > 0 { parts.append("\(activity.completed) fertig") }
        if activity.busy > 0 { parts.append("\(activity.busy) \(activity.busy == 1 ? "lädt" : "laden")") }
        if activity.needsAttention > 0 { parts.append("\(activity.needsAttention) \(activity.needsAttention == 1 ? "wartet" : "warten") auf dich") }
        if activity.problems > 0 { parts.append(Formatters.count(activity.problems, "Problem", "Probleme")) }
        return parts.joined(separator: " · ")
    }
}

/// Ein erkannter Eintrag in der Vorschau – mit Hinweis, wenn er schon vorhanden ist.
private struct PreviewRow: View {
    let number: Int
    let entry: ParsedEntry
    let hit: DuplicateHit?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            Image(systemName: entry.isSpotify ? "music.note.list" : entry.isPlaylist ? "list.and.film" : entry.isLink ? "link" : "magnifyingglass")
                .font(.caption)
                .foregroundStyle(entry.isLink ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayText)
                    .lineLimit(2)
                    .help(entry.url?.absoluteString ?? entry.displayText)
                if let hit {
                    Text(hit.strength == .exact ? "Schon in \(hit.location)" : "Ähnlich: „\(hit.title)“")
                        .font(.caption)
                        .foregroundStyle(hit.strength == .exact ? Color.green : Color.orange)
                        .lineLimit(1)
                        .help("„\(hit.title)“ – \(hit.location)")
                }
            }
        }
    }
}

/// Ein Titel auf dem Weg in seinen Ordner – mit Fortschritt, Auswahl per Wischen oder Aktionen.
struct AddItemCard: View {
    @ObservedObject var item: DownloadItem

    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var navigation: AppNavigation
    @EnvironmentObject private var player: PreviewPlayer

    @State private var query = ""
    @State private var link = ""
    @State private var showLinkSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Thumbnail(url: item.thumbnailURL, placeholderSymbol: item.origin == .search ? "magnifyingglass" : "link")
                    .frame(width: 112)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ItemStatusLine(item: item)
                    if item.status.isTransferring {
                        ProgressView(value: item.progress)
                            .controlSize(.small)
                    }
                }
                Spacer(minLength: 8)
                actions
            }
            if showsChooser {
                chooser
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Theme.cardBackground))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(item.status.needsAttention ? Color.accentColor.opacity(0.7) : Theme.border.opacity(0.6),
                              lineWidth: item.status.needsAttention ? 1.5 : 1)
        )
        .sheet(isPresented: $showLinkSheet) {
            ManualLinkSheet(item: item) { queue.useLink($0, for: item) }
        }
    }

    private var subtitle: String {
        var parts = ["→ \(library.locationText(forFolder: item.destination))"]
        if item.origin == .search { parts.append("Gesucht: „\(item.originalText)“") }
        return parts.joined(separator: " · ")
    }

    /// Die Auswahl bleibt sichtbar, auch während neu gesucht wird.
    private var showsChooser: Bool {
        item.status.needsAttention || (item.status == .searching && item.hasSearched)
    }

    // MARK: Auswahl

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Suchbegriff", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { queue.search(item, for: query) }
                Button("Suchen") { queue.search(item, for: query) }
                Spacer()
                TextField("Eigener YouTube-Link", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(useLink)
                Button("Laden", action: useLink)
                    .disabled(ListParser.link(from: link) == nil)
            }

            switch item.status {
            case .searching:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 190)
            case .noResults:
                Text("Keine Treffer")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            default:
                let checker = DuplicateChecker(library: library, history: history,
                                               sourceID: library.source(containing: item.destination)?.id)
                CandidateCarousel(
                    candidates: item.candidates,
                    isLoadingMore: item.isLoadingMore,
                    canLoadMore: item.hasMoreCandidates,
                    existing: { checker.existingLocation(of: $0) },
                    onPreview: { player.play($0) },
                    onLoadMore: { queue.loadMoreCandidates(for: item) },
                    onSelect: { queue.choose($0, for: item) }
                )
                .frame(height: 226)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .onAppear { query = item.query }
        .onChange(of: item.query) { query = $0 }
    }

    private func useLink() {
        guard let url = ListParser.link(from: link), !YouTubeLink.isPlaylist(url), !YouTubeLink.isChannel(url) else { return }
        queue.useLink(url, for: item)
        link = ""
    }

    // MARK: Aktionen

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch item.status {
            case .completed:
                Button("Im Ordner zeigen", action: showInFolder)
                if item.canSuggest {
                    Button("Andere Version") { queue.showMoreSuggestions(for: item) }
                }
            case .failed:
                Button("Erneut versuchen") { queue.retry(item) }
                if item.canSuggest {
                    Button("Andere Version") { queue.showMoreSuggestions(for: item) }
                }
            case let .skipped(reason):
                if reason.canForce {
                    Button("Trotzdem laden") { queue.forceDownload(item) }
                }
            case .cancelled, .ignored:
                Button("Erneut versuchen") { queue.retry(item) }
            case .needsSelection, .noResults:
                Button("Überspringen") { queue.remove(item) }
            case .waiting, .searching, .resolvingPlaylist, .downloading, .processing:
                EmptyView()
            }
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Eigenen Link eingeben …") { showLinkSheet = true }
            if let url = item.sourceURL {
                Button("Im Browser öffnen") { NSWorkspace.shared.open(url) }
            }
            if !item.log.isEmpty {
                Button("Protokoll kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.log.joined(separator: "\n"), forType: .string)
                }
            }
            Divider()
            Button(item.status.isBusy ? "Abbrechen" : "Entfernen", role: .destructive) { queue.remove(item) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Ordner, die nicht in der Seitenleiste stehen, zeigt der Finder.
    private func showInFolder() {
        let folder = item.destination.standardizedFileURL
        if let source = library.source(containing: folder), library.folder(id: folder.path, in: source.id) != nil {
            navigation.selection = .folder(source: source.id, id: folder.path)
        } else {
            library.reveal([item.outputFile ?? folder])
        }
    }
}

/// Symbol und Text zum Zustand eines Titels.
private struct ItemStatusLine: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(text)
                .foregroundStyle(color)
                .lineLimit(2)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.status {
        case .searching, .resolvingPlaylist, .processing, .waiting:
            ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 16, height: 16)
        default:
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch item.status {
        case .needsSelection: return "hand.tap.fill"
        case .noResults: return "questionmark.circle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .skipped: return "arrow.uturn.right.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled, .ignored: return "stop.circle"
        case .searching, .resolvingPlaylist, .processing, .waiting: return "circle"
        }
    }

    private var color: Color {
        switch item.status {
        case .needsSelection, .downloading: return .accentColor
        case .noResults: return .orange
        case .completed: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private var text: String {
        switch item.status {
        case .waiting: return "Wartet …"
        case .searching: return item.hasSearched ? "Neue Vorschläge …" : "Suche …"
        case .needsSelection: return "Welche Version?"
        case .noResults: return "Keine Treffer"
        case .resolvingPlaylist: return "Playlist wird gelesen …"
        case .downloading:
            let percent = Formatters.percent(item.progress)
            return item.detail.map { "\(percent) · \($0)" } ?? percent
        case .processing: return item.phaseText ?? "Wird fertiggestellt …"
        case .completed: return item.outputFile.map { "Hinzugefügt · \($0.lastPathComponent)" } ?? "Hinzugefügt"
        case let .skipped(reason): return reason.text
        case let .failed(message): return message
        case .cancelled: return "Abgebrochen"
        case .ignored: return "Übersprungen"
        }
    }
}
