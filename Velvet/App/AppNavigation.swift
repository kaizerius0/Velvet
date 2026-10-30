import Foundation

/// Was in der Seitenleiste gewählt ist – und Aufträge aus dem Menü an die Oberfläche.
@MainActor
final class AppNavigation: ObservableObject {
    enum Item: Hashable {
        /// Titel suchen und hinzufügen – einer oder eine ganze Liste.
        case add
        /// Alle Titel einer Bibliothek (Mac oder Stick).
        case allTracks(source: String)
        /// Eine Playlist (Ordner) einer Bibliothek.
        case playlist(source: String, id: String)
        case history
    }

    @Published var selection: Item? = .add
    /// Menübefehle, die eine Ansicht öffnen soll.
    /// Bibliothek, in der eine neue Playlist angelegt werden soll.
    @Published var newPlaylistSource: String?
    /// Setzt den Cursor ins Eingabefeld von „Hinzufügen“.
    @Published var focusInput = UUID()

    var sourceID: String? {
        switch selection {
        case let .allTracks(source), let .playlist(source, _): return source
        case .add, .history, .none: return nil
        }
    }

    var playlistID: String? {
        if case let .playlist(_, id) = selection { return id }
        return nil
    }
}
