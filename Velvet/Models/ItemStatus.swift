import Foundation

enum SkipReason: Equatable, Sendable {
    case archived
    case alreadyExists
    case livestream

    var text: String {
        switch self {
        case .archived: return "Übersprungen – bereits geladen (Archiv)"
        case .alreadyExists: return "Übersprungen – Datei ist schon vorhanden"
        case .livestream: return "Übersprungen – Livestreams werden nicht geladen"
        }
    }
}

/// Zustand eines Eintrags in der Download-Liste.
enum ItemStatus: Equatable {
    /// Wartet auf einen freien Download-Platz.
    case waiting
    case searching
    case needsSelection
    case noResults
    case resolvingPlaylist
    case downloading
    case processing
    case completed
    case skipped(SkipReason)
    case failed(String)
    case cancelled
    /// Vom Nutzer ausgelassen.
    case ignored

    /// Abgeschlossen – egal ob erfolgreich oder nicht.
    var isTerminal: Bool {
        switch self {
        case .completed, .skipped, .failed, .cancelled, .ignored: return true
        default: return false
        }
    }

    /// Velvet arbeitet gerade an diesem Eintrag.
    var isBusy: Bool {
        switch self {
        case .waiting, .searching, .resolvingPlaylist, .downloading, .processing: return true
        default: return false
        }
    }

    /// Der Nutzer muss etwas tun.
    var needsAttention: Bool {
        self == .needsSelection || self == .noResults
    }

    var isTransferring: Bool {
        self == .downloading || self == .processing
    }

    var isProblem: Bool {
        switch self {
        case .failed, .cancelled: return true
        default: return false
        }
    }
}
