import SwiftUI

@main
struct VelvetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var tools: ToolManager
    @StateObject private var input: InputViewModel
    @StateObject private var queue: QueueViewModel
    @StateObject private var history: HistoryStore
    @StateObject private var library: LibraryViewModel
    @StateObject private var navigation = AppNavigation()

    init() {
        let settings = AppSettings()
        let tools = ToolManager()
        let history = HistoryStore()
        let library = LibraryViewModel(history: history)
        _settings = StateObject(wrappedValue: settings)
        _tools = StateObject(wrappedValue: tools)
        _input = StateObject(wrappedValue: InputViewModel())
        _history = StateObject(wrappedValue: history)
        _library = StateObject(wrappedValue: library)
        _queue = StateObject(wrappedValue: QueueViewModel(settings: settings, tools: tools, history: history, library: library))
    }

    var body: some Scene {
        Window("Velvet", id: "main") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(tools)
                .environmentObject(input)
                .environmentObject(queue)
                .environmentObject(history)
                .environmentObject(library)
                .environmentObject(navigation)
                .task {
                    appDelegate.queue = queue
                    appDelegate.history = history
                    // Beim ersten Start prüfen, ob die gebündelten Werkzeuge funktionieren.
                    await tools.prepare(autoUpdate: settings.autoUpdateYtDlp)
                }
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            VelvetCommands(input: input, navigation: navigation)
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(tools)
                .environmentObject(queue)
        }
    }
}

struct VelvetCommands: Commands {
    @ObservedObject var input: InputViewModel
    @ObservedObject var navigation: AppNavigation

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neue Playlist") {
                navigation.newPlaylistSource = navigation.sourceID ?? LibrarySource.macID
            }
            .keyboardShortcut("n")

            Button("Mehrere Titel hinzufügen …") {
                navigation.showAddSeveral = true
            }
            .keyboardShortcut("l")

            Button("Titel aus Datei hinzufügen …") {
                input.chooseFile()
                if !input.text.isEmpty { navigation.showAddSeveral = true }
            }
            .keyboardShortcut("o")
        }
        CommandGroup(after: .textEditing) {
            Button("Titel suchen") {
                if navigation.selection == .history { navigation.selection = .allTracks(source: LibrarySource.macID) }
                navigation.focusSearch = UUID()
            }
            .keyboardShortcut("f")
        }
        CommandGroup(before: .sidebar) {
            Button("Verlauf") { navigation.selection = .history }
                .keyboardShortcut("y")
            Divider()
        }
    }
}
