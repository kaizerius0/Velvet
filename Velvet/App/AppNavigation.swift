import Foundation

/// Was in der Seitenleiste gewählt ist – und Aufträge aus dem Menü an die Oberfläche.
@MainActor
final class AppNavigation: ObservableObject {
    enum Item: Hashable {
        /// Titel suchen und hinzufügen – einer oder eine ganze Liste.
        case add
        /// Alle Titel eines Sticks.
        case allTracks(source: String)
        /// Ein Ordner auf dem Mac oder einem Stick.
        case folder(source: String, id: String)
        case history
    }

    @Published var selection: Item? = .add
    /// Bibliothek, in der ein neuer Ordner angelegt werden soll (aus dem Menü).
    @Published var newFolderSource: String?
    /// Setzt den Cursor ins Eingabefeld von „Hinzufügen“.
    @Published var focusInput = UUID()

    var sourceID: String? {
        switch selection {
        case let .allTracks(source), let .folder(source, _): return source
        case .add, .history, .none: return nil
        }
    }

    var folderID: String? {
        if case let .folder(_, id) = selection { return id }
        return nil
    }
}
