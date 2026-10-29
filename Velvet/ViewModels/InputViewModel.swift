import AppKit
import Foundation

/// Das Eingabefeld: Text, Live-Erkennung der Einträge und Laden aus Dateien.
@MainActor
final class InputViewModel: ObservableObject {
    @Published var text: String {
        didSet { scheduleParse() }
    }
    @Published private(set) var parsed: ListParseResult
    @Published var notice: String?
    @Published var errorMessage: String?

    private var parseTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private let draftKey = "listDraft"

    init() {
        let draft = UserDefaults.standard.string(forKey: draftKey) ?? ""
        text = draft
        parsed = ListParser.parse(draft)
    }

    /// Sofort parsen (z. B. direkt vor dem Start), ohne auf die Verzögerung zu warten.
    @discardableResult
    func parseNow() -> ListParseResult {
        parseTask?.cancel()
        parsed = ListParser.parse(text)
        return parsed
    }

    func clear() {
        text = ""
    }

    func pasteFromClipboard() {
        guard let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty else {
            showNotice("Die Zwischenablage enthält keinen Text.")
            return
        }
        append(clip)
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Liste laden"
        panel.message = "Wähle eine oder mehrere Textdateien mit deiner Liste."
        panel.prompt = "Laden"
        panel.allowedContentTypes = TextFileLoader.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { load(from: url) }
    }

    /// Hängt den Inhalt an – so geht nichts verloren, was schon im Feld steht.
    func load(from url: URL) {
        do {
            let content = try TextFileLoader.load(url)
            let found = ListParser.parse(content).entries.count
            append(content)
            showNotice("„\(url.lastPathComponent)“ geladen – \(Formatters.count(found, "Eintrag", "Einträge")) erkannt.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func append(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = trimmed
        } else {
            text = text.trimmingCharacters(in: .newlines) + "\n" + trimmed
        }
        parseNow()
    }

    private func scheduleParse() {
        parseTask?.cancel()
        let snapshot = text
        parseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self else { return }
            self.parsed = ListParser.parse(snapshot)
            UserDefaults.standard.set(snapshot, forKey: self.draftKey)
        }
    }

    private func showNotice(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
