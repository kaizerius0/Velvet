import Foundation

/// Ein eingehängtes Laufwerk (USB-Stick, externe Festplatte).
struct VolumeInfo: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let uuid: String?
    let isExternal: Bool
    let fileSystem: String?
    let totalBytes: Int64?
    let availableBytes: Int64?

    var id: String { uuid ?? url.path }

    var freeSpaceText: String? {
        guard let availableBytes, let totalBytes, totalBytes > 0 else { return nil }
        return "\(Formatters.bytes(availableBytes)) frei von \(Formatters.bytes(totalBytes))"
    }

    var usedFraction: Double? {
        guard let availableBytes, let totalBytes, totalBytes > 0 else { return nil }
        return 1 - Double(availableBytes) / Double(totalBytes)
    }
}

/// Eine Bibliothek in der Seitenleiste: deine Ordner auf dem Mac oder ein eingesteckter Stick.
struct LibrarySource: Identifiable, Hashable, Sendable {
    static let macID = "mac"

    let id: String
    let name: String
    /// Stick: das Laufwerk selbst (seine Unterordner sind die Ordner).
    /// Mac: die Ordner, die du in die Seitenleiste geholt hast.
    let roots: [URL]
    /// Nur bei Sticks und externen Laufwerken.
    let volume: VolumeInfo?

    var isExternal: Bool { volume != nil }
}

/// Ein Ordner in der Bibliothek – das, was anderswo eine Playlist ist.
struct LibraryFolder: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let trackCount: Int
    /// Der Stick selbst – heißt wie der Stick und lässt sich nicht umbenennen oder löschen.
    let isVolumeRoot: Bool

    var id: String { url.standardizedFileURL.path }
}

/// Eine Audio- oder Videodatei in der Bibliothek.
struct Track: Identifiable, Hashable, Sendable {
    let url: URL
    /// Name des Ordners – direkt auf dem Stick der Name des Sticks.
    let folderName: String
    let size: Int64
    let added: Date
    let isAudio: Bool

    var id: String { url.standardizedFileURL.path }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var format: String { url.pathExtension.uppercased() }
    var folderID: String { url.deletingLastPathComponent().standardizedFileURL.path }
}

/// Ein Eintrag im Verlauf: was wann wohin geladen wurde.
struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        case downloaded
        case replaced
        case deleted
    }

    var id = UUID()
    var date: Date
    var title: String
    /// Der ursprüngliche Eintrag aus der Liste (bei Suchen).
    var query: String?
    var videoID: String?
    var sourceURL: String?
    var format: String
    var path: String
    var folderName: String
    var volumeName: String
    var volumeUUID: String?
    /// Pfad innerhalb des Laufwerks – nur bei externen Laufwerken.
    var relativePath: String?
    var state: State = .downloaded
    var stateDate: Date?
    var note: String?

    var locationText: String { "\(volumeName) › \(folderName)" }
}

/// Wo eine Datei aus dem Verlauf gerade ist.
enum HistoryAvailability: Equatable {
    case present(URL)
    case offline(String)
    case missing
    case replaced(String?)
    case deleted

    var isPresent: Bool {
        if case .present = self { return true }
        return false
    }
}

/// Ein Titel aus der Liste, der schon irgendwo vorhanden ist.
struct DuplicateHit: Equatable {
    enum Strength: Equatable {
        /// Gleiches Video oder gleicher Titel.
        case exact
        /// Ähnlich – z. B. „Africa“ vorhanden, gesucht wird „Africa Extended“.
        case similar
    }

    let strength: Strength
    let title: String
    let location: String
    let url: URL?
    /// Liegt in der gerade gewählten Bibliothek (Stick/Ordner).
    let inCurrentLibrary: Bool
}
