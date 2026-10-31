import AppKit
import SwiftUI

/// „Entdecken“: Spotify-Gefühl für den Stick. Oben der Set-Builder, darunter Reihen mit Vorschlägen,
/// ähnliche Künstler, Spotify-Abgleich und Labels. Vorhören per Klick, „+“ lädt auf den Stick.
struct DiscoverScreen: View {
    @EnvironmentObject private var discover: DiscoverViewModel
    @EnvironmentObject private var tools: ToolManager

    var body: some View {
        Group {
            if let model = discover.setBuilder {
                SetBuilderView(model: model)
                    .id(model.id)
            } else {
                DiscoverHome()
            }
        }
        .onAppear { discover.refreshIfNeeded() }
        .onChange(of: tools.isReady) { ready in
            if ready { discover.refreshIfNeeded() }
        }
    }
}

private struct DiscoverHome: View {
    @EnvironmentObject private var discover: DiscoverViewModel
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var library: LibraryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if case let .failed(message) = tools.state {
                    ToolFailureBanner(message: message)
                }
                header
                SetBuilderHero()

                if discover.shelves.isEmpty {
                    if discover.isRefreshing {
                        loadingShelves
                    } else {
                        emptyState
                    }
                }
                ForEach(discover.shelves) { shelf in
                    ShelfView(shelf: shelf)
                }
                if !discover.relatedArtists.isEmpty {
                    RelatedArtistsRow(artists: discover.relatedArtists)
                }
                SpotifySection()
                LabelsSection()
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Entdecken")
                    .font(.title.weight(.bold))
                Text("Wie Spotify – nur dass alles, was dir gefällt, auf deinem Stick landet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let notice = library.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .lineLimit(1)
            }
            if discover.isRefreshing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(discover.status ?? "Wird aktualisiert …")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            TargetFolderMenu(prefix: "Ziel: ")
            Button {
                discover.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(discover.isRefreshing || !tools.isReady)
            .help(discover.lastRefresh.map { "Neue Vorschläge holen (zuletzt \(Formatters.dateTime($0)))" } ?? "Neue Vorschläge holen")
        }
    }

    private var loadingShelves: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Velvet hört sich für dich um …")
                .font(.title3.weight(.bold))
            HStack(spacing: 12) {
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(width: SuggestionCard.width, height: 210)
                }
            }
        }
        .redacted(reason: .placeholder)
    }

    private var emptyState: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(discover.hasHistory ? "Noch keine Vorschläge" : "Velvet lernt deinen Geschmack")
                        .font(.headline)
                    Text(discover.hasHistory
                         ? "Klick oben rechts auf ↻, dann sucht Velvet passende Titel zu dem, was auf deinen Sticks liegt."
                         : "Lade ein paar Titel über „Hinzufügen“ oder bau oben ein Set aus einem Lieblingssong. Danach schlägt Velvet hier ähnliche Titel vor – je mehr du lädst, desto besser.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Set-Builder oben

private struct SetBuilderHero: View {
    @EnvironmentObject private var discover: DiscoverViewModel
    @EnvironmentObject private var navigation: AppNavigation
    @EnvironmentObject private var tools: ToolManager
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "dial.medium.fill")
                    .font(.system(size: 22, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set bauen")
                        .font(.title2.weight(.bold))
                    Text("Ein Song rein – Velvet stellt passende Titel zusammen, mit Tempo und Tonart, und lädt sie auf den Stick.")
                        .font(.callout)
                        .opacity(0.85)
                }
            }
            HStack(spacing: 10) {
                TextField("Song, Künstler oder YouTube-Link – z. B. „Fred again.. Marea“", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .textBackgroundColor)))
                    .foregroundStyle(Color(nsColor: .textColor))
                    .focused($focused)
                    .onSubmit(start)
                Button(action: start) {
                    Text("Set bauen")
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.25))
                .controlSize(.large)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || !tools.isReady)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.velvetGradient))
        .onChange(of: navigation.focusSetBuilder) { _ in focused = true }
    }

    private func start() {
        discover.startSet(query: query)
        query = ""
    }
}

