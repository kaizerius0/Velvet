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
    @StateObject private var taste: TasteStore
    @StateObject private var analysis: AnalysisCenter
    @StateObject private var player: PreviewPlayer
    @StateObject private var discover: DiscoverViewModel

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
        let queue = QueueViewModel(settings: settings, tools: tools, history: history, library: library)
        _queue = StateObject(wrappedValue: queue)

        let taste = TasteStore()
        let analysis = AnalysisCenter(tools: tools, settings: settings)
        analysis.library = library
        queue.analysis = analysis
        let player = PreviewPlayer(tools: tools, settings: settings)
        player.onListened = { [weak taste] in taste?.recordListen($0) }
        _taste = StateObject(wrappedValue: taste)
        _analysis = StateObject(wrappedValue: analysis)
        _player = StateObject(wrappedValue: player)
        _discover = StateObject(wrappedValue: DiscoverViewModel(
            settings: settings, tools: tools, history: history, library: library,
            queue: queue, taste: taste, analysis: analysis
        ))
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
                .environmentObject(taste)
                .environmentObject(analysis)
                .environmentObject(player)
                .environmentObject(discover)
                .task {
                    appDelegate.queue = queue
                    appDelegate.history = history
                    appDelegate.taste = taste
                    // Beim ersten Start prüfen, ob die gebündelten Werkzeuge funktionieren.
                    await tools.prepare(autoUpdate: settings.autoUpdateYtDlp)
                }
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            VelvetCommands(input: input, navigation: navigation, player: player)
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(tools)
                .environmentObject(queue)
                .environmentObject(taste)
        }
    }
}

struct VelvetCommands: Commands {
    @ObservedObject var input: InputViewModel
    @ObservedObject var navigation: AppNavigation
    @ObservedObject var player: PreviewPlayer

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neuer Ordner …") {
                navigation.newFolderSource = navigation.sourceID ?? LibrarySource.macID
            }
            .keyboardShortcut("n")

            Button("Titel hinzufügen") {
                navigation.selection = .add
                navigation.focusInput = UUID()
            }
            .keyboardShortcut("l")

            Button("Titel aus Datei hinzufügen …") {
                navigation.selection = .add
                input.chooseFile()
            }
            .keyboardShortcut("o")
        }
        CommandGroup(before: .sidebar) {
            Button("Entdecken") { navigation.selection = .discover }
                .keyboardShortcut("e")
            Button("Set bauen …") {
                navigation.selection = .discover
                navigation.focusSetBuilder = UUID()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Verlauf") { navigation.selection = .history }
                .keyboardShortcut("y")
            Divider()
        }
        CommandMenu("Wiedergabe") {
            Button(player.isPlaying ? "Pause" : "Abspielen") { player.togglePlayPause() }
                .disabled(!player.isActive)
            Button("15 Sekunden zurück") { player.skip(by: -15) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!player.isActive)
            Button("15 Sekunden vor") { player.skip(by: 15) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!player.isActive)
            Divider()
            Button("Wiedergabe beenden") { player.stop() }
                .keyboardShortcut(".", modifiers: [.command, .option])
                .disabled(!player.isActive)
        }
    }
}
