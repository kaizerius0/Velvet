import AppKit
import SwiftUI

/// Was wann wohin geladen wurde – und wo es heute liegt.
struct HistoryScreen: View {
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var input: InputViewModel
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var navigation: AppNavigation

    enum Filter: String, CaseIterable, Identifiable {
        case all, present, gone
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "Alle"
            case .present: return "Vorhanden"
            case .gone: return "Nicht mehr da"
            }
        }
    }

    struct Row: Identifiable {
        let entry: HistoryEntry
        let availability: HistoryAvailability

        var id: UUID { entry.id }
        var date: Date { entry.date }
        var title: String { entry.title }
        var location: String { entry.locationText }
        var format: String { entry.format }
        var statusRank: Int {
            switch availability {
            case .present: return 0
            case .offline: return 1
            case .missing: return 2
            case .replaced: return 3
            case .deleted: return 4
            }
        }
    }

    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\Row.date, order: .reverse)]
    @State private var confirmClear = false

    var body: some View {
        let rows = visibleRows
        VStack(spacing: 0) {
            header(count: rows.count)
            Divider()
            if history.entries.isEmpty {
                emptyState
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Datum", value: \.date) { row in
                        Text(Formatters.dateTime(row.date)).monospacedDigit()
                    }
                    .width(min: 110, ideal: 140, max: 170)
                    TableColumn("Titel", value: \.title) { row in
                        Text(row.title).help(row.entry.query.map { "Aus der Liste: „\($0)“" } ?? row.title)
                    }
                    TableColumn("Ort", value: \.location)
                        .width(min: 120, ideal: 200, max: 320)
                    TableColumn("Format", value: \.format)
                        .width(min: 50, ideal: 60, max: 70)
                    TableColumn("Status", value: \.statusRank) { row in
                        StatusLabel(availability: row.availability)
                    }
                    .width(min: 120, ideal: 170, max: 260)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    menu(for: rows.filter { ids.contains($0.id) })
                } primaryAction: { ids in
                    if let row = rows.first(where: { ids.contains($0.id) }), case let .present(url) = row.availability {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .confirmationDialog("Verlauf leeren?", isPresented: $confirmClear) {
            Button("Verlauf leeren", role: .destructive) { history.clear() }
        } message: {
            Text("Nur die Einträge im Verlauf werden gelöscht – deine Dateien bleiben, wo sie sind.")
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Verlauf").font(.title2.weight(.bold))
                Text("\(Formatters.count(count, "Eintrag", "Einträge")) · was du wann wohin geladen hast")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextField("Suchen", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Menu {
                Button("Verlauf leeren …", role: .destructive) { confirmClear = true }
                    .disabled(history.entries.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func menu(for rows: [Row]) -> some View {
        let present = rows.compactMap { row -> URL? in
            if case let .present(url) = row.availability { return url }
            return nil
        }
        if rows.count == 1, let url = present.first {
            Button("Abspielen") { NSWorkspace.shared.open(url) }
        }
        if !present.isEmpty {
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting(present) }
        }
        if rows.count == 1, let source = rows.first?.entry.sourceURL, let url = URL(string: source) {
            Button("Auf YouTube öffnen") { NSWorkspace.shared.open(url) }
        }
        Button(rows.count == 1 ? "Erneut laden" : "\(rows.count) Einträge erneut laden") { reload(rows) }
            .disabled(queue.hasRun)
            .help(queue.hasRun ? "Erst den laufenden Download-Lauf beenden." : "")
        Divider()
        Button("Aus dem Verlauf entfernen", role: .destructive) {
            history.remove(Set(rows.map(\.id)))
            selection.subtract(rows.map(\.id))
        }
    }

    /// Setzt die Einträge unter „Downloads“ in die Liste.
    private func reload(_ rows: [Row]) {
        let lines = rows.map { $0.entry.sourceURL ?? $0.entry.query ?? $0.entry.title }
        let current = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        input.text = ([current].filter { !$0.isEmpty } + lines).joined(separator: "\n")
        navigation.section = .downloads
    }

    private var visibleRows: [Row] {
        let words = search.lowercased().split(separator: " ")
        return history.entries
            .filter { entry in
                words.isEmpty || words.allSatisfy { word in
                    "\(entry.title) \(entry.query ?? "") \(entry.locationText)".lowercased().contains(word)
                }
            }
            .map { Row(entry: $0, availability: history.availability(of: $0, volumes: library.volumes)) }
            .filter { row in
                switch filter {
                case .all: return true
                case .present: return row.availability.isPresent
                case .gone: return !row.availability.isPresent
                }
            }
            .sorted(using: sortOrder)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Noch nichts geladen").font(.headline)
            Text("Alles, was du ab jetzt lädst, erscheint hier – mit Ort und Status.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatusLabel: View {
    let availability: HistoryAvailability

    var body: some View {
        switch availability {
        case .present:
            Label("Vorhanden", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .offline(volume):
            Label("\(volume) nicht verbunden", systemImage: "externaldrive.badge.xmark").foregroundStyle(.secondary)
        case .missing:
            Label("Nicht mehr da", systemImage: "questionmark.circle").foregroundStyle(.orange)
        case let .replaced(note):
            Label(note ?? "Ersetzt", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
                .help(note ?? "Ersetzt")
        case .deleted:
            Label("Gelöscht", systemImage: "trash").foregroundStyle(.secondary)
        }
    }
}
