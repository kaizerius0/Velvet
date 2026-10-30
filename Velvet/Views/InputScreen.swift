import SwiftUI
import UniformTypeIdentifiers

/// Startbildschirm: Liste einfügen, Erkennung prüfen, Format wählen, „Alle starten“.
struct InputScreen: View {
    @EnvironmentObject private var input: InputViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var history: HistoryStore

    @State private var isDropTargeted = false
    @State private var alertMessage: String?
    /// Einträge, die schon vorhanden sind (Eintrags-ID → Fundstelle).
    @State private var hits: [Int: DuplicateHit] = [:]

    private static let placeholder = """
    Füge hier deine Liste ein – zum Beispiel:

    1. Queen – Bohemian Rhapsody
    2) Toto - Africa (Official Video)
    - daft punk get lucky
    • a-ha take on me, live
    https://www.youtube.com/watch?v=dQw4w9WgXcQ

    Nummern, Spiegelstriche, Emojis und Zusatztext werden automatisch entfernt.
    """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if case let .failed(message) = tools.state {
                    ToolFailureBanner(message: message)
                }

                HStack(alignment: .top, spacing: 16) {
                    editorCard
                    PreviewCard(result: input.parsed, hits: hits)
                        .frame(width: 340)
                }
                .frame(height: 440)

                OptionsCard()

