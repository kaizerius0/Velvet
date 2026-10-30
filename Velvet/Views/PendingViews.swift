import AppKit
import SwiftUI

/// Ein Titel, der gerade hinzugefügt wird – mit Fortschritt oder der nötigen Aktion.
struct PendingRow: View {
    @ObservedObject var item: DownloadItem
    let queue: QueueViewModel
    /// Zeigt zusätzlich das Ziel, z. B. „AUTO-STICK › Rock“.
    var location: String?

    @State private var showChooser = false

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: item.thumbnailURL, placeholderSymbol: "music.note", cornerRadius: 4)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .help(statusText)
            }
            Spacer(minLength: 12)
            trailing
            if item.status != .completed {
                Button {
                    queue.remove(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Entfernen")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .popover(isPresented: $showChooser, arrowEdge: .bottom) {
            CandidateChooser(item: item, queue: queue) { showChooser = false }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.status {
        case .searching, .resolvingPlaylist, .waiting:
            ProgressView().controlSize(.small)
        case .downloading, .processing:
            HStack(spacing: 8) {
                ProgressView(value: item.progress)
                    .frame(width: 120)
                Text(Formatters.percent(item.progress))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        case .needsSelection, .noResults:
            Button("Auswählen") { showChooser = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .failed:
            HStack(spacing: 6) {
                Button("Erneut versuchen") { queue.retry(item) }
                    .controlSize(.small)
                Button("Andere Version") {
                    queue.showMoreSuggestions(for: item)
                    showChooser = true
                }
                .controlSize(.small)
                .disabled(!item.canSuggest)
            }
        case let .skipped(reason):
            if reason.canForce {
                Button("Trotzdem laden") { queue.forceDownload(item) }
                    .controlSize(.small)
            }
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cancelled, .ignored:
            Button("Erneut versuchen") { queue.retry(item) }
                .controlSize(.small)
        }
    }

    private var statusText: String {
        let text: String
        switch item.status {
        case .searching: text = "Suche …"
        case .resolvingPlaylist: text = "Playlist wird gelesen …"
        case .waiting: text = "Wartet"
        case .downloading: text = item.detail ?? "Wird geladen …"
        case .processing: text = item.phaseText ?? "Wird fertiggestellt …"
        case .needsSelection: text = "Welche Version?"
        case .noResults: text = "Keine Treffer"
        case .completed: text = "Hinzugefügt"
        case let .skipped(reason): text = reason.text
        case let .failed(message): text = message
        case .cancelled, .ignored: text = "Abgebrochen"
        }
        guard let location else { return text }
        return "\(location) · \(text)"
    }

    private var statusColor: Color {
        switch item.status {
        case .failed: return .red
        case .needsSelection, .noResults: return .accentColor
        case .completed: return .green
        default: return .secondary
        }
    }
}

/// Unten in der Seitenleiste: was gerade passiert – ein Klick zeigt alle laufenden Titel.
struct ActivityButton: View {
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var library: LibraryViewModel
    @State private var showDetails = false

    var body: some View {
        if !queue.activity.isEmpty {
            Button {
                showDetails.toggle()
            } label: {
                HStack(spacing: 8) {
                    if queue.activity.busy > 0 {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: queue.activity.needsAttention > 0 ? "hand.tap" : "exclamationmark.triangle")
                            .foregroundStyle(queue.activity.needsAttention > 0 ? Color.accentColor : .orange)
                    }
                    Text(summary)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDetails, arrowEdge: .trailing) {
                ActivityPopover(queue: queue, library: library)
            }
        }
    }

    private var summary: String {
        let activity = queue.activity
        var parts: [String] = []
        if activity.busy > 0 { parts.append("\(activity.busy) \(activity.busy == 1 ? "Titel wird" : "Titel werden") geladen") }
        if activity.needsAttention > 0 { parts.append("\(activity.needsAttention) zur Auswahl") }
        if activity.problems > 0 { parts.append(Formatters.count(activity.problems, "Problem", "Probleme")) }
        return parts.joined(separator: " · ")
    }
}

private struct ActivityPopover: View {
    @ObservedObject var queue: QueueViewModel
    let library: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Wird hinzugefügt").font(.headline)
                Spacer()
                if queue.activity.problems > 0 {
                    Button("Alle erneut versuchen") { queue.retryAllProblems() }
                        .controlSize(.small)
                }
                Button("Alle abbrechen", role: .destructive) { queue.removeAll() }
                    .controlSize(.small)
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queue.items) { item in
                        PendingRow(item: item, queue: queue, location: library.locationText(forFolder: item.destination))
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 560)
    }
}
