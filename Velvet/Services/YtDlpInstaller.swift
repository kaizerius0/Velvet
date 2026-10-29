import CryptoKit
import Foundation

/// Installiert und aktualisiert yt-dlp in `~/Library/Application Support/Velvet/yt-dlp`.
///
/// Velvet nutzt das offizielle `yt-dlp_macos.zip` (entpackter Ordner): Es startet in ~0,2 s,
/// die Einzeldatei `yt-dlp_macos` braucht dagegen bei jedem Aufruf ~7 s zum Entpacken.
/// Weil sich die Ordner-Variante nicht selbst aktualisieren kann, übernimmt Velvet das:
/// Download von GitHub → SHA-256 prüfen → entpacken → testen → austauschen.
enum YtDlpInstaller {
    static let assetName = "yt-dlp_macos.zip"
    static let executableName = "yt-dlp_macos"
    private static let releases = "https://github.com/yt-dlp/yt-dlp/releases"

    enum InstallError: LocalizedError {
        case unpackFailed(String)
        case notWorking(String)
        case checksumMissing
        case checksumMismatch
        case noReleaseFound

        var errorDescription: String? {
            switch self {
            case let .unpackFailed(detail): return "yt-dlp konnte nicht entpackt werden: \(detail)"
            case let .notWorking(detail): return "Das neue yt-dlp startet nicht: \(detail)"
            case .checksumMissing: return "Für das yt-dlp-Update gibt es keine Prüfsumme."
            case .checksumMismatch: return "Die Prüfsumme des yt-dlp-Updates stimmt nicht – Download verworfen."
            case .noReleaseFound: return "Die aktuelle yt-dlp-Version konnte nicht ermittelt werden."
            }
        }
    }

    // MARK: Orte

    static func supportRoot() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = base.appendingPathComponent("Velvet", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func installDirectory() throws -> URL {
        try supportRoot().appendingPathComponent("yt-dlp", isDirectory: true)
    }

    static func executable() throws -> URL {
        try installDirectory().appendingPathComponent(executableName)
    }

    private static func versionFile() throws -> URL {
        try supportRoot().appendingPathComponent("yt-dlp.version")
    }

    static var installedVersion: String? {
        (try? versionFile()).flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func writeInstalledVersion(_ version: String) {
        guard let file = try? versionFile() else { return }
        try? version.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: Installieren

    /// Installationen und Updates laufen nacheinander, nie gleichzeitig.
    private static let lock = AsyncLock()

    /// Installiert das gebündelte Archiv, wenn yt-dlp fehlt, `force` gesetzt ist oder das Bundle neuer ist.
    static func installIfNeeded(archive: URL, bundledVersion: String?, force: Bool) async throws {
        await lock.acquire()
        do {
            let installed = installedVersion
            var needed = force || installed == nil
            if let executable = try? executable(), !FileManager.default.isExecutableFile(atPath: executable.path) {
                needed = true
            }
            if let bundledVersion, let installed, VersionComparator.isNewer(bundledVersion, than: installed) {
                needed = true
            }
            if needed { try await unlockedInstall(archive: archive) }
            await lock.release()
        } catch {
            await lock.release()
            throw error
        }
    }

    /// Entpackt `archive`, prüft das Ergebnis und ersetzt erst dann die bisherige Installation.
    @discardableResult
    static func install(archive: URL) async throws -> String {
        await lock.acquire()
        do {
            let version = try await unlockedInstall(archive: archive)
            await lock.release()
            return version
        } catch {
            await lock.release()
            throw error
        }
    }
    /// - Returns: Die Version, die `yt-dlp --version` meldet.
    @discardableResult
    private static func unlockedInstall(archive: URL) async throws -> String {
        let fileManager = FileManager.default
        let root = try supportRoot()
        let staging = root.appendingPathComponent("yt-dlp.staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        let unpack = try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, staging.path],
            timeout: 180
        )
        guard unpack.succeeded else {
            throw InstallError.unpackFailed(unpack.tail.last ?? "Exit-Code \(unpack.exitCode)")
        }
        let candidate = staging.appendingPathComponent(executableName)
        guard fileManager.isExecutableFile(atPath: candidate.path) else {
            throw InstallError.unpackFailed("\(executableName) fehlt im Archiv")
        }

        // Der erste Start dauert einige Sekunden, weil macOS die Dateien einmalig prüft.
        let check = try await ProcessRunner.run(candidate, arguments: ["--version"], timeout: 180)
        guard check.succeeded else {
            throw InstallError.notWorking(check.timedOut ? "Zeitüberschreitung" : (check.tail.last ?? "Exit-Code \(check.exitCode)"))
        }
        let version = check.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let target = try installDirectory()
        if fileManager.fileExists(atPath: target.path) {
            // Laufende yt-dlp-Prozesse dürfen ihre Dateien behalten – die alte Kopie wird später entfernt.
            let old = root.appendingPathComponent("yt-dlp.old-\(UUID().uuidString)", isDirectory: true)
            try fileManager.moveItem(at: target, to: old)
            if RunningProcesses.shared.isEmpty { try? fileManager.removeItem(at: old) }
        }
        try fileManager.moveItem(at: staging, to: target)
        writeInstalledVersion(version)
        return version
    }

    /// Räumt Reste abgebrochener Installationen und alte Kopien auf.
    /// Nur was älter als zehn Minuten ist – eine gerade laufende Installation bleibt unberührt.
    static func removeLeftovers() {
        guard let root = try? supportRoot(),
              let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-10 * 60)
        for url in contents where url.lastPathComponent.hasPrefix("yt-dlp.old-") || url.lastPathComponent.hasPrefix("yt-dlp.staging-") {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? FileManager.default.removeItem(at: url) }
        }
        // Frühere Velvet-Versionen nutzten die Einzeldatei in bin/.
        try? FileManager.default.removeItem(at: root.appendingPathComponent("bin", isDirectory: true))
    }

    // MARK: Aktualisieren

    /// Ermittelt die neueste stabile Version über die Weiterleitung von `releases/latest`.
    static func latestVersion() async throws -> String {
        var request = URLRequest(url: URL(string: "\(releases)/latest")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let url = response.url, url.pathComponents.contains("tag") else { throw InstallError.noReleaseFound }
        let tag = url.lastPathComponent
        guard !tag.isEmpty, tag != "latest" else { throw InstallError.noReleaseFound }
        return tag
    }

    /// Lädt die Version `tag`, prüft die SHA-256-Summe und installiert sie.
    @discardableResult
    static func update(to tag: String) async throws -> String {
        let base = "\(releases)/download/\(tag)"
        let (sumsData, _) = try await URLSession.shared.data(from: URL(string: "\(base)/SHA2-256SUMS")!)
        guard let expected = checksum(for: assetName, in: String(decoding: sumsData, as: UTF8.self)) else {
            throw InstallError.checksumMissing
        }

        let (downloaded, _) = try await URLSession.shared.download(from: URL(string: "\(base)/\(assetName)")!)
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("velvet-\(UUID().uuidString)-\(assetName)")
        try FileManager.default.moveItem(at: downloaded, to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }

        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw InstallError.checksumMismatch }

        return try await install(archive: archive)
    }

    /// Sucht in einer `SHA2-256SUMS`-Datei („<hash>  <datei>“) die Summe für `file`.
    static func checksum(for file: String, in sums: String) -> String? {
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, parts[1] == file {
                return String(parts[0])
            }
        }
        return nil
    }
}

/// Einfache asynchrone Sperre: Wer `acquire()` aufruft, wartet, bis der Vorgänger `release()` gemeldet hat.
actor AsyncLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
