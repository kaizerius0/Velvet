import SwiftUI

/// Zeigt oben rechts, ob yt-dlp, ffmpeg und deno bereit sind.
struct ToolStatusBadge: View {
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var queue: QueueViewModel
    @State private var showDetails = false

    var body: some View {
        if tools.state != .ready || tools.isUpdating {
            badge
        }
    }

    private var badge: some View {
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 6) {
                switch tools.state {
                case .checking:
                    ProgressView().controlSize(.small)
                    Text("Wird vorbereitet …")
                case .ready:
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(tools.isUpdating ? "yt-dlp wird aktualisiert …" : "Bereit")
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Werkzeuge fehlen")
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Status der eingebauten Werkzeuge")
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            ToolDetailsView()
                .environmentObject(tools)
                .environmentObject(queue)
                .padding(16)
                .frame(width: 360)
        }
    }
}

struct ToolDetailsView: View {
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var queue: QueueViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Eingebaute Werkzeuge")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("yt-dlp", tools.versions.ytDlp, note: "lädt die Videos")
                row("ffmpeg", tools.versions.ffmpeg, note: "MP4/MP3-Umwandlung")
                row("deno", tools.versions.deno, note: "löst YouTube-Prüfungen")
            }

            if case let .failed(message) = tools.state {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = tools.updateMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Erneut prüfen") {
                    Task { await tools.prepare(autoUpdate: false) }
                }
                .disabled(tools.state == .checking || queue.hasBusyItems)
                Button("yt-dlp aktualisieren") {
                    Task { await tools.updateYtDlp() }
                }
                .disabled(!tools.isReady || tools.isUpdating || queue.hasBusyItems)
                if tools.isUpdating { ProgressView().controlSize(.small) }
            }
        }
    }

    @ViewBuilder
    private func row(_ name: String, _ version: String?, note: String) -> some View {
        GridRow {
            Image(systemName: version == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(version == nil ? Color.red : Color.green)
            Text(name).fontWeight(.medium)
            Text(version ?? "–").monospacedDigit()
            Text(note).foregroundStyle(.secondary).font(.caption)
        }
    }
}

/// Großer Hinweis im Eingabebildschirm, wenn die Werkzeuge nicht funktionieren.
struct ToolFailureBanner: View {
    @EnvironmentObject private var tools: ToolManager
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Die eingebauten Werkzeuge funktionieren nicht")
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Erneut prüfen") {
                Task { await tools.prepare(autoUpdate: false) }
            }
        }
        .bannerStyle(.orange)
    }
}
