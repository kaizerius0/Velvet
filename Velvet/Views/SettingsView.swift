import SwiftUI

/// Einstellungsfenster (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            DownloadSettingsTab()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            ToolSettingsTab()
                .tabItem { Label("Werkzeuge", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct DownloadSettingsTab: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Ablauf") {
                Stepper(value: $settings.maxParallelDownloads, in: 1...4) {
                    Text("Gleichzeitige Downloads: \(settings.maxParallelDownloads)")
                }
                Toggle("Bestes Suchergebnis automatisch wählen", isOn: $settings.autoPickFirstResult)
                Toggle("Bereits Geladenes überspringen (Archivdatei im Zielordner)", isOn: $settings.useArchive)
            }

            Section {
                Picker("Cookies aus Browser", selection: $settings.cookieBrowser) {
                    ForEach(CookieBrowser.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("YouTube-Zugang")
            } footer: {
                Text("Nur nötig für altersbeschränkte Videos oder wenn YouTube eine Bot-Prüfung verlangt. Du musst im gewählten Browser bei YouTube angemeldet sein. Safari benötigt dafür „Festplattenvollzugriff“ für Velvet (Systemeinstellungen → Datenschutz & Sicherheit).")
                    .foregroundStyle(.secondary)
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
