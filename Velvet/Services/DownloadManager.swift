import Foundation

/// Was ein laufender Download an die Oberfläche meldet.
enum DownloadEvent: Sendable {
    case metadata(videoID: String, title: String)
    case progress(fraction: Double, speed: Double?, eta: Double?)
    case postprocessing(String)
}

enum DownloadResult: Sendable, Equatable {
    case completed(file: URL, videoID: String?)
    case skipped(SkipReason)
}

struct DownloadFailure: LocalizedError, Sendable {
    let message: String
    let log: [String]

    var errorDescription: String? { message }
}

/// Kapselt alle Aufrufe von yt-dlp: Suche, Playlist-Auflösung und Downloads mit Live-Fortschritt.
final class DownloadManager: @unchecked Sendable {
    static let searchPageSize = 5

    private let tools: ToolPaths

    init(tools: ToolPaths) {
        self.tools = tools
    }

    // MARK: - Suche

    /// Sucht auf YouTube (`ytsearch`) und liefert bis zu fünf Treffer, die nicht in `seen` stehen.
    ///
    /// YouTube sortiert Treffer bei jeder Anfrage leicht anders – deshalb werden für „Andere Vorschläge“
    /// keine festen Seiten geladen, sondern etwas mehr Treffer, aus denen bereits gezeigte aussortiert werden.
    func search(_ query: String, excluding seen: Set<String> = [], cookies: CookieBrowser = .none) async throws -> [VideoCandidate] {
        let count = min(seen.count + Self.searchPageSize * 2, 100)
        let arguments = commonArguments(cookies: cookies) + [
            "--flat-playlist",
            "--dump-single-json",
            "--",
            "ytsearch\(count):\(query)",
        ]
        let output = try await run(arguments, timeout: 90)
        try Task.checkCancellation()
        guard output.succeeded else {
            throw failure(from: output, lastError: nil, fallback: "Die Suche ist fehlgeschlagen.")
        }
        let fresh = try YTDLPOutput.parseEntries(Data(output.stdout.utf8)).filter { !seen.contains($0.id) }
        return Array(fresh.prefix(Self.searchPageSize))
    }

    // MARK: - Playlists

    /// Liest alle Videos einer Playlist, ohne sie herunterzuladen.
    func playlistEntries(_ url: URL, cookies: CookieBrowser = .none) async throws -> [VideoCandidate] {
        let arguments = commonArguments(cookies: cookies) + [
            "--flat-playlist",
            "--dump-single-json",
            "--",
            url.absoluteString,
        ]
        let output = try await run(arguments, timeout: 180)
        try Task.checkCancellation()
        guard output.succeeded else {
            throw failure(from: output, lastError: nil, fallback: "Die Playlist konnte nicht gelesen werden.")
        }
        return try YTDLPOutput.parseEntries(Data(output.stdout.utf8))
    }

    // MARK: - Download

    /// Lädt ein Video als MP4 oder MP3 und meldet Fortschritt über `onEvent`.
    func download(
        _ url: URL,
        options: DownloadOptions,
        onEvent: @escaping @Sendable (DownloadEvent) -> Void
    ) async throws -> DownloadResult {
        try? FileManager.default.createDirectory(at: options.tempDirectory, withIntermediateDirectories: true)

        let tracker = DownloadTracker(onEvent: onEvent)
        let output = try await run(downloadArguments(for: url, options: options), collectStdout: false) { _, line in
            tracker.consume(line)
        }
        if output.wasCancelled || Task.isCancelled { throw CancellationError() }

        let state = tracker.state
        // Liegt eine fertige Datei vor, zählt der Download – auch wenn danach noch eine Warnung kam.
        if let file = state.files.last {
            return .completed(file: file, videoID: state.videoID)
        }
        if output.exitCode == 0 {
            return .skipped(state.skipReason ?? .alreadyExists)
        }
        throw failure(from: output, lastError: state.lastError, fallback: "Der Download ist fehlgeschlagen.")
    }

    func downloadArguments(for url: URL, options: DownloadOptions) -> [String] {
        var arguments = commonArguments(cookies: options.cookieBrowser)
        arguments += [
            "--no-quiet",
            "--newline",
            "--progress",
            "--no-simulate",
            "--progress-delta", "0.25",
            "--progress-template", YTDLPOutput.progressTemplate,
            "--progress-template", YTDLPOutput.postprocessTemplate,
            "--print", YTDLPOutput.infoTemplate,
            "--print", YTDLPOutput.fileTemplate,
            "--paths", "home:\(options.destination.path)",
            "--paths", "temp:\(options.tempDirectory.path)",
            "--output", "%(title).180B.%(ext)s",
            "--no-playlist",
            "--no-mtime",
            "--embed-metadata",
            "--match-filters", "!is_live",
        ]
        if options.useArchive {
            arguments += ["--download-archive", options.archiveURL.path]
        }

        switch options.format {
        case .video:
            arguments += [
                "--format", "bv*+ba/b",
                "--format-sort", options.videoQuality.formatSort,
                "--merge-output-format", "mp4",
                "--remux-video", "mp4",
            ]
        case .audio:
            arguments += [
                "--format", "ba/b",
                "--extract-audio",
                "--audio-format", "mp3",
                "--audio-quality", options.audioQuality.ytDlpValue,
                "--embed-thumbnail",
                "--convert-thumbnails", "jpg",
                // "Interpret - Titel" in saubere ID3-Tags zerlegen, ohne den Dateinamen zu ändern.
                "--parse-metadata", "title:(?P<meta_artist>.+?) - (?P<meta_title>.+)",
                "--replace-in-metadata", "meta_title",
                #"\s*[\(\[][^\)\]]*(?i:official|offiziell|lyric|video|audio|visuali[sz]er|remaster|hd|4k)[^\)\]]*[\)\]]"#, "",
            ]
        }

        arguments += ["--", url.absoluteString]
        return arguments
    }

