import AppKit
import SwiftUI

/// Eine Zeile der Download-Liste – mit Status, Fortschritt, Aktionen und ggf. der Video-Auswahl.
struct ItemRow: View {
    @ObservedObject var item: DownloadItem
    var onEnterLink: () -> Void

    @EnvironmentObject private var queue: QueueViewModel
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Thumbnail(url: item.thumbnailURL, placeholderSymbol: item.origin == .search ? "magnifyingglass" : "link")
                    .frame(width: 112)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("#\(item.number)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(item.displayTitle)
                            .font(.headline)
                            .lineLimit(2)
                    }
                    Text(item.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    StatusLine(item: item)
                    if item.status.isTransferring {
                        ProgressView(value: item.progress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    }
                }

                Spacer(minLength: 8)

                actions
            }

            if showsPicker {
                CandidatePicker(item: item, onEnterLink: onEnterLink)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Theme.cardBackground))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(item.status.needsAttention ? Color.accentColor.opacity(0.7) : Theme.border.opacity(0.6),
                              lineWidth: item.status.needsAttention ? 1.5 : 1)
        )
    }

    /// Die Auswahl bleibt auch sichtbar, während neue Vorschläge geladen werden.
    private var showsPicker: Bool {
        item.status.needsAttention || (item.status == .searching && item.hasSearched)
    }

    // MARK: Aktionen

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch item.status {
            case .waiting, .searching, .resolvingPlaylist, .downloading, .processing:
                if !(item.status == .searching && item.hasSearched) {
                    Button {
                        queue.cancel(item)
                    } label: {
                        Label("Abbrechen", systemImage: "xmark")
                    }
                }
            case .completed:
                Button {
                    queue.reveal(item)
                } label: {
                    Label("Im Finder zeigen", systemImage: "magnifyingglass")
                }
                suggestionsButton
            case let .skipped(reason):
                if reason == .archived {
                    Button("Trotzdem laden") { queue.downloadIgnoringArchive(item) }
                        .help("Lädt das Video erneut, obwohl es im Archiv steht.")
                }
                suggestionsButton
            case .failed:
                Button {
                    queue.retry(item)
                } label: {
                    Label("Erneut versuchen", systemImage: "arrow.clockwise")
                }
                suggestionsButton
            case .cancelled, .ignored:
                Button {
                    queue.retry(item)
                } label: {
                    Label("Wieder aufnehmen", systemImage: "arrow.clockwise")
                }
            case .needsSelection, .noResults:
                EmptyView()
            }

            moreMenu
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var suggestionsButton: some View {
        if item.canSuggest {
            Button {
                queue.showMoreSuggestions(for: item)
            } label: {
                Label("Andere Vorschläge", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Falsches Video? Zeigt fünf neue Vorschläge – die alte Datei wird ersetzt.")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Eigenen Link eingeben …", action: onEnterLink)
            if item.canSuggest, !item.status.needsAttention {
                Button("Andere Vorschläge") { queue.showMoreSuggestions(for: item) }
            }
            if let url = item.sourceURL {
                Divider()
                Button("Im Browser öffnen") { NSWorkspace.shared.open(url) }
                Button("Link kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            if !item.log.isEmpty {
                Divider()
                Button("Protokoll anzeigen") { showLog = true }
            }
            if !item.status.isTerminal {
                Divider()
                Button("Überspringen") { queue.skip(item) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Weitere Aktionen")
        .popover(isPresented: $showLog, arrowEdge: .bottom) {
            LogView(lines: item.log)
        }
    }
}

/// Symbol und Text zum aktuellen Status.
private struct StatusLine: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(text)
                .foregroundStyle(color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.status {
        case .searching, .resolvingPlaylist, .processing:
            ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 16, height: 16)
        default:
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch item.status {
        case .waiting: return "clock"
        case .needsSelection: return "hand.tap.fill"
        case .noResults: return "questionmark.circle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .skipped: return "arrow.uturn.right.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle"
        case .ignored: return "minus.circle"
        case .searching, .resolvingPlaylist, .processing: return "circle"
        }
    }

    private var color: Color {
        switch item.status {
        case .needsSelection, .downloading: return .accentColor
        case .noResults: return .orange
        case .completed: return .green
        case .skipped: return .blue
        case .failed: return .red
        default: return .secondary
        }
    }

    private var text: String {
        switch item.status {
        case .waiting:
            return "Wartet auf einen freien Download-Platz …"
        case .searching:
            return item.hasSearched ? "Lade neue Vorschläge …" : "Suche passende Videos …"
        case .needsSelection:
            return "Bitte wähle das passende Video aus."
        case .noResults:
            return item.page > 0 ? "Keine weiteren Treffer." : "Keine Treffer gefunden."
        case .resolvingPlaylist:
            return "Playlist wird gelesen …"
        case .downloading:
            let percent = Formatters.percent(item.progress)
            return item.detail.map { "Lädt … \(percent) · \($0)" } ?? "Lädt … \(percent)"
        case .processing:
            return item.phaseText ?? "Nachbearbeitung …"
        case .completed:
            return item.outputFile.map { "Fertig · \($0.lastPathComponent)" } ?? "Fertig"
        case let .skipped(reason):
            return reason.text
        case let .failed(message):
            return message
        case .cancelled:
            return "Abgebrochen"
        case .ignored:
            return "Ausgelassen"
        }
    }
}

private struct LogView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Protokoll von yt-dlp").font(.headline)
                Spacer()
                Button("Kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
            }
            ScrollView {
                Text(lines.suffix(80).joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(width: 560, height: 320)
    }
}