// MARK: - Reihen

struct ShelfView: View {
    let shelf: DiscoverShelf
    @EnvironmentObject private var discover: DiscoverViewModel
    @EnvironmentObject private var library: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shelf.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                    if let subtitle = shelf.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button(allTitle) { discover.addAll(shelf) }
                    .controlSize(.small)
            }
            CardRow(items: shelf.items) { suggestion in
                SuggestionCard(suggestion: suggestion, folder: shelf.folder)
            }
        }
    }

    private var allTitle: String {
        if let folder = shelf.folder { return "Alle \(shelf.items.count) in „\(folder.lastPathComponent)“" }
        return "Alle \(shelf.items.count) laden"
    }
}

/// Waagerechte Reihe zum Durchwischen – mit Pfeilen für die Maus.
struct CardRow<Content: View>: View {
    let items: [Suggestion]
    @ViewBuilder var content: (Suggestion) -> Content
    @State private var leading = 0

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            content(item)
                                .frame(width: SuggestionCard.width)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
                if items.count > 4 {
                    HStack {
                        arrow("chevron.left") { scroll(proxy, by: -4) }
                        Spacer()
                        arrow("chevron.right") { scroll(proxy, by: 4) }
                    }
                    .padding(.horizontal, -10)
                    .padding(.top, SuggestionCard.width * 9 / 32 - 14)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Theme.border))
        }
        .buttonStyle(.plain)
    }

    private func scroll(_ proxy: ScrollViewProxy, by step: Int) {
        guard !items.isEmpty else { return }
        leading = min(max(leading + step, 0), items.count - 1)
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(items[leading].id, anchor: .leading)
        }
    }
}

/// Eine Vorschlagskarte: Vorschaubild zum Vorhören, Version, Tempo/Tonart und „+“ für den Stick.
struct SuggestionCard: View {
    static let width: CGFloat = 186

    let suggestion: Suggestion
    /// Ordner der Reihe – sonst das gewählte Ziel.
    var folder: URL?

    @EnvironmentObject private var discover: DiscoverViewModel
    @EnvironmentObject private var player: PreviewPlayer
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var analysis: AnalysisCenter
    @EnvironmentObject private var taste: TasteStore
    @State private var isHovering = false
    @State private var hoverTask: Task<Void, Never>?

