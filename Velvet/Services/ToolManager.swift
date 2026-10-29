import AppKit
import Foundation

/// Pfade zu den Werkzeugen, die Velvet verwendet.
struct ToolPaths: Sendable, Equatable {
    var ytDlp: URL
    var ffmpeg: URL
    var ffprobe: URL?
    var deno: URL?

    /// Ordner, die beim Start von yt-dlp vorne in PATH stehen.
    var searchDirectories: [String] {
        var seen = Set<String>()
        return [ytDlp, ffmpeg, ffprobe, deno]
            .compactMap { $0?.deletingLastPathComponent().path }
            .filter { seen.insert($0).inserted }
    }
}

struct ToolVersions: Equatable {
    var ytDlp: String?
    var ffmpeg: String?
    var deno: String?
}

/// Findet, prüft und aktualisiert die gebündelten Werkzeuge.
///
/// yt-dlp wird beim ersten Start aus dem App-Bundle nach `~/Library/Application Support/Velvet/yt-dlp`
/// entpackt und dort aktualisiert (YouTube ändert sich oft – ein aktuelles yt-dlp ist der wichtigste
/// Faktor für funktionierende Downloads). ffmpeg, ffprobe und deno laufen direkt aus dem Bundle.
@MainActor
final class ToolManager: ObservableObject {
    enum State: Equatable {
        case checking
        case ready
        case failed(String)
    }

    enum ToolError: LocalizedError {
        case missing(String)
        case notWorking(String, String)

        var errorDescription: String? {
            switch self {
            case let .missing(tool):
                return "\(tool) wurde weder im App-Bundle noch auf dem System gefunden."
            case let .notWorking(tool, detail):
                return "\(tool) lässt sich nicht starten: \(detail)"
            }
        }
    }

    @Published private(set) var state: State = .checking
    @Published private(set) var paths: ToolPaths?
    @Published private(set) var versions = ToolVersions()
    @Published private(set) var isUpdating = false
    @Published private(set) var updateMessage: String?

    private let fileManager = FileManager.default
    private let lastUpdateCheckKey = "lastYtDlpUpdateCheck"

    var isReady: Bool { state == .ready }

    // MARK: Prüfen

