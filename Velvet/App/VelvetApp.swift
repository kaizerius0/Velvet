import SwiftUI

@main
struct VelvetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var tools: ToolManager
    @StateObject private var input: InputViewModel
    @StateObject private var queue: QueueViewModel

    init() {
        let settings = AppSettings()
        let tools = ToolManager()
        _settings = StateObject(wrappedValue: settings)
        _tools = StateObject(wrappedValue: tools)
        _input = StateObject(wrappedValue: InputViewModel())
        _queue = StateObject(wrappedValue: QueueViewModel(settings: settings, tools: tools))
    }

    var body: some Scene {
        Window("Velvet", id: "main") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(tools)
                .environmentObject(input)
                .environmentObject(queue)
                .task {
                    appDelegate.queue = queue
                    // Beim ersten Start prüfen, ob die gebündelten Werkzeuge funktionieren.
                    await tools.prepare(autoUpdate: settings.autoUpdateYtDlp)
                }
        }
        .defaultSize(width: 1120, height: 840)
        .commands {
            VelvetCommands(input: input, queue: queue)
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

    var body: some Commands {
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
