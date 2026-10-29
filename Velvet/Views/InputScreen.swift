import SwiftUI
import UniformTypeIdentifiers

/// Startbildschirm: Liste einfügen, Erkennung prüfen, Format wählen, „Alle starten“.
struct InputScreen: View {
    @EnvironmentObject private var input: InputViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var queue: QueueViewModel

    @State private var isDropTargeted = false
    @State private var alertMessage: String?

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
                    PreviewCard(result: input.parsed)
                        .frame(width: 320)
                }
                .frame(height: 440)

                OptionsCard()

                startButton
            }
            .padding(20)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
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
            return "Nach dem Klick wählst du den Zielordner. Tastenkürzel: ⌘↩"
        }
    }

    private func startRun() {
        let result = input.parseNow()
        guard !result.entries.isEmpty, tools.isReady else { return }
        guard let folder = FolderPicker.chooseDestination(startingAt: settings.lastDestination) else { return }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            alertMessage = "In den Ordner „\(folder.lastPathComponent)“ kann Velvet nicht schreiben. Bitte wähle einen anderen Ordner."
            return
        }
        queue.start(entries: result.entries, destination: folder)
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

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(result.entries.enumerated()), id: \.element.id) { index, entry in
                                PreviewRow(number: index + 1, entry: entry)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(entry.isLink ? Color.accentColor : .secondary)
            Text(entry.displayText)
                .font(.callout)
                .lineLimit(2)
                .help(entry.url?.absoluteString ?? entry.displayText)
        }
    }

    private var symbol: String {
        if entry.isPlaylist { return "list.and.film" }
        return entry.isLink ? "link" : "magnifyingglass"
    }
}

/// Format, Qualität, Zielordner und Optionen.
struct OptionsCard: View {
    @EnvironmentObject private var settings: AppSettings

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
                        label("Zielordner")
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text("Wird beim Start abgefragt")
                            if let last = settings.lastDestination {
                                Text("· zuletzt „\(last.lastPathComponent)“")
                                    .foregroundStyle(.secondary)
                                    .help(last.path)
                            }
                        }
                    }
                }

                Divider()

                HStack(spacing: 28) {
                    Toggle("Bestes Suchergebnis automatisch wählen", isOn: $settings.autoPickFirstResult)
                        .help("Spart Klicks bei langen Listen. Du kannst jedes Video danach trotzdem noch über „Andere Vorschläge“ ändern.")
                    Toggle("Bereits Geladenes überspringen (\(settings.format.archiveFileName))", isOn: $settings.useArchive)
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
