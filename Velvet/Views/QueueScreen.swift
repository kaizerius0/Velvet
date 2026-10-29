import SwiftUI

/// Bildschirm während eines Laufs: Gesamtfortschritt, Einträge mit Auswahl und am Ende die Zusammenfassung.
struct QueueScreen: View {
    @EnvironmentObject private var queue: QueueViewModel
    @State private var linkTarget: DownloadItem?
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 0) {
            RunHeader(confirmReset: $confirmReset)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if queue.isFinished {
                        SummaryCard()
                    }

                    FilterBar()

                    let visible = queue.filteredItems
                    if visible.isEmpty {
                        Text("Hier ist gerade nichts.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(30)
                    }
                    ForEach(visible) { item in
                        ItemRow(item: item) { linkTarget = item }
                    }
                }
                .padding(20)
            }
        }
        .sheet(item: $linkTarget) { item in
            ManualLinkSheet(item: item) { url in
                queue.useLink(url, for: item)
            }
        }
        .confirmationDialog("Neue Liste beginnen?", isPresented: $confirmReset) {
            Button("Downloads abbrechen und neu beginnen", role: .destructive) {
                queue.reset()
            }
        } message: {
            Text("Laufende Downloads werden abgebrochen. Bereits geladene Dateien bleiben erhalten.")
        }
    }
}

private struct RunHeader: View {
    @EnvironmentObject private var queue: QueueViewModel
    @Binding var confirmReset: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(queue.summary.finished) von \(queue.summary.total) erledigt")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let destination = queue.destination {
                    Button {
                        queue.openDestination()
                    } label: {
                        Label(destination.lastPathComponent, systemImage: "folder")
                    }
                    .help("Zielordner öffnen: \(destination.path)")
                }
                if queue.hasBusyItems {
                    Button {
                        queue.cancelAll()
                    } label: {
                        Label("Alle abbrechen", systemImage: "stop.circle")
                    }
                }
                Button {
                    if queue.hasBusyItems {
                        confirmReset = true
                    } else {
                        queue.reset()
                    }
                } label: {
                    Label("Neue Liste", systemImage: "plus")
                }
            }

            ProgressView(value: queue.overallProgress)
                .progressViewStyle(.linear)

            if queue.summary.needsAttention > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "hand.tap.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(attentionText)
                    Spacer()
                    if queue.filter != .attention {
                        Button("Nur diese zeigen") { queue.filter = .attention }
                    }
                    Button("Restliche überspringen") { queue.skipRemainingSelections() }
                }
                .bannerStyle()
            }
        }
    }

    private var subtitle: String {
        let summary = queue.summary
        var parts: [String] = []
        if summary.transferring > 0 { parts.append("\(summary.transferring) \(summary.transferring == 1 ? "lädt" : "laden")") }
        if summary.waiting > 0 { parts.append("\(summary.waiting) in der Warteschlange") }
        if summary.searching > 0 { parts.append("\(summary.searching) \(summary.searching == 1 ? "Suche läuft" : "Suchen laufen")") }
        if summary.needsAttention > 0 { parts.append("\(summary.needsAttention) \(summary.needsAttention == 1 ? "wartet" : "warten") auf dich") }
        if let options = queue.options {
            parts.append(options.format == .video ? "MP4 · \(options.videoQuality.title)" : "MP3 · \(options.audioQuality.title)")
        }
        return parts.joined(separator: " · ")
    }

    private var attentionText: String {
        let count = queue.summary.needsAttention
        return count == 1
            ? "1 Titel wartet auf deine Auswahl – klicke einfach auf das passende Video."
            : "\(count) Titel warten auf deine Auswahl – klicke einfach auf das passende Video."
    }
}

private struct FilterBar: View {
    @EnvironmentObject private var queue: QueueViewModel

    var body: some View {
        Picker("Anzeigen", selection: $queue.filter) {
            ForEach(QueueViewModel.Filter.allCases) { filter in
                Text("\(filter.title) (\(queue.count(for: filter)))").tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 560)
    }
}

/// Der große „Fertig“-Bereich am Ende eines Laufs.
struct SummaryCard: View {
    @EnvironmentObject private var queue: QueueViewModel

    var body: some View {
        let summary = queue.summary
        let failed = queue.failedItems

        Card(padding: 20) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: failed.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(failed.isEmpty ? Color.green : Color.orange)

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failed.isEmpty ? "Fertig! Alles erledigt." : "Fertig – mit \(Formatters.count(failed.count, "Fehler", "Fehlern"))")
                            .font(.title.weight(.bold))
                        if let destination = queue.destination {
                            Text("Gespeichert in „\(destination.path)“")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    HStack(spacing: 10) {
                        StatPill(value: summary.completed, title: "geladen", color: .green, systemImage: "checkmark.circle.fill")
                        StatPill(value: summary.skipped, title: "übersprungen", color: .blue, systemImage: "arrow.uturn.right.circle.fill")
                        StatPill(value: summary.failed, title: "fehlgeschlagen", color: .red, systemImage: "xmark.octagon.fill")
                        StatPill(value: summary.ignored + summary.cancelled, title: "ausgelassen", color: .gray, systemImage: "minus.circle.fill")
                    }

                    if !failed.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Nicht geklappt:")
                                .font(.subheadline.weight(.semibold))
                            ForEach(failed) { item in
                                FailureLine(item: item)
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            queue.openDestination()
                        } label: {
                            Label("Ordner im Finder öffnen", systemImage: "folder.fill")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        if !failed.isEmpty {
                            Button {
                                queue.retryAllFailed()
                            } label: {
                                Label("Fehlgeschlagene erneut versuchen", systemImage: "arrow.clockwise")
                            }
                            .controlSize(.large)
                        }

                        Button {
                            queue.reset()
                        } label: {
                            Label("Neue Liste", systemImage: "plus")
                        }
                        .controlSize(.large)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder((failed.isEmpty ? Color.green : Color.orange).opacity(0.5), lineWidth: 1.5)
        )
    }
}

private struct FailureLine: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("#\(item.number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(item.displayTitle)
                .fontWeight(.medium)
                .lineLimit(1)
            if case let .failed(message) = item.status {
                Text("– \(message)")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .font(.callout)
    }
}
