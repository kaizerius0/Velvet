import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var queue: QueueViewModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let queue, queue.hasBusyItems else { return .terminateNow }
        let quit = Dialogs.confirm(
            title: "Downloads laufen noch",
            message: "Wenn du Velvet jetzt beendest, werden laufende Downloads abgebrochen. Bereits fertige Dateien bleiben erhalten.",
            confirmTitle: "Beenden",
            cancelTitle: "Weiterladen"
        )
        return quit ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // yt-dlp-Prozesse sollen nicht ohne die App weiterlaufen.
        RunningProcesses.shared.terminateAll()
    }
}

enum Dialogs {
    @MainActor
    static func confirm(title: String, message: String, confirmTitle: String, cancelTitle: String = "Abbrechen") -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum FolderPicker {
    /// Fragt bei jedem Lauf nach dem Zielordner.
    @MainActor
    static func chooseDestination(startingAt directory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Zielordner wählen"
        panel.message = "Wähle den Ordner, in dem die Downloads gespeichert werden sollen."
        panel.prompt = "Hier speichern"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return panel.runModal() == .OK ? panel.url : nil
    }
}
