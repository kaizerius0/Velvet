import SwiftUI

/// Einstellungsfenster (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            DownloadSettingsTab()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            DiscoverSettingsTab()
                .tabItem { Label("Entdecken", systemImage: "sparkles") }
            ToolSettingsTab()
                .tabItem { Label("Werkzeuge", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 580, height: 560)
    }
}

private struct DownloadSettingsTab: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Video (MP4)", selection: $settings.videoQuality) {
                    ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
                }
                Picker("Audio", selection: $settings.audioQuality) {
                    ForEach(AudioQuality.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Qualität")
            } footer: {
                Text("YouTube liefert Ton mit höchstens etwa 130 kbit/s. „MP3 320“ macht daraus nicht mehr Qualität, nur größere Dateien. „M4A – Original“ übernimmt die Tonspur ohne zweite Umwandlung; die meisten aktuellen DJ-Player spielen M4A.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Bevorzugte Version", selection: $settings.preferredVersion) {
                    ForEach(PreferredVersion.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Dateien sauber benennen („Interpret - Titel (Extended Mix)“)", isOn: $settings.cleanFileNames)
                Toggle("Tempo & Tonart ermitteln und in die MP3 schreiben", isOn: $settings.analyzeDownloads)
            } header: {
                Text("Für DJs")
            } footer: {
                Text(settings.preferredVersion.explanation + " Tempo (BPM) und Tonart (Camelot) stehen danach in den Tags – Mixer, rekordbox und Velvet zeigen sie an.")
                    .foregroundStyle(.secondary)
            }

            Section("Laden") {
                Stepper(value: $settings.maxParallelDownloads, in: 1...4) {
                    Text("Gleichzeitige Downloads: \(settings.maxParallelDownloads)")
                }
                Toggle("Bei mehreren Titeln den ersten Treffer nehmen", isOn: $settings.autoPickFirstResult)
                Toggle("Archivdatei im Ordner führen (archive.txt)", isOn: $settings.useArchive)
            }

            Section {
                Picker("Cookies aus Browser", selection: $settings.cookieBrowser) {
                    ForEach(CookieBrowser.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("YouTube-Zugang")
            } footer: {
                Text("Nur für altersbeschränkte Videos oder wenn YouTube eine Bot-Prüfung verlangt. Safari braucht dafür Festplattenvollzugriff.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DiscoverSettingsTab: View {
    @EnvironmentObject private var taste: TasteStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Ausgeblendete Vorschläge", value: "\(taste.hiddenVideoIDs.count)")
                Button("Ausgeblendete wieder zeigen") { taste.unhideAll() }
                    .disabled(taste.hiddenVideoIDs.isEmpty)
            } header: {
                Text("Geschmack")
            } footer: {
                Text("Velvet lernt aus dem, was du lädst, länger vorhörst, ausblendest oder schnell wieder löschst. Alles bleibt auf diesem Mac.")
                    .foregroundStyle(.secondary)
            }
            Section("Labels & Kanäle") {
                if taste.followedChannels.isEmpty {
                    Text("Du folgst noch keinem Kanal – das geht unter „Entdecken“.")
                        .foregroundStyle(.secondary)
                }
                ForEach(taste.followedChannels) { channel in
                    HStack {
                        Text(channel.name)
                        Spacer()
                        Button("Nicht mehr folgen") { taste.unfollow(channel.id) }
                            .controlSize(.small)
                    }
                }
            }
            Section("Spotify-Playlists") {
                if taste.spotifyLinks.isEmpty {
                    Text("Keine Playlist verknüpft.")
                        .foregroundStyle(.secondary)
                }
                ForEach(taste.spotifyLinks) { link in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(link.name)
                            Text("→ \(link.folderName)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Entfernen") { taste.removeSpotifyLink(link) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ToolSettingsTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var queue: QueueViewModel

    var body: some View {
        Form {
            Section("Eingebaute Werkzeuge") {
                LabeledContent("yt-dlp", value: tools.versions.ytDlp ?? "–")
                LabeledContent("ffmpeg", value: tools.versions.ffmpeg ?? "–")
                LabeledContent("deno", value: tools.versions.deno ?? "–")
                if case let .failed(message) = tools.state {
                    Text(message).foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Täglich beim Start nach yt-dlp-Updates suchen", isOn: $settings.autoUpdateYtDlp)
                HStack {
                    Button("yt-dlp jetzt aktualisieren") {
                        Task { await tools.updateYtDlp() }
                    }
                    .disabled(!tools.isReady || tools.isUpdating || queue.hasBusyItems)
                    if tools.isUpdating { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Erneut prüfen") {
                        Task { await tools.prepare(autoUpdate: false) }
                    }
                    .disabled(tools.state == .checking || queue.hasBusyItems)
                    Button("Ordner zeigen") { tools.revealToolsFolder() }
                }
                if let message = tools.updateMessage {
                    Text(message).foregroundStyle(.secondary)
                }
            } header: {
                Text("Aktualisierung")
            } footer: {
                Text("YouTube ändert sich häufig. Wenn Downloads plötzlich scheitern, hilft fast immer ein aktuelles yt-dlp.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
