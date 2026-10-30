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
        static let skipExisting = "skipExisting"
        static let addTargetPath = "addTargetPath"
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
    /// Der Ordner, in den neue Titel kommen („“ = noch keiner gewählt).
    @Published var addTargetPath: String {
        didSet { defaults.set(addTargetPath, forKey: Key.addTargetPath) }
    }
    /// Titel überspringen, die schon in der Bibliothek liegen.
    @Published var skipExisting: Bool {
        didSet { defaults.set(skipExisting, forKey: Key.skipExisting) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            // Das Archiv ist seit der Duplikat-Erkennung nur noch optional.
            Key.useArchive: false,
            Key.maxParallelDownloads: 2,
            Key.autoUpdateYtDlp: true,
            Key.skipExisting: true,
        ])
        format = MediaFormat(rawValue: defaults.string(forKey: Key.format) ?? "") ?? .audio
        videoQuality = VideoQuality(rawValue: defaults.string(forKey: Key.videoQuality) ?? "") ?? .p720
        audioQuality = AudioQuality(rawValue: defaults.string(forKey: Key.audioQuality) ?? "") ?? .best
        autoPickFirstResult = defaults.bool(forKey: Key.autoPickFirstResult)
        useArchive = defaults.bool(forKey: Key.useArchive)
        maxParallelDownloads = min(max(defaults.integer(forKey: Key.maxParallelDownloads), 1), 4)
        cookieBrowser = CookieBrowser(rawValue: defaults.string(forKey: Key.cookieBrowser) ?? "") ?? .none
        autoUpdateYtDlp = defaults.bool(forKey: Key.autoUpdateYtDlp)
        skipExisting = defaults.bool(forKey: Key.skipExisting)
        addTargetPath = defaults.string(forKey: Key.addTargetPath) ?? ""
    }

    /// Der gewählte Ordner – sofern es ihn gibt (ein abgezogener Stick zählt nicht).
    var addTarget: URL? {
        get {
            var isDirectory: ObjCBool = false
            guard !addTargetPath.isEmpty, FileManager.default.fileExists(atPath: addTargetPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: addTargetPath, isDirectory: true)
        }
        set { addTargetPath = newValue?.standardizedFileURL.path ?? "" }
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