    private var candidate: VideoCandidate { suggestion.candidate }
    private var version: TrackVersion { suggestion.version }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork
            VersionBadges(version: version, limit: 2)
                .frame(height: 15, alignment: .leading)
            Text(version.song)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                status
                Spacer(minLength: 4)
                addButton
            }
            .font(.caption2)
            .frame(height: 20)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 11).fill(isHovering ? Color.accentColor.opacity(0.08) : Theme.cardBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(player.isCurrent(candidate.id) ? Color.accentColor : Theme.border.opacity(0.6),
                              lineWidth: player.isCurrent(candidate.id) ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onHover { hovering in
            isHovering = hovering
            hoverTask?.cancel()
            // Kurz drüber verweilen: Vorschau schon laden, damit sie beim Klick sofort spielt.
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    player.prefetch(candidate)
                }
            }
        }
        .help(candidate.title)
        .contextMenu { SuggestionMenu(candidate: candidate, folder: folder) }
    }

    /// Interpret – und der Remixer, denn „Extended“ & Co. zeigen schon die Schildchen.
    private var subtitle: String {
        let remix = version.badges.contains(.remix) ? version.mix : nil
        return [version.artist ?? candidate.channel, remix].compactMap { $0 }.joined(separator: " · ")
    }

    private var artwork: some View {
        Button {
            player.play(candidate)
        } label: {
            ZStack {
                Thumbnail(url: candidate.thumbnailURL, cornerRadius: 7)
                if isHovering || player.isCurrent(candidate.id) {
                    RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.35))
                    playIcon
                }
            }
        }
        .buttonStyle(.plain)
        .help("Vorhören (Leertaste: Pause)")
        .overlay(alignment: .bottomTrailing) {
            if let duration = candidate.durationText {
                Text(duration)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7)))
                    .padding(5)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Außerhalb des Vorhör-Knopfs, damit der Klick hier ankommt.
            if isHovering {
                Button {
                    discover.hide(candidate)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .help("Nicht interessiert")
                .padding(5)
            }
        }
    }

    @ViewBuilder
    private var playIcon: some View {
        if player.isLoading(candidate.id) {
            ProgressView().controlSize(.small).tint(.white)
        } else {
            Image(systemName: player.isCurrent(candidate.id) && player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(radius: 3)
        }
    }

    @ViewBuilder
    private var status: some View {
        if let queued = queue.item(forVideo: candidate.id) {
            QueueStatusLabel(item: queued)
                .lineLimit(1)
        } else if discover.addedIDs.contains(candidate.id) {
            Label("Geladen", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if let known = analysis.analysis(forVideo: candidate.id), known.shortText != nil {
            AnalysisLabel(analysis: known)
        } else if suggestion.hits > 1 {
            Label("\(suggestion.hits)× empfohlen", systemImage: "sparkles")
                .foregroundStyle(.secondary)
                .help("Taucht in \(suggestion.hits) Mixen auf – passt besonders gut")
        } else if let channel = candidate.channelID, taste.isFollowing(channel) {
            Label("Label", systemImage: "star.fill")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var addButton: some View {
        if queue.item(forVideo: candidate.id) == nil, !discover.addedIDs.contains(candidate.id) {
            Button {
                discover.add(candidate, to: folder)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(folder.map { "Auf den Stick: „\(library.locationText(forFolder: $0))“" }
                  ?? discover.target.map { "Auf den Stick: „\(library.locationText(forFolder: $0))“" }
                  ?? "Auf den Stick – Ziel wählen")
        }
    }
}

/// Rechtsklick auf einen Vorschlag.
struct SuggestionMenu: View {
    let candidate: VideoCandidate
    var folder: URL?

    @EnvironmentObject private var discover: DiscoverViewModel
    @EnvironmentObject private var player: PreviewPlayer
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var taste: TasteStore

    var body: some View {
        Button("Vorhören") { player.play(candidate) }
        Button("Auf den Stick") { discover.add(candidate, to: folder) }
        Menu("Laden nach") {
            ForEach(library.sources) { source in
                Section(source.name) {
                    ForEach(library.folders(in: source.id)) { target in
                        Button(target.name) { discover.add(candidate, to: target.url) }
                    }
                }
            }
        }
        Divider()
        Button("Set daraus bauen") { discover.startSet(from: candidate) }
        if let channelID = candidate.channelID, let channel = candidate.channel {
            if taste.isFollowing(channelID) {
                Button("„\(channel)“ nicht mehr folgen") { taste.unfollow(channelID) }
            } else {
                Button("„\(channel)“ folgen") { taste.follow(FollowedChannel(id: channelID, name: channel)) }
            }
        }
        Divider()
        Button("Nicht interessiert") { discover.hide(candidate) }
        Button("Auf YouTube ansehen") { NSWorkspace.shared.open(candidate.url) }
        Button("Link kopieren") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(candidate.url.absoluteString, forType: .string)
        }
    }
}

// MARK: - Ähnliche Künstler

private struct RelatedArtistsRow: View {
    let artists: [String]
    @EnvironmentObject private var discover: DiscoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ähnliche Künstler")
                    .font(.title3.weight(.bold))
                Text("Noch nicht auf deinem Stick – Klick baut ein Set aus ihrem bekanntesten Titel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 8) {
                ForEach(artists, id: \.self) { artist in
                    Button {
                        discover.startSet(query: artist)
                    } label: {
                        Label(artist, systemImage: "person.wave.2")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Elemente nebeneinander, mit Umbruch.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Spotify

private struct SpotifySection: View {
    @EnvironmentObject private var discover: DiscoverViewModel
    @EnvironmentObject private var taste: TasteStore
    @State private var showLinkSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spotify-Playlists → Stick")
                        .font(.title3.weight(.bold))
                    Text("Verknüpfe eine Playlist mit einem Ordner: Kommt in Spotify etwas dazu, lädt Velvet es auf Klick nach.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showLinkSheet = true
                } label: {
                    Label("Playlist verknüpfen …", systemImage: "link.badge.plus")
                }
                .controlSize(.small)
            }
            if taste.spotifyLinks.isEmpty {
                Text("Noch keine Playlist verknüpft. Tipp: Eine Spotify-Playlist kannst du auch einfach unter „Hinzufügen“ einfügen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(taste.spotifyLinks) { link in
                        SpotifyLinkRow(link: link)
                    }
                }
            }
        }
        .sheet(isPresented: $showLinkSheet) {
            SpotifyLinkSheet()
        }
    }
}

private struct SpotifyLinkRow: View {
    let link: SpotifyLink
    @EnvironmentObject private var discover: DiscoverViewModel

    var body: some View {
        let state = discover.spotifyStates[discover.key(for: link)]
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("→ \(link.folderName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            statusText(state)
                .font(.callout)
            if let state, !state.missing.isEmpty {
                Button("\(state.missing.count) laden") { discover.loadMissing(link) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button {
                discover.check(link)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(state?.isChecking == true)
            .help("Jetzt mit Spotify abgleichen")
            Menu {
                Button("Auf Spotify öffnen") {
                    if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
                }
                Divider()
                Button("Verknüpfung entfernen", role: .destructive) { discover.unlink(link) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border.opacity(0.6)))
    }

    @ViewBuilder
    private func statusText(_ state: SpotifyLinkState?) -> some View {
        if let state {
            if state.isChecking {
                ProgressView().controlSize(.small)
            } else if state.isOffline {
                Label("Stick nicht verbunden", systemImage: "externaldrive.badge.xmark")
                    .foregroundStyle(.secondary)
            } else if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if state.missing.isEmpty {
                Label("Alles da (\(state.total))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("\(state.missing.count) neue von \(state.total)\(state.mayBeTruncated ? "+" : "")")
                    .foregroundStyle(Color.accentColor)
                    .help(state.mayBeTruncated ? "Spotify zeigt Velvet höchstens 100 Titel einer Playlist." : "")
            }
        }
    }
}

// MARK: - Labels

private struct LabelsSection: View {
    @EnvironmentObject private var discover: DiscoverViewModel
    @EnvironmentObject private var taste: TasteStore
    @State private var showChannelSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Labels & Kanäle")
                        .font(.title3.weight(.bold))
                    Text("Folge Labels auf YouTube – ihre neuen Titel erscheinen oben unter „Neu von deinen Labels“.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showChannelSheet = true
                } label: {
                    Label("Kanal hinzufügen …", systemImage: "plus")
                }
                .controlSize(.small)
            }
            FlowLayout(spacing: 8) {
                ForEach(channels) { channel in
                    let following = taste.isFollowing(channel.id)
                    Button {
                        if following { taste.unfollow(channel.id) } else { taste.follow(channel) }
                    } label: {
                        Label(channel.name, systemImage: following ? "checkmark" : "plus")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(following ? Color.white : Color.primary)
                            .background(Capsule().fill(following ? Color.accentColor : Color.secondary.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help(following ? "Nicht mehr folgen" : "Folgen")
                }
            }
        }
        .sheet(isPresented: $showChannelSheet) {
            ChannelSheet()
        }
    }

    /// Gefolgte Kanäle zuerst, dann die Vorschläge.
    private var channels: [FollowedChannel] {
        taste.followedChannels + TasteStore.suggestedLabels.filter { !taste.isFollowing($0.id) }
    }
}
