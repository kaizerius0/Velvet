import SwiftUI

/// Mehrere Titel auf einmal hinzufügen – eingefügt, aus einer Datei oder hineingezogen.
struct AddSeveralSheet: View {
    let sourceID: String
    /// Playlist, aus der das Fenster geöffnet wurde (`nil` = Hauptordner).
    let playlistID: String?

    @EnvironmentObject private var input: InputViewModel
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var targetID: String?
    @State private var hits: [Int: DuplicateHit] = [:]
    @State private var isDropTargeted = false

    private static let placeholder = """
    Queen – Bohemian Rhapsody
    Toto – Africa
    https://youtu.be/dQw4w9WgXcQ
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Mehrere Titel hinzufügen")
                    .font(.title2.weight(.bold))
                Spacer()
                Button("Aus Datei …") { input.chooseFile() }
            }

            HStack(alignment: .top, spacing: 14) {
                editor
                preview
                    .frame(width: 300)
            }
            .frame(height: 340)

            HStack(spacing: 12) {
                Picker("Hinzufügen zu", selection: $targetID) {
                    Text("Hauptordner").tag(String?.none)
                    ForEach(folderPlaylists) { playlist in
                        Text(playlist.name).tag(String?.some(playlist.id))
                    }
                }
                .fixedSize()
                Toggle("Vorhandene überspringen", isOn: $settings.skipExisting)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(addTitle, action: add)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(entriesToAdd.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 880)
        .onAppear {
            targetID = playlistID.flatMap { id in folderPlaylists.contains { $0.id == id } ? id : nil }
            updateHits()
        }
        .onChange(of: input.parsed) { _ in updateHits() }
        .onChange(of: library.revision) { _ in updateHits() }
    }

    // MARK: Teile

    private var editor: some View {
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
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isDropTargeted ? Color.accentColor : Theme.border, lineWidth: isDropTargeted ? 2 : 1)
        )
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Formatters.count(input.parsed.entries.count, "Titel erkannt", "Titel erkannt"))
                .font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(input.parsed.entries) { entry in
                        EntryPreviewRow(entry: entry, hit: hits[entry.id])
                    }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border.opacity(0.6)))
    }

    // MARK: Logik

    private var folderPlaylists: [Playlist] {
        library.playlists(in: sourceID).filter { !$0.isRoot }
    }

    /// Ohne Titel, die schon in dieser Bibliothek liegen (wenn gewünscht).
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
        hits = DuplicateChecker(library: library, history: history, sourceID: sourceID).hits(for: input.parsed.entries)
    }

    private func add() {
        let entries = entriesToAdd
        let folder: URL?
        if let targetID, let playlist = library.playlist(id: targetID, in: sourceID) {
            folder = playlist.url
        } else {
            folder = library.source(id: sourceID)?.rootURL
        }
        guard let folder, !entries.isEmpty else { return }
        queue.add(entries: entries, to: folder)
        input.clear()
        dismiss()
    }
}

/// Ein erkannter Eintrag – mit Hinweis, wenn er schon vorhanden ist.
private struct EntryPreviewRow: View {
    let entry: ParsedEntry
    let hit: DuplicateHit?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.isPlaylist ? "list.and.film" : entry.isLink ? "link" : "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayText)
                    .lineLimit(2)
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
