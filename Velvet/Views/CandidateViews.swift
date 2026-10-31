import AppKit
import SwiftUI

/// Eine Vorschlagskarte mit Vorschaubild, Titel, Kanal, Dauer und Aufrufen.
struct CandidateCard: View {
    let candidate: VideoCandidate
    /// „AUTO-STICK › Rock“, wenn der Titel dort schon liegt.
    var existing: String?
    /// Vorhören in Velvet – ohne: im Browser ansehen.
    var onPreview: (() -> Void)?
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

                VersionBadges(version: candidate.version, limit: 2)

                Text(candidate.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)

                Text(candidate.channel ?? "Unbekannter Kanal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let existing {
                    Label("Schon in \(existing)", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                } else if let views = candidate.viewCountText {
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
                    if let onPreview { onPreview() } else { NSWorkspace.shared.open(candidate.url) }
                } label: {
                    Image(systemName: onPreview == nil ? "play.rectangle.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .help(onPreview == nil ? "Im Browser ansehen" : "Vorhören")
                .padding(14)
            }
        }
        .help(candidate.title)
        .contextMenu {
            Button("Dieses Video laden", action: onSelect)
            if let onPreview { Button("Vorhören", action: onPreview) }
            Button("Im Browser ansehen") { NSWorkspace.shared.open(candidate.url) }
            Button("Link kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(candidate.url.absoluteString, forType: .string)
            }
        }
    }
}

/// Vorschläge zum seitlichen Durchwischen: am Ende werden automatisch weitere geladen,
/// die bisherigen bleiben – man kann jederzeit zurückwischen.
struct CandidateCarousel: View {
    let candidates: [VideoCandidate]
    let isLoadingMore: Bool
    let canLoadMore: Bool
    var existing: (VideoCandidate) -> String? = { _ in nil }
    var onPreview: ((VideoCandidate) -> Void)?
    let onLoadMore: () -> Void
    let onSelect: (VideoCandidate) -> Void

    static let cardWidth: CGFloat = 196

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                            CandidateCard(candidate: candidate, existing: existing(candidate),
                                          onPreview: onPreview.map { preview in { preview(candidate) } }) {
                                onSelect(candidate)
                            }
                            .frame(width: Self.cardWidth)
                            .id(candidate.id)
                            .onAppear {
                                // Kurz vor dem Ende schon die nächsten fünf holen.
                                if index >= candidates.count - 2 { onLoadMore() }
                            }
                        }
                        trailing
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 12)
                }

                // Pfeile mittig auf Höhe der Vorschaubilder – für die Maus; mit dem Trackpad einfach wischen.
                HStack {
                    pageButton("chevron.left") { scroll(proxy, by: -4) }
                    Spacer()
                    pageButton("chevron.right") { scroll(proxy, by: 4) }
                }
                .padding(.horizontal, -8)
                .padding(.top, (Self.cardWidth - 16) * 9 / 32 - 6)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    @State private var leadingIndex = 0

    @ViewBuilder
    private var trailing: some View {
        if isLoadingMore {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Weitere Vorschläge …")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 140, height: 160)
        } else if canLoadMore {
            Button(action: onLoadMore) {
                Label("Mehr", systemImage: "arrow.right.circle")
            }
            .buttonStyle(.borderless)
            .frame(width: 100, height: 160)
        } else if !candidates.isEmpty {
            Text("Keine weiteren Treffer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 140, height: 160)
        }
    }

    private func pageButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Theme.border))
        }
        .buttonStyle(.plain)
    }

    /// Für die Maus: vier Karten weiter bzw. zurück.
    private func scroll(_ proxy: ScrollViewProxy, by step: Int) {
        guard !candidates.isEmpty else { return }
        let target = min(max(leadingIndex + step, 0), candidates.count - 1)
        if step > 0, target >= candidates.count - 2 { onLoadMore() }
        leadingIndex = target
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(candidates[target].id, anchor: .leading)
        }
    }
}
