import Foundation

/// Dauerhaft gespeicherte Einstellungen.
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let format = "format"
        static let videoQuality = "videoQuality"
        static let audioQuality = "audioQuality"
        static let autoPickFirstResult = "autoPickFirstResult"
        static let useArchive = "useArchive"
        static let maxParallelDownloads = "maxParallelDownloads"
        static let cookieBrowser = "cookieBrowser"
        static let autoUpdateYtDlp = "autoUpdateYtDlp"
        static let lastDestinationPath = "lastDestinationPath"
    }

    private let defaults: UserDefaults

    @Published var format: MediaFormat {
        didSet { defaults.set(format.rawValue, forKey: Key.format) }
    }
    @Published var videoQuality: VideoQuality {
        didSet { defaults.set(videoQuality.rawValue, forKey: Key.videoQuality) }
    }
    @Published var audioQuality: AudioQuality {
        didSet { defaults.set(audioQuality.rawValue, forKey: Key.audioQuality) }
    }
    @Published var autoPickFirstResult: Bool {
        didSet { defaults.set(autoPickFirstResult, forKey: Key.autoPickFirstResult) }
    }
    @Published var useArchive: Bool {
        didSet { defaults.set(useArchive, forKey: Key.useArchive) }
    }
    @Published var maxParallelDownloads: Int {
        didSet { defaults.set(maxParallelDownloads, forKey: Key.maxParallelDownloads) }
    }
    @Published var cookieBrowser: CookieBrowser {
        didSet { defaults.set(cookieBrowser.rawValue, forKey: Key.cookieBrowser) }
    }
    @Published var autoUpdateYtDlp: Bool {
        didSet { defaults.set(autoUpdateYtDlp, forKey: Key.autoUpdateYtDlp) }
    }
    @Published var lastDestinationPath: String? {
        didSet { defaults.set(lastDestinationPath, forKey: Key.lastDestinationPath) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.useArchive: true,
            Key.maxParallelDownloads: 2,
            Key.autoUpdateYtDlp: true,
        ])
        format = MediaFormat(rawValue: defaults.string(forKey: Key.format) ?? "") ?? .video
        videoQuality = VideoQuality(rawValue: defaults.string(forKey: Key.videoQuality) ?? "") ?? .p720
        audioQuality = AudioQuality(rawValue: defaults.string(forKey: Key.audioQuality) ?? "") ?? .best
        autoPickFirstResult = defaults.bool(forKey: Key.autoPickFirstResult)
        useArchive = defaults.bool(forKey: Key.useArchive)
        maxParallelDownloads = min(max(defaults.integer(forKey: Key.maxParallelDownloads), 1), 4)
        cookieBrowser = CookieBrowser(rawValue: defaults.string(forKey: Key.cookieBrowser) ?? "") ?? .none
        autoUpdateYtDlp = defaults.bool(forKey: Key.autoUpdateYtDlp)
        lastDestinationPath = defaults.string(forKey: Key.lastDestinationPath)
    }

    var lastDestination: URL? {
        guard let lastDestinationPath, FileManager.default.fileExists(atPath: lastDestinationPath) else { return nil }
        return URL(fileURLWithPath: lastDestinationPath, isDirectory: true)
    }

    var qualityDescription: String {
        format == .video ? videoQuality.title : audioQuality.title
    }

    func downloadOptions(destination: URL) -> DownloadOptions {
        DownloadOptions(
            format: format,
            videoQuality: videoQuality,
            audioQuality: audioQuality,
            destination: destination,
            useArchive: useArchive,
            cookieBrowser: cookieBrowser
        )
    }
}
