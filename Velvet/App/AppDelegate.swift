import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var queue: QueueViewModel?
    weak var history: HistoryStore?

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
        history?.saveNow()
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
