import SwiftUI

/// Die Wiedergabe-Leiste unten im Fenster – solange etwas vorgehört wird.
struct PlayerBar: View {
    @EnvironmentObject private var player: PreviewPlayer
    @EnvironmentObject private var discover: DiscoverViewModel
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var analysis: AnalysisCenter

    @State private var scrubPosition: Double?

    var body: some View {
        if let item = player.item {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 14) {
                    artwork(item)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if let subtitle = item.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .lineLimit(1)
                            }
                            if let candidate = item.candidate {
                                AnalysisLabel(analysis: analysis.analysis(forVideo: candidate.id))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 160, maxWidth: 320, alignment: .leading)

                    controls
                    timeline
                    trailing(item)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func artwork(_ item: PreviewPlayer.Item) -> some View {
        Group {
            if let artwork = item.artwork {
                Thumbnail(url: artwork, cornerRadius: 5)
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Theme.velvetGradient)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(Image(systemName: "music.note").foregroundStyle(.white))
            }
        }
        .frame(width: 68)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { player.skip(by: -15) } label: {
                Image(systemName: "gobackward.15")
            }
            .help("15 Sekunden zurück (⌥⌘←)")
            Button { player.togglePlayPause() } label: {
                ZStack {
                    if case .loading = player.phase {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 30, height: 30)
            }
            .help("Abspielen/Pause (Leertaste)")
            Button { player.skip(by: 15) } label: {
                Image(systemName: "goforward.15")
            }
            .help("15 Sekunden vor (⌥⌘→)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 15, weight: .medium))
    }

    @ViewBuilder
    private var timeline: some View {
        switch player.phase {
        case let .loading(fraction):
            HStack(spacing: 8) {
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 220)
                    Text("Vorschau lädt … \(Formatters.percent(fraction))")
                } else {
                    Text("Vorschau lädt …")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            HStack(spacing: 8) {
                Text(Formatters.duration(scrubPosition ?? player.position) ?? "0:00")
                    .frame(width: 42, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { scrubPosition ?? player.position },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...max(player.duration ?? 1, 1)
                ) { editing in
                    if !editing, let target = scrubPosition {
                        player.seek(to: target)
                        scrubPosition = nil
                    }
                }
                .controlSize(.small)
                Text(Formatters.duration(player.duration) ?? "–")
                    .frame(width: 42, alignment: .leading)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func trailing(_ item: PreviewPlayer.Item) -> some View {
        HStack(spacing: 8) {
            if let candidate = item.candidate {
                if let queued = queue.item(forVideo: candidate.id) {
                    QueueStatusLabel(item: queued)
                        .font(.caption)
                } else {
                    Button {
                        discover.add(candidate)
                    } label: {
                        Label("Auf den Stick", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help(discover.target.map { "Laden nach „\($0.lastPathComponent)“" } ?? "Ziel wählen und laden")
                }
            }
            Button { player.stop() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Wiedergabe beenden")
        }
    }
}
