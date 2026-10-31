import AppKit
import SwiftUI

/// Schildchen wie EXTENDED, RADIO EDIT, LIVE – höchstens drei, DJ-Versionen zuerst.
struct VersionBadges: View {
    let version: TrackVersion
    var limit = 3

    var body: some View {
        let badges = Self.ordered(version.badges).prefix(limit)
        // Auch ohne Schildchen da, damit alle Karten gleich hoch sind.
        HStack(spacing: 4) {
            ForEach(Array(badges), id: \.self) { badge in
                    Text(badge.title)
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.3)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .foregroundStyle(color(for: badge))
                        .background(Capsule().fill(color(for: badge).opacity(0.14)))
            }
        }
    }

    static func ordered(_ badges: Set<TrackVersion.Badge>) -> [TrackVersion.Badge] {
        TrackVersion.Badge.allCases.filter { badges.contains($0) && $0 != .visualizer }
    }

    private func color(for badge: TrackVersion.Badge) -> Color {
        if badge.isDJVersion { return .accentColor }
        if badge.isWarning { return .orange }
        if badge == .remix { return .blue }
        return .secondary
    }
}

/// „124 BPM · 8A“ – mit Farbe je Tonart (wie auf dem Camelot-Rad).
struct AnalysisLabel: View {
    let analysis: TrackAnalysis?
    var isLoading = false

    var body: some View {
        HStack(spacing: 6) {
            if let bpm = analysis?.bpmText {
                Text("\(bpm) BPM")
                    .monospacedDigit()
            }
            if let key = analysis?.key {
                KeyBadge(key: key)
            }
            if analysis == nil, isLoading {
                ProgressView().controlSize(.mini)
                Text("Tempo …")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

struct KeyBadge: View {
    let key: MusicalKey

    var body: some View {
        Text(key.camelot)
            .font(.caption2.weight(.bold).monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(.white)
            .background(Capsule().fill(Self.color(for: key)))
            .help(key.name)
    }

    /// Farben des Camelot-Rads: benachbarte Tonarten haben ähnliche Farben.
    static func color(for key: MusicalKey) -> Color {
        let hue = Double((key.camelotNumber - 1) % 12) / 12
        return Color(hue: hue, saturation: key.isMinor ? 0.55 : 0.75, brightness: key.isMinor ? 0.72 : 0.62)
    }
}

/// Zielordner wählen – Ordner aus der Seitenleiste oder „Anderer Ordner …“.
struct TargetFolderMenu: View {
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var settings: AppSettings
    var prefix = ""

    var body: some View {
        Menu {
            ForEach(library.sources) { source in
                let folders = library.folders(in: source.id)
                if !folders.isEmpty {
                    Section(source.name) {
                        ForEach(folders) { folder in
                            Button {
                                settings.addTarget = folder.url
                            } label: {
                                Label(folder.name, systemImage: folder.isVolumeRoot ? "externaldrive" : "folder")
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Anderer Ordner …") { choose() }
        } label: {
            Label(prefix + text, systemImage: symbol)
        }
        .fixedSize()
        .help("Hierhin kommen die neuen Titel")
    }

    private var text: String {
        settings.addTarget.map { library.locationText(forFolder: $0) } ?? "Ordner wählen …"
    }

    private var symbol: String {
        guard let target = settings.addTarget else { return "folder.badge.questionmark" }
        return library.isOnStick(target) ? "externaldrive" : "folder"
    }

    @discardableResult
    func choose() -> URL? {
        guard let url = library.chooseFolder(title: "Wohin sollen die Titel?", startingAt: settings.addTarget) else { return nil }
        settings.addTarget = url
        return url
    }
}

/// Zeigt, was mit einem Video in der Warteschlange passiert: lädt, fertig, Fehler.
struct QueueStatusLabel: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        switch item.status {
        case .completed:
            Label("Auf dem Stick", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloading, .processing:
            Label(Formatters.percent(item.progress), systemImage: "arrow.down.circle")
                .foregroundStyle(Color.accentColor)
                .monospacedDigit()
        case .waiting, .searching, .resolvingPlaylist:
            Label("Wartet …", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .failed:
            Label("Fehler", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .skipped:
            Label("Schon da", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .needsSelection, .noResults, .cancelled, .ignored:
            EmptyView()
        }
    }
}
