import Foundation

enum MediaFormat: String, CaseIterable, Identifiable, Sendable {
    case video
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return "Video (MP4)"
        case .audio: return "Nur Audio"
        }
    }

    var symbol: String {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        }
    }

    /// Getrennte Archive, damit ein Video als MP4 und später als MP3 geladen werden kann.
    var archiveFileName: String {
        switch self {
        case .video: return "archive.txt"
        case .audio: return "archive-mp3.txt"
        }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable, Sendable {
    case best
    case p1080
    case p720
    case p480

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: return "Beste"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        }
    }

    /// Sortierung für yt-dlp: höchstens diese Auflösung, H.264 + AAC bevorzugt (läuft überall, auch in QuickTime).
    var formatSort: String {
        switch self {
        case .best: return "res,fps,+codec:avc:m4a"
        case .p1080: return "res:1080,+codec:avc:m4a"
        case .p720: return "res:720,+codec:avc:m4a"
        case .p480: return "res:480,+codec:avc:m4a"
        }
    }
}

enum AudioQuality: String, CaseIterable, Identifiable, Sendable {
    case best
    case k320
    case k192
    case k128
    /// Die Tonspur von YouTube unverändert als M4A (AAC) – keine zweite verlustbehaftete Umwandlung.
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: return "MP3 – Beste (VBR)"
        case .k320: return "MP3 – 320 kbit/s"
        case .k192: return "MP3 – 192 kbit/s"
        case .k128: return "MP3 – 128 kbit/s"
        case .original: return "M4A – Original, ohne Umwandlung"
        }
    }

    /// „MP3“ oder „M4A“
    var fileType: String { self == .original ? "M4A" : "MP3" }

    var ytDlpValue: String {
        switch self {
        case .best, .original: return "0"
        case .k320: return "320K"
        case .k192: return "192K"
        case .k128: return "128K"
        }
    }
}

/// Browser, aus dem yt-dlp Cookies lesen darf (für altersbeschränkte Videos oder Bot-Prüfungen).
enum CookieBrowser: String, CaseIterable, Identifiable, Sendable {
    case none
    case safari
    case chrome
    case firefox
    case brave
    case edge
    case vivaldi
    case opera
    case chromium

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Keine"
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .firefox: return "Firefox"
        case .brave: return "Brave"
        case .edge: return "Microsoft Edge"
        case .vivaldi: return "Vivaldi"
        case .opera: return "Opera"
        case .chromium: return "Chromium"
        }
    }

    var ytDlpValue: String? {
        self == .none ? nil : rawValue
    }
}

/// Alle Einstellungen eines Download-Laufs – wird beim Start festgehalten.
struct DownloadOptions: Sendable, Equatable {
    var format: MediaFormat
    var videoQuality: VideoQuality
    var audioQuality: AudioQuality
    var destination: URL
    var useArchive: Bool
    var cookieBrowser: CookieBrowser
    var preferredVersion: PreferredVersion = .any
    /// „Interpret - Titel (Extended Mix)“ statt des Videotitels mit „Official Video“ & Co.
    var cleanFileNames = false

    var archiveURL: URL {
        destination.appendingPathComponent(format.archiveFileName)
    }

    /// Zwischendateien landen versteckt im Zielordner und werden erst fertig verschoben.
    var tempDirectory: URL {
        destination.appendingPathComponent(".velvet-temp", isDirectory: true)
    }
}