    func prepare(autoUpdate: Bool) async {
        state = .checking
        YtDlpInstaller.removeLeftovers()
        await Self.terminateOrphanedDownloads()
        do {
            let ytDlp = try await ensureYtDlp(force: false)
            guard let ffmpeg = locate("ffmpeg") else { throw ToolError.missing("ffmpeg") }
            let resolved = ToolPaths(ytDlp: ytDlp, ffmpeg: ffmpeg, ffprobe: locate("ffprobe"), deno: locate("deno"))

            var found = ToolVersions()
            do {
                found.ytDlp = try await Self.version(of: ytDlp, arguments: ["--version"])
            } catch {
                // Die Installation könnte beschädigt sein – frisch aus dem Bundle entpacken.
                try await ensureYtDlp(force: true)
                found.ytDlp = try await Self.version(of: ytDlp, arguments: ["--version"])
            }
            let ffmpegLine = try await Self.version(of: ffmpeg, arguments: ["-hide_banner", "-version"])
            found.ffmpeg = Self.shortVersion(ffmpegLine, prefix: "ffmpeg version ")
            if let deno = resolved.deno {
                let denoLine = try? await Self.version(of: deno, arguments: ["--version"])
                found.deno = Self.shortVersion(denoLine, prefix: "deno ")
            }

            if let version = found.ytDlp, ytDlp == (try? YtDlpInstaller.executable()) {
                YtDlpInstaller.writeInstalledVersion(version)
            }
            versions = found
            paths = resolved
            state = .ready

            if autoUpdate, shouldCheckForUpdate {
                Task { await updateYtDlp(silent: true) }
            }
        } catch {
            paths = nil
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Aktualisieren

    /// Holt bei Bedarf das neueste yt-dlp von GitHub (geprüft per SHA-256).
    func updateYtDlp(silent: Bool = false) async {
        guard paths != nil, !isUpdating else { return }
        isUpdating = true
        if !silent { updateMessage = "Suche nach Updates …" }
        defer { isUpdating = false }
        UserDefaults.standard.set(Date(), forKey: lastUpdateCheckKey)

        do {
            let latest = try await YtDlpInstaller.latestVersion()
            let current = versions.ytDlp ?? YtDlpInstaller.installedVersion ?? "0"
            guard VersionComparator.isNewer(latest, than: current) else {
                if !silent { updateMessage = "yt-dlp ist aktuell (\(current))." }
                return
            }
            if !silent { updateMessage = "Lade yt-dlp \(latest) …" }
            let installed = try await YtDlpInstaller.update(to: latest)
            versions.ytDlp = installed
            updateMessage = "yt-dlp wurde auf \(installed) aktualisiert."
        } catch {
            if !silent { updateMessage = "Update fehlgeschlagen: \(error.localizedDescription)" }
        }
    }

    func revealToolsFolder() {
        guard let directory = try? YtDlpInstaller.installDirectory() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private var shouldCheckForUpdate: Bool {
        guard let last = UserDefaults.standard.object(forKey: lastUpdateCheckKey) as? Date else { return true }
        return Date().timeIntervalSince(last) > 20 * 60 * 60
    }

    // MARK: Dateien

    nonisolated static func bundledTool(_ name: String) -> URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var bundledYtDlpVersion: String? {
        Self.bundledTool("yt-dlp.version")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Entpackt yt-dlp aus dem Bundle, wenn es noch fehlt oder das gebündelte neuer ist.
    @discardableResult
    private func ensureYtDlp(force: Bool) async throws -> URL {
        let executable = try YtDlpInstaller.executable()
        guard let archive = Self.bundledTool(YtDlpInstaller.assetName) else {
            if fileManager.isExecutableFile(atPath: executable.path) { return executable }
            if let system = systemTool("yt-dlp") { return system }
            throw ToolError.missing("yt-dlp")
        }

        try await YtDlpInstaller.installIfNeeded(archive: archive, bundledVersion: bundledYtDlpVersion, force: force)
        return executable
    }

    /// Sucht ein Werkzeug im Bundle, sonst in Homebrew- und Systempfaden.
    private func locate(_ name: String) -> URL? {
        if let bundled = Self.bundledTool(name) {
            if fileManager.isExecutableFile(atPath: bundled.path) { return bundled }
            // Ging das Ausführungsrecht verloren, eine ausführbare Kopie anlegen.
            if let copy = try? copyToSupport(bundled, name: name) { return copy }
        }
        return systemTool(name)
    }

    private func systemTool(_ name: String) -> URL? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func copyToSupport(_ source: URL, name: String) throws -> URL {
        let directory = try YtDlpInstaller.supportRoot().appendingPathComponent("tools", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        try? fileManager.removeItem(at: target)
        try fileManager.copyItem(at: source, to: target)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        return target
    }

    /// Beendet yt-dlp-Prozesse einer Velvet-Sitzung, die hart beendet wurde (Absturz, Xcode-Stopp, `kill`).
    /// Solche Prozesse hängen nach dem Ende der App direkt an launchd (Elternprozess 1).
    nonisolated static func terminateOrphanedDownloads() async {
        guard let executable = try? YtDlpInstaller.executable(),
              let output = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-axo", "pid=,ppid=,command="], timeout: 10)
        else { return }

        var orphans: [pid_t] = []
        for line in output.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, parts[1] == "1", parts[2].hasPrefix(executable.path), let pid = pid_t(parts[0]) else { continue }
            orphans.append(pid)
        }
        guard !orphans.isEmpty else { return }
        orphans.forEach { kill($0, SIGINT) }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        orphans.filter { kill($0, 0) == 0 }.forEach { kill($0, SIGKILL) }
    }

    // MARK: Versionen

    nonisolated static func version(of tool: URL, arguments: [String]) async throws -> String {
        // Der erste Start von yt-dlp kann dauern, weil macOS die Datei prüft.
        let output = try await ProcessRunner.run(tool, arguments: arguments, timeout: 120)
        guard output.succeeded else {
            let detail = output.timedOut ? "Zeitüberschreitung" : (output.tail.last ?? "Exit-Code \(output.exitCode)")
            throw ToolError.notWorking(tool.lastPathComponent, detail)
        }
        let firstLine = output.stdout.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.trimmingCharacters(in: .whitespaces)
    }

    /// "ffmpeg version 9.0.2-https://…" → "9.0.2", "deno 2.9.8 (stable, …)" → "2.9.8"
    nonisolated static func shortVersion(_ line: String?, prefix: String) -> String? {
        guard var text = line else { return nil }
        if text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        let token = text.split(separator: " ").first.map(String.init) ?? text
        return token.split(separator: "-").first.map(String.init) ?? token
    }
}

/// Vergleicht yt-dlp-Versionen wie "2026.10.26" oder "2026.10.26.123".
enum VersionComparator {
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}