                startButton
            }
            .padding(20)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .onAppear(perform: updateHits)
        .onChange(of: input.parsed) { _ in updateHits() }
        .onChange(of: library.revision) { _ in updateHits() }
        .onChange(of: history.revision) { _ in updateHits() }
        .alert("Hinweis", isPresented: Binding(
            get: { alertMessage != nil || input.errorMessage != nil },
            set: { if !$0 { alertMessage = nil; input.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? input.errorMessage ?? "")
        }
    }

    // MARK: Liste

    private var editorCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(
                    title: "Deine Liste",
                    systemImage: "list.bullet.rectangle",
                    subtitle: "Titel oder YouTube-Links – eine Zeile pro Video oder Lied. Ungenaue Titel sind kein Problem."
                )

                ZStack(alignment: .topLeading) {
                    ListTextEditor(text: $input.text, isDropTargeted: $isDropTargeted, onFileDrop: input.load)
                    if input.text.isEmpty {
                        Text(Self.placeholder)
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    if isDropTargeted {
                        dropOverlay
                    }
                }
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isDropTargeted ? Color.accentColor : Theme.border, lineWidth: isDropTargeted ? 2 : 1)
                )

                HStack(spacing: 10) {
                    Button {
                        input.chooseFile()
                    } label: {
                        Label("Liste aus .txt-Datei laden …", systemImage: "doc.text")
                    }
                    Button {
                        input.pasteFromClipboard()
                    } label: {
                        Label("Einfügen", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        input.clear()
                    } label: {
                        Label("Leeren", systemImage: "trash")
                    }
                    .disabled(input.text.isEmpty)

                    Spacer()

                    if let notice = input.notice {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .lineLimit(1)
                    } else {
                        Text("oder .txt-Datei hierher ziehen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.accentColor.opacity(0.12))
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus").font(.system(size: 36))
                    Text("Datei loslassen, um die Liste zu laden").font(.headline)
                }
                .foregroundStyle(Color.accentColor)
            )
            .allowsHitTesting(false)
    }

    // MARK: Start

    private var startButton: some View {
        VStack(spacing: 8) {
            Button(action: startRun) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(startTitle)
                }
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(input.parsed.entries.isEmpty || !tools.isReady)

            Text(startHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var startTitle: String {
        let count = input.parsed.entries.count
        return count == 0 ? "Alle starten" : "Alle starten (\(Formatters.count(count, "Eintrag", "Einträge")))"
    }

    private var startHint: String {
        switch tools.state {
        case .checking:
            return "Einen Moment – die eingebauten Werkzeuge werden geprüft …"
        case .failed:
            return "Die Werkzeuge müssen erst funktionieren (siehe Hinweis oben)."
        case .ready:
            if input.parsed.entries.isEmpty { return "Füge zuerst eine Liste ein." }
            if let target = targetDescription { return "Speichert in \(target). Tastenkürzel: ⌘↩" }
            return "Nach dem Klick wählst du den Zielordner. Tastenkürzel: ⌘↩"
        }
    }

    /// „AUTO-STICK › Rock“, wenn ein Ziel in der Bibliothek gewählt ist.
    private var targetDescription: String? {
        guard library.status == .ready, let name = library.location?.shortName else { return nil }
        switch settings.downloadTarget {
        case .ask: return nil
        case .libraryRoot: return "\(name) › Hauptordner"
        case let .playlist(playlist): return "\(name) › \(playlist)"
        }
    }

    private func updateHits() {
        hits = DuplicateChecker(library: library, history: history).hits(for: input.parsed.entries)
    }

    private func startRun() {
        let result = input.parseNow()
        guard !result.entries.isEmpty, tools.isReady else { return }
        guard let folder = resolveDestination() else { return }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            alertMessage = "In den Ordner „\(folder.lastPathComponent)“ kann Velvet nicht schreiben. Bitte wähle einen anderen Ordner."
            return
        }
        // Was schon in der Bibliothek liegt, wird übersprungen (kann im Lauf trotzdem geladen werden).
        var existing: [Int: String] = [:]
        if settings.skipExisting, library.contains(folder) {
            let found = DuplicateChecker(library: library, history: history).hits(for: result.entries)
            for (id, hit) in found where hit.strength == .exact && hit.inCurrentLibrary {
                existing[id] = hit.location
            }
        }
        queue.start(entries: result.entries, destination: folder, existing: existing)
    }

    private func resolveDestination() -> URL? {
        if library.status == .ready {
            switch settings.downloadTarget {
            case .ask: break
            case .libraryRoot: return library.rootURL
            case let .playlist(name): return library.folder(forPlaylist: name)
            }
        }
        return FolderPicker.chooseDestination(startingAt: settings.lastDestination ?? library.rootURL)
    }

    // MARK: Drag & Drop außerhalb des Textfelds

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
}

/// Rechte Spalte: zeigt live, was aus der Liste erkannt wurde.
struct PreviewCard: View {
    let result: ListParseResult
    var hits: [Int: DuplicateHit] = [:]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Erkannt", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    Text("\(result.entries.count)")
                        .font(.headline.monospacedDigit())
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }

                if result.entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 34))
                            .foregroundStyle(.tertiary)
                        Text("Noch keine Einträge")
                            .font(.callout.weight(.medium))
                        Text("Sobald du links etwas einfügst, siehst du hier, welche Titel und Links Velvet erkannt hat.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    HStack(spacing: 14) {
                        Label(Formatters.count(result.searchCount, "Titel", "Titel"), systemImage: "magnifyingglass")
                        Label(Formatters.count(result.linkCount, "Link", "Links"), systemImage: "link")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if !hits.isEmpty {
                        Label(duplicateText, systemImage: "externaldrive.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(result.entries.enumerated()), id: \.element.id) { index, entry in
                                PreviewRow(number: index + 1, entry: entry, hit: hits[entry.id])
                            }
                        }
                    }

                    if result.duplicateCount > 0 || result.ignoredLineCount > 0 {
                        Text(skippedText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)
    }

    private var duplicateText: String {
        let exact = hits.values.filter { $0.strength == .exact }.count
        let similar = hits.count - exact
        var parts: [String] = []
        if exact > 0 { parts.append("\(exact) schon vorhanden") }
        if similar > 0 { parts.append("\(similar) ähnlich") }
        return parts.joined(separator: " · ")
    }

    private var skippedText: String {
        var parts: [String] = []
        if result.duplicateCount > 0 { parts.append(Formatters.count(result.duplicateCount, "Duplikat entfernt", "Duplikate entfernt")) }
        if result.ignoredLineCount > 0 { parts.append(Formatters.count(result.ignoredLineCount, "Zeile ignoriert", "Zeilen ignoriert")) }
        return parts.joined(separator: " · ")
    }
}

