import Foundation

/// Welcher Bereich gerade in der Seitenleiste gewählt ist.
@MainActor
final class AppNavigation: ObservableObject {
    enum Section: String, Hashable, CaseIterable {
        case downloads
        case library
        case history

        var title: String {
            switch self {
            case .downloads: return "Downloads"
            case .library: return "Bibliothek"
            case .history: return "Verlauf"
            }
        }

        var symbol: String {
            switch self {
            case .downloads: return "arrow.down.circle"
            case .library: return "music.note.list"
            case .history: return "clock.arrow.circlepath"
            }
        }
    }

    @Published var section: Section? = .downloads
}
