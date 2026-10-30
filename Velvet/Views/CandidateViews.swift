import AppKit
import SwiftUI

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

/// Ein Suchergebnis unter dem Suchfeld: Vorschaubild, Titel, Kanal – und „+“ zum Hinzufügen.
struct SuggestionRow: View {
    let candidate: VideoCandidate
    /// „Rock“, wenn der Titel dort schon liegt.
    let existing: String?
    let isAdded: Bool
    let onAdd: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: candidate.thumbnailURL, cornerRadius: 4)
                .frame(width: 72)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let existing {
                    Label("Schon in \(existing)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer(minLength: 12)
            Button {
                NSWorkspace.shared.open(candidate.url)
            } label: {
                Image(systemName: "play.rectangle")
            }
            .buttonStyle(.borderless)
            .help("Im Browser ansehen")
            .opacity(isHovering ? 1 : 0)

            if isAdded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .help("Hinzugefügt")
            } else {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .help("Hinzufügen")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovering ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { if !isAdded { onAdd() } }
    }

    private var details: String {
        [candidate.channel, candidate.durationText, candidate.viewCountText].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Auswahl für einen Titel, bei dem Velvet nicht sicher ist: fünf Vorschläge, Suche anpassen oder eigenen Link.
struct CandidateChooser: View {
    @ObservedObject var item: DownloadItem
    let queue: QueueViewModel
    let onDone: () -> Void

    @State private var query = ""
    @State private var link = ""

    private let columns = Array(repeating: GridItem(.flexible(minimum: 120), spacing: 12, alignment: .top), count: DownloadManager.searchPageSize)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Suchbegriff", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Suchen", action: search)
            }

            Group {
                switch item.status {
                case .searching:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 160)
                case .noResults:
                    Text("Keine Treffer")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                default:
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(item.candidates) { candidate in
                            CandidateCard(candidate: candidate) {
                                queue.choose(candidate, for: item)
                                onDone()
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Weitere Vorschläge") { queue.showMoreSuggestions(for: item) }
                    .disabled(item.status == .searching)
                Spacer()
                TextField("YouTube-Link", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(useLink)
                Button("Laden", action: useLink)
                    .disabled(ListParser.link(from: link) == nil)
            }
        }
        .padding(16)
        .frame(width: 860)
        .onAppear { query = item.query }
    }

    private func search() {
        queue.search(item, for: query)
    }

    private func useLink() {
        guard let url = ListParser.link(from: link), !YouTubeLink.isPlaylist(url), !YouTubeLink.isChannel(url) else { return }
        queue.useLink(url, for: item)
        onDone()
    }
}