    // MARK: - Archiv

    /// Entfernt ein Video aus dem Download-Archiv (z. B. wenn ein falsch gewähltes Video ersetzt wurde).
    static func removeFromArchive(videoID: String, archive: URL) {
        guard let content = try? String(contentsOf: archive, encoding: .utf8) else { return }
        let kept = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let parts = line.split(separator: " ")
                return !(parts.count == 2 && parts[1] == videoID)
            }
        try? kept.joined(separator: "\n").write(to: archive, atomically: true, encoding: .utf8)
    }

    // MARK: - Intern

    private func commonArguments(cookies: CookieBrowser) -> [String] {
        var arguments = [
            "--ignore-config",
            "--color", "never",
            "--ffmpeg-location", tools.ffmpeg.deletingLastPathComponent().path,
        ]
        if let deno = tools.deno {
            arguments += ["--js-runtimes", "deno:\(deno.path)"]
        }
        if let browser = cookies.ytDlpValue {
            arguments += ["--cookies-from-browser", browser]
        }
        return arguments
    }

    private var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let systemPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = (tools.searchDirectories + systemPath).joined(separator: ":")
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    private func run(
        _ arguments: [String],
        collectStdout: Bool = true,
        timeout: TimeInterval? = nil,
        onLine: (@Sendable (ProcessRunner.Stream, String) -> Void)? = nil
    ) async throws -> ProcessRunner.Output {
        try await ProcessRunner.run(
            tools.ytDlp,
            arguments: arguments,
            environment: environment,
            collectStdout: collectStdout,
            timeout: timeout,
            onLine: onLine
        )
    }

    private func failure(from output: ProcessRunner.Output, lastError: String?, fallback: String) -> DownloadFailure {
        if output.timedOut {
            return DownloadFailure(message: "yt-dlp hat nicht rechtzeitig geantwortet. Bitte erneut versuchen.", log: output.tail)
        }
        let error = lastError
            ?? output.tail.reversed().lazy.compactMap(YTDLPOutput.errorMessage(in:)).first
            ?? output.stderr.split(separator: "\n").last.map(String.init)
        let message = error.map(YTDLPOutput.friendlyError) ?? fallback
        return DownloadFailure(message: message, log: output.tail)
    }
}

// MARK: - Fortschritt eines Downloads

/// Wertet die Zeilen eines Downloads aus. Zeilen kommen nacheinander, nie gleichzeitig.
private final class DownloadTracker: @unchecked Sendable {
    struct State {
        var videoID: String?
        var formatParts: [String] = []
        var files: [URL] = []
        var skipReason: SkipReason?
        var lastError: String?
        var downloadStarted = false
    }

    private let lock = NSLock()
    private var current = State()
    private let onEvent: @Sendable (DownloadEvent) -> Void

    init(onEvent: @escaping @Sendable (DownloadEvent) -> Void) {
        self.onEvent = onEvent
    }

    var state: State { lock.locked { current } }

    func consume(_ line: String) {
        guard let event = YTDLPOutput.parse(line) else {
            lock.locked {
                if let reason = YTDLPOutput.skipReason(in: line) { current.skipReason = reason }
                if let error = YTDLPOutput.errorMessage(in: line) { current.lastError = error }
            }
            return
        }

        switch event {
        case let .info(videoID, formatID, title):
            lock.locked {
                current.videoID = videoID
                current.formatParts = formatID.split(separator: "+").map(String.init)
            }
            onEvent(.metadata(videoID: videoID, title: title))

        case let .progress(formatID, _, downloaded, total, speed, eta):
            let parts = lock.locked { () -> [String] in
                current.downloadStarted = true
                return current.formatParts
            }
            if let fraction = YTDLPOutput.downloadFraction(formatParts: parts, formatID: formatID, downloaded: downloaded, total: total) {
                onEvent(.progress(fraction: fraction, speed: speed, eta: eta))
            }

        case let .postprocess(status, name):
            let started = lock.locked { current.downloadStarted }
            if status == "started", started, let label = YTDLPOutput.postprocessorLabel(name) {
                onEvent(.postprocessing(label))
            }

        case let .file(path):
            lock.locked { current.files.append(URL(fileURLWithPath: path)) }
        }
    }
}
