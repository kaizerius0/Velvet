import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var navigation: AppNavigation

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            switch navigation.section ?? .downloads {
            case .downloads:
                Group {
                    if queue.hasRun {
                        QueueScreen()
                    } else {
                        InputScreen()
                    }
                }
                .navigationTitle("Downloads")
            case .library:
                LibraryScreen()
                    .navigationTitle("Bibliothek")
            case .history:
                HistoryScreen()
                    .navigationTitle("Verlauf")
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
    }
}

/// Seitenleiste: Bereiche, gewähltes Laufwerk und Werkzeug-Status.
struct Sidebar: View {
    @EnvironmentObject private var navigation: AppNavigation
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var library: LibraryViewModel

    var body: some View {
        List(selection: $navigation.section) {
            Section {
                ForEach(AppNavigation.Section.allCases, id: \.self) { section in
                    Label(section.title, systemImage: section.symbol)
                        .badge(badge(for: section))
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            SidebarHeader()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                DrivePanel()
                Divider()
                ToolStatusBadge()
            }
            .padding(12)
        }
    }

    private func badge(for section: AppNavigation.Section) -> Int {
        switch section {
        case .downloads: return queue.summary.needsAttention
        case .library: return library.tracks.count
        case .history: return 0
        }
    }
}

private struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            LogoMark(size: 30)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("Velvet")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    #if DEBUG
                    Text("DEV")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .help("Entwicklungsversion aus Xcode – die normale App liegt unter /Programme.")
                    #endif
                }
                Text("Deine Musik für unterwegs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

/// Zeigt den gewählten Stick mit freiem Speicher; wechseln und auswerfen.
struct DrivePanel: View {
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var queue: QueueViewModel
    @EnvironmentObject private var navigation: AppNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LAUFWERK")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Menu {
                if library.volumes.isEmpty {
                    Text("Kein Stick eingesteckt")
                }
                ForEach(library.volumes) { volume in
                    Button {
                        library.use(volume: volume)
                        navigation.section = .library
                    } label: {
                        Label(volume.name, systemImage: "externaldrive")
                    }
                }
                Divider()
                Button("Ordner auf diesem Mac …") {
                    library.chooseFolder()
                    navigation.section = .library
                }
            } label: {
                Label(title, systemImage: symbol)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .help("Laufwerk oder Ordner wählen, den Velvet verwaltet")

            if case .offline = library.status {
                Text("Nicht verbunden – Stick einstecken")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let volume = library.volume, let used = volume.usedFraction, let text = volume.freeSpaceText {
                ProgressView(value: used)
                    .progressViewStyle(.linear)
                    .tint(used > 0.9 ? .orange : .accentColor)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if library.status == .ready, library.isExternal {
                Button {
                    Task { await library.eject() }
                } label: {
                    Label("Auswerfen", systemImage: "eject")
                }
                .buttonStyle(.borderless)
                .disabled(isWritingToLibrary)
                .help(isWritingToLibrary ? "Es laufen noch Downloads auf diesen Stick." : "Stick sicher auswerfen")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isWritingToLibrary: Bool {
        guard queue.hasBusyItems, let destination = queue.destination else { return false }
        return library.contains(destination)
    }

    private var title: String {
        library.location?.displayName ?? "Laufwerk wählen …"
    }

    private var symbol: String {
        switch library.status {
        case .none: return "externaldrive.badge.plus"
        case .offline: return "externaldrive.badge.xmark"
        case .ready: return library.isExternal ? "externaldrive.fill" : "folder.fill"
        }
    }
}
