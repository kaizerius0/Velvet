import Foundation

/// Startet externe Programme (yt-dlp, ffmpeg, deno) und liefert deren Ausgabe live und zeilenweise.
enum ProcessRunner {
    enum Stream: Sendable {
        case stdout
        case stderr
    }

    struct Output: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        /// Die letzten Zeilen beider Ausgabekanäle – für Fehlerprotokolle.
        let tail: [String]
        let wasCancelled: Bool
        let timedOut: Bool

        var succeeded: Bool { exitCode == 0 && !wasCancelled && !timedOut }
    }

    enum RunError: LocalizedError {
        case launchFailed(tool: String, reason: String)

        var errorDescription: String? {
            switch self {
            case let .launchFailed(tool, reason):
                return "\(tool) konnte nicht gestartet werden: \(reason)"
            }
        }
    }

    /// Führt `executable` aus. Wird die aufrufende Task abgebrochen, wird auch der Prozess beendet.
    /// - Parameters:
    ///   - collectStdout: Gesamte Standardausgabe sammeln (z. B. für JSON).
    ///   - timeout: Nach so vielen Sekunden wird der Prozess beendet.
    ///   - onLine: Wird für jede vollständige Ausgabezeile aufgerufen (nacheinander, nie parallel).
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        collectStdout: Bool = true,
        timeout: TimeInterval? = nil,
        onLine: (@Sendable (Stream, String) -> Void)? = nil
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let control = ProcessControl(process)
        let collector = OutputCollector(collectStdout: collectStdout, onLine: onLine)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                let streamsClosed = DispatchGroup()
                for (pipe, stream) in [(stdoutPipe, Stream.stdout), (stderrPipe, Stream.stderr)] {
                    streamsClosed.enter()
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if data.isEmpty {
                            handle.readabilityHandler = nil
                            streamsClosed.leave()
                        } else {
                            collector.append(data, from: stream)
                        }
                    }
                }

                process.terminationHandler = { finished in
                    DispatchQueue.global(qos: .utility).async {
                        // Kindprozesse (z. B. ffmpeg) können die Pipes noch offen halten – nicht ewig warten.
                        _ = streamsClosed.wait(timeout: .now() + 3)
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        collector.finish()
                        RunningProcesses.shared.remove(finished)
                        continuation.resume(returning: Output(
                            exitCode: finished.terminationStatus,
                            stdout: collector.stdoutText,
                            stderr: collector.stderrText,
                            tail: collector.tail,
                            wasCancelled: control.isCancelled,
                            timedOut: control.isTimedOut
                        ))
                    }
                }

                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: RunError.launchFailed(
                        tool: executable.lastPathComponent,
                        reason: error.localizedDescription
                    ))
                    return
                }

                RunningProcesses.shared.add(process)
                control.didLaunch()
                if let timeout { control.scheduleTimeout(after: timeout) }
            }
        } onCancel: {
            control.cancel()
        }
    }
}

// MARK: - Prozesssteuerung

/// Beendet einen Prozess sanft (SIGINT → SIGTERM → SIGKILL), damit yt-dlp aufräumen kann.
private final class ProcessControl: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var launched = false
    private var cancelled = false
    private var timedOut = false

    init(_ process: Process) {
        self.process = process
    }

    var isCancelled: Bool { lock.locked { cancelled } }
    var isTimedOut: Bool { lock.locked { timedOut } }

    func didLaunch() {
        let shouldStop = lock.locked { () -> Bool in
            launched = true
            return cancelled
        }
        if shouldStop { stop() }
    }

    func cancel() {
        let isLaunched = lock.locked { () -> Bool in
            cancelled = true
            return launched
        }
        if isLaunched { stop() }
    }

    func scheduleTimeout(after seconds: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.lock.locked { self.timedOut = true }
            self.stop()
        }
    }

    private func stop() {
        guard process.isRunning else { return }
        let process = process
        let pid = process.processIdentifier
        process.interrupt()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

// MARK: - Ausgabe sammeln

/// Zerlegt die Ausgabe in Zeilen (bei \n und \r) und merkt sich die letzten Zeilen.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let collectStdout: Bool
    private let onLine: (@Sendable (ProcessRunner.Stream, String) -> Void)?
    private var pending: [ProcessRunner.Stream: Data] = [.stdout: Data(), .stderr: Data()]
    private var stdoutData = Data()
    private var stderrData = Data()
    private var tailLines: [String] = []
    private let tailLimit = 250
    private let stderrLimit = 2_000_000

    init(collectStdout: Bool, onLine: (@Sendable (ProcessRunner.Stream, String) -> Void)?) {
        self.collectStdout = collectStdout
        self.onLine = onLine
    }

    var stdoutText: String { lock.locked { String(decoding: stdoutData, as: UTF8.self) } }
    var stderrText: String { lock.locked { String(decoding: stderrData, as: UTF8.self) } }
    var tail: [String] { lock.locked { tailLines } }

    func append(_ data: Data, from stream: ProcessRunner.Stream) {
        lock.locked {
            switch stream {
            case .stdout:
                if collectStdout { stdoutData.append(data) }
                // Große JSON-Ausgaben ohne Zeilen-Callback nicht unnötig zerlegen.
                guard onLine != nil || !collectStdout else { return }
            case .stderr:
                if stderrData.count < stderrLimit { stderrData.append(data) }
            }
            var buffer = pending[stream, default: Data()]
            buffer.append(data)
            while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                emit(line, from: stream)
            }
            pending[stream] = buffer
        }
    }

    func finish() {
        lock.locked {
            for (stream, rest) in pending where !rest.isEmpty {
                emit(rest, from: stream)
            }
            pending = [:]
        }
    }

    /// Muss innerhalb des Locks aufgerufen werden.
    private func emit(_ data: Data, from stream: ProcessRunner.Stream) {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        tailLines.append(line)
        if tailLines.count > tailLimit { tailLines.removeFirst(tailLines.count - tailLimit) }
        onLine?(stream, line)
    }
}

// MARK: - Laufende Prozesse

/// Merkt sich alle laufenden Prozesse, damit sie beim Beenden der App nicht weiterlaufen.
final class RunningProcesses: @unchecked Sendable {
    static let shared = RunningProcesses()

    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func add(_ process: Process) {
        lock.locked { processes[ObjectIdentifier(process)] = process }
    }

    func remove(_ process: Process) {
        lock.locked { _ = processes.removeValue(forKey: ObjectIdentifier(process)) }
    }

    var isEmpty: Bool {
        lock.locked { processes.isEmpty }
    }

    func terminateAll() {
        let running = lock.locked { Array(processes.values) }
        for process in running where process.isRunning {
            process.terminate()
        }
    }
}

extension NSLock {
    @discardableResult
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
