import SwiftUI

/// Spotify-Playlist mit einem Ordner verknüpfen.
struct SpotifyLinkSheet: View {
    @EnvironmentObject private var discover: DiscoverViewModel
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var link = ""
    @State private var folder: URL?
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spotify-Playlist verknüpfen")
                        .font(.title2.weight(.bold))
                    Text("Velvet vergleicht die Playlist mit dem Ordner und lädt fehlende Titel auf Klick.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Link zur Playlist")
                    .font(.headline)
                TextField("https://open.spotify.com/playlist/…", text: $link)
                    .textFieldStyle(.roundedBorder)
                Text("In Spotify: ••• → Teilen → Link zur Playlist kopieren. Die Playlist muss öffentlich sein.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Ordner")
                    .font(.headline)
                Menu {
                    ForEach(library.sources) { source in
                        Section(source.name) {
                            ForEach(library.folders(in: source.id)) { item in
                                Button(item.name) { folder = item.url }
                            }
                        }
                    }
                    Divider()
                    Button("Anderer Ordner …") {
                        folder = library.chooseFolder(title: "Ordner für die Playlist", startingAt: folder)
                    }
                } label: {
                    Label(folder.map { library.locationText(forFolder: $0) } ?? "Ordner wählen …",
                          systemImage: folder.map { library.isOnStick($0) ? "externaldrive" : "folder" } ?? "folder.badge.questionmark")
                }
                .fixedSize()
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    connect()
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Verknüpfen")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || folder == nil || spotifyURL == nil)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { folder = folder ?? discover.target }
    }

    private var spotifyURL: URL? {
        ListParser.link(from: link).flatMap { SpotifyEmbed.isSupported($0) ? $0 : nil }
    }

    private func connect() {
        guard let url = spotifyURL, let folder else { return }
        isWorking = true
        error = nil
        Task {
            do {
                try await discover.linkSpotify(url: url, to: folder)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// Einem YouTube-Kanal folgen – per Link.
struct ChannelSheet: View {
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var taste: TasteStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var link = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kanal folgen")
                    .font(.title2.weight(.bold))
                Text("Ein Label oder Künstler auf YouTube – neue Videos erscheinen in „Entdecken“.")
                    .foregroundStyle(.secondary)
            }
            TextField("https://www.youtube.com/@defectedmusic", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit(follow)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    follow()
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Folgen")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || channelURL == nil || !tools.isReady)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    /// „@name“ allein geht auch.
    private var channelURL: URL? {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("@") { return URL(string: "https://www.youtube.com/\(trimmed)") }
        return ListParser.link(from: trimmed).flatMap { YouTubeLink.isYouTube($0) ? $0 : nil }
    }

    private func follow() {
        guard let url = channelURL, let manager = tools.downloadManager else { return }
        isWorking = true
        error = nil
        let cookies = settings.cookieBrowser
        Task {
            do {
                let info = try await manager.channelInfo(url, cookies: cookies)
                taste.follow(FollowedChannel(id: info.id, name: info.name))
                dismiss()
            } catch {
                self.error = (error as? DownloadFailure)?.message ?? error.localizedDescription
            }
            isWorking = false
        }
    }
}