private struct PreviewRow: View {
    let number: Int
    let entry: ParsedEntry
    let hit: DuplicateHit?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(entry.isLink ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayText)
                    .font(.callout)
                    .lineLimit(2)
                    .help(entry.url?.absoluteString ?? entry.displayText)
                if let hit {
                    Label(hitText(hit), systemImage: hit.strength == .exact ? "checkmark.circle.fill" : "questionmark.circle")
                        .font(.caption2)
                        .foregroundStyle(hit.strength == .exact ? Color.green : Color.orange)
                        .lineLimit(1)
                        .help("„\(hit.title)“ – \(hit.location)")
                }
            }
        }
    }

    private func hitText(_ hit: DuplicateHit) -> String {
        switch hit.strength {
        case .exact: return "Schon vorhanden: \(hit.location)"
        case .similar: return "Ähnlich: „\(hit.title)“ in \(hit.location)"
        }
    }

    private var symbol: String {
        if entry.isPlaylist { return "list.and.film" }
        return entry.isLink ? "link" : "magnifyingglass"
    }
}

/// Format, Qualität, Ziel und Optionen.
struct OptionsCard: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Einstellungen", systemImage: "slider.horizontal.3")

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        label("Format")
                        Picker("Format", selection: $settings.format) {
                            ForEach(MediaFormat.allCases) { format in
                                Text(format.title).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        label("Qualität")
                        Group {
                            if settings.format == .video {
                                Picker("Qualität", selection: $settings.videoQuality) {
                                    ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                                }
                            } else {
                                Picker("Qualität", selection: $settings.audioQuality) {
                                    ForEach(AudioQuality.allCases) { Text($0.title).tag($0) }
                                }
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        label("Speichern in")
                        TargetPicker()
                    }
                }

                Divider()

                HStack(spacing: 28) {
                    Toggle("Bestes Suchergebnis automatisch wählen", isOn: $settings.autoPickFirstResult)
                        .help("Spart Klicks bei langen Listen. Du kannst jedes Video danach trotzdem noch über „Andere Vorschläge“ ändern.")
                    if library.status == .ready {
                        Toggle("Titel überspringen, die schon auf \(library.location?.shortName ?? "dem Stick") sind", isOn: $settings.skipExisting)
                            .help("Velvet vergleicht die Liste mit den Dateien in der Bibliothek. Übersprungene Titel kannst du im Lauf trotzdem laden.")
                    }
                    Toggle("Archiv nutzen (\(settings.format.archiveFileName))", isOn: $settings.useArchive)
                        .help("Velvet merkt sich im Zielordner, welche Videos schon geladen wurden, und überspringt sie beim nächsten Mal.")
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

/// Ziel eines Laufs: eine Playlist auf dem Stick, dessen Hauptordner oder jedes Mal fragen.
private struct TargetPicker: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var navigation: AppNavigation
    @State private var showNewPlaylist = false

    var body: some View {
        HStack(spacing: 8) {
            if library.status == .ready {
                Picker("Speichern in", selection: $settings.downloadTarget) {
                    Text("\(library.location?.shortName ?? "Bibliothek") – Hauptordner").tag(AppSettings.Target.libraryRoot)
                    ForEach(library.folderPlaylists) { playlist in
                        Text("Playlist „\(playlist.name)“").tag(AppSettings.Target.playlist(playlist.name))
                    }
                    if case let .playlist(name) = settings.downloadTarget, !library.folderPlaylists.contains(where: { $0.name == name }) {
                        Text("Playlist „\(name)“ (wird angelegt)").tag(settings.downloadTarget)
                    }
                    Divider()
                    Text("Jedes Mal fragen …").tag(AppSettings.Target.ask)
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    showNewPlaylist = true
                } label: {
                    Label("Neue Playlist", systemImage: "plus")
                }
            } else {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text("Wird beim Start abgefragt")
                Button("Stick als Ziel wählen …") { navigation.section = .library }
                    .buttonStyle(.link)
            }
        }
        .sheet(isPresented: $showNewPlaylist) {
            NameSheet(title: "Neue Playlist", initial: "", confirm: "Anlegen") { name in
                if let playlist = library.createPlaylist(named: name) {
                    settings.downloadTarget = .playlist(playlist.name)
                }
            }
        }
    }
}
