import AppKit
import SwiftUI

/// Die Auswahl aus fünf Vorschlägen: Klick auf eine Karte = dieses Video laden.
struct CandidatePicker: View {
    @ObservedObject var item: DownloadItem
    var onEnterLink: () -> Void

    @EnvironmentObject private var queue: QueueViewModel
    @State private var query = ""

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 120), spacing: 12, alignment: .top),
        count: DownloadManager.searchPageSize
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(heading)
                    .font(.subheadline.weight(.semibold))
                if item.page > 0 {
                    Text("Seite \(item.page + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Suchbegriff anpassen", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(runSearch)
                Button("Suchen", action: runSearch)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            content

            if item.outputFile != nil {
                Label("Die bisher geladene Datei wird nach dem neuen Download in den Papierkorb gelegt.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    queue.showMoreSuggestions(for: item)
                } label: {
                    Label("Andere Vorschläge", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(item.status == .searching)

                Button(action: onEnterLink) {
                    Label("Eigenen Link eingeben …", systemImage: "link")
                }

                Spacer()

                Button("Überspringen") {
                    queue.skip(item)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .onAppear { query = item.query }
        .onChange(of: item.query) { query = $0 }
    }

    private var heading: String {
        switch item.status {
        case .noResults: return "Nichts Passendes gefunden"
        case .searching: return "Neue Vorschläge werden geladen …"
        default: return "Welches Video meinst du?"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.status {
        case .searching:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Einen Moment …").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .noResults:
            Text("Ändere den Suchbegriff, lass dir andere Vorschläge zeigen oder gib einen eigenen Link ein.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(item.candidates) { candidate in
                    CandidateCard(candidate: candidate) {
                        queue.choose(candidate, for: item)
                    }
                }
            }
        }
    }

    private func runSearch() {
        queue.search(item, for: query)
    }
}

/// Eine Vorschlagskarte mit Vorschaubild, Titel, Kanal, Dauer und Aufrufen.
struct CandidateCard: View {
    let candidate: VideoCandidate
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Thumbnail(url: candidate.thumbnailURL)
                    if let duration = candidate.durationText {
                        Text(duration)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.75)))
                            .padding(5)
                    }
                }

                Text(candidate.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(candidate.channel ?? "Unbekannter Kanal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let views = candidate.viewCountText {
                    Text(views)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isHovering ? Color.accentColor : Theme.border.opacity(0.7), lineWidth: isHovering ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button {
                    NSWorkspace.shared.open(candidate.url)
                } label: {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .help("Im Browser ansehen")
                .padding(14)
            }
        }
        .help("Klicken, um „\(candidate.title)“ zu laden")
        .contextMenu {
            Button("Dieses Video laden", action: onSelect)
            Button("Im Browser ansehen") { NSWorkspace.shared.open(candidate.url) }
            Button("Link kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(candidate.url.absoluteString, forType: .string)
            }
        }
    }
}
