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
        .defaultSize(width: 1320, height: 880)
        .commands {
            VelvetCommands(input: input, queue: queue, navigation: navigation)
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
    @ObservedObject var queue: QueueViewModel
    @ObservedObject var navigation: AppNavigation

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            ForEach(Array(AppNavigation.Section.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { navigation.section = section }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
        }

        CommandGroup(replacing: .newItem) {
            Button("Neue Liste") {
                if !queue.hasBusyItems || Dialogs.confirm(
                    title: "Neue Liste beginnen?",
                    message: "Laufende Downloads werden abgebrochen. Bereits geladene Dateien bleiben erhalten.",
                    confirmTitle: "Abbrechen und neu beginnen"
                ) {
                    queue.reset()
                }
            }
            .keyboardShortcut("n")
            .disabled(!queue.hasRun)

            Button("Liste aus .txt-Datei laden …") {
                navigation.section = .downloads
                input.chooseFile()
            }
            .keyboardShortcut("o")
            .disabled(queue.hasRun)

            Divider()

            Button("Zielordner im Finder öffnen") {
                queue.openDestination()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(queue.destination == nil)
        }
    }
}
