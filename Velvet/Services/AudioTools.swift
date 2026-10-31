import Foundation

/// Dekodiert Audiodateien mit ffmpeg zu Rohdaten (mono, 11 025 Hz, 32-Bit-Float) für `AudioAnalyzer`.
enum AudioDecoder {
    enum DecodeError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(detail): return "Die Audiodatei konnte nicht gelesen werden: \(detail)"
            }
        }
    }

    /// Liest bis zu `duration` Sekunden ab `start`.
    static func samples(of file: URL, ffmpeg: URL, start: Double = 0, duration: Double = 420) async throws -> [Float] {
        let arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin",
            "-ss", String(format: "%.2f", start),
            "-t", String(format: "%.2f", duration),
            "-i", file.path,
            "-vn", "-ac", "1", "-ar", "\(Int(AudioAnalyzer.sampleRate))",
            "-f", "f32le", "-",
        ]
        let data = try await BinaryRunner.run(ffmpeg, arguments: arguments, timeout: 120)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Schreibt Tempo und Tonart als ID3-Tags (TBPM, TKEY) in eine MP3 – Cover und übrige Tags bleiben.
enum TagWriter {
    static func canWrite(_ file: URL) -> Bool {
        file.pathExtension.lowercased() == "mp3"
    }

    static func write(bpm: Double?, key: MusicalKey?, to file: URL, ffmpeg: URL) async throws {
        guard canWrite(file), bpm != nil || key != nil else { return }
        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".velvet-tags-\(UUID().uuidString.prefix(8)).mp3")
        var arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-i", file.path,
            "-map", "0", "-c", "copy", "-map_metadata", "0",
            "-id3v2_version", "3", "-write_id3v1", "0",
        ]
        if let bpm { arguments += ["-metadata", "TBPM=\(Int(bpm.rounded()))"] }
        if let key { arguments += ["-metadata", "TKEY=\(key.name)"] }
        arguments.append(temporary.path)

        // Datum bleibt, damit „Hinzugefügt“ in der Bibliothek stimmt.
        let dates = (try? FileManager.default.attributesOfItem(atPath: file.path))
            .map { $0.filter { $0.key == .creationDate || $0.key == .modificationDate } } ?? [:]
        do {
            _ = try await BinaryRunner.run(ffmpeg, arguments: arguments, timeout: 120)
            let fileManager = FileManager.default
            let size = ((try? fileManager.attributesOfItem(atPath: temporary.path))?[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 1000 else { throw AudioDecoder.DecodeError.failed("leere Ausgabe") }
            // Auf Sticks (FAT32/exFAT) klappt „replaceItemAt“ nicht immer – dann löschen und verschieben.
            do {
                _ = try fileManager.replaceItemAt(file, withItemAt: temporary)
            } catch {
                try fileManager.removeItem(at: file)
                try fileManager.moveItem(at: temporary, to: file)
            }
            if !dates.isEmpty { try? fileManager.setAttributes(dates, ofItemAtPath: file.path) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

/// Liest die wichtigsten ID3v2-Textfelder (TBPM, TKEY) einer MP3 – schnell, ohne ffmpeg.
enum ID3Reader {
    struct Tags: Equatable {
        var bpm: Double?
        var key: MusicalKey?
    }

    /// Liest nur die Rahmenköpfe und springt über alles andere (z. B. das Cover) – schnell auch auf Sticks.
    static func tags(of file: URL) -> Tags? {
        guard file.pathExtension.lowercased() == "mp3", let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 10), header.count == 10 else { return nil }
        let bytes = [UInt8](header)
        guard bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33, bytes[3] == 3 || bytes[3] == 4,
              bytes[5] & 0x40 == 0 else {
            // Ohne Standardkopf (selten): den Anfang am Stück lesen.
            guard let body = try? handle.read(upToCount: 64_000) else { return nil }
            return parse(header: header, body: body)
        }
        let isV4 = bytes[3] == 4
        let end = 10 + syncsafe(header, at: 6)
        var offset = 10
        var tags = Tags()
        while offset + 10 <= end, tags.bpm == nil || tags.key == nil {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let frameHeader = try? handle.read(upToCount: 10), frameHeader.count == 10 else { break }
            let frame = [UInt8](frameHeader)
            guard frame[0...3].allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }) else { break }
            let id = String(decoding: frame[0...3], as: UTF8.self)
            let length = isV4 ? syncsafe(frameHeader, at: 4) : Int(bigEndian: frame, at: 4)
            guard length > 0, offset + 10 + length <= end else { break }
            if (id == "TBPM" || id == "TKEY"), length < 200, let payload = try? handle.read(upToCount: length),
               let text = decodeText([UInt8](payload)) {
                if id == "TBPM", let value = Double(text.replacingOccurrences(of: ",", with: ".")), value > 30, value < 300 {
                    tags.bpm = value
                } else if id == "TKEY" {
                    tags.key = MusicalKey.parse(text)
                }
            }
            offset += 10 + length
        }
        return tags.bpm == nil && tags.key == nil ? nil : tags
    }

    static func parse(header: Data, body: Data) -> Tags? {
        let bytes = [UInt8](header)
        guard bytes.count == 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return nil }  // "ID3"
        let version = bytes[3]
        guard version == 3 || version == 4 else { return nil }
        let frames = [UInt8](body)
        var tags = Tags()
        var offset = 0
        // Erweiterter Kopf (selten) überspringen.
        if bytes[5] & 0x40 != 0, frames.count >= 4 {
            let extended = version == 4 ? syncsafe(Data(frames), at: 0) : Int(bigEndian: frames, at: 0) + 4
            offset = min(extended, frames.count)
        }
        while offset + 10 <= frames.count {
            let idBytes = frames[offset..<offset + 4]
            guard idBytes.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }) else { break }
            let id = String(decoding: idBytes, as: UTF8.self)
            let length = version == 4 ? syncsafe(Data(frames), at: offset + 4) : Int(bigEndian: frames, at: offset + 4)
            let start = offset + 10
            guard length > 0, start + length <= frames.count else { break }
            if id == "TBPM" || id == "TKEY", let text = decodeText(Array(frames[start..<start + length])) {
                if id == "TBPM", let value = Double(text.replacingOccurrences(of: ",", with: ".")), value > 30, value < 300 {
                    tags.bpm = value
                } else if id == "TKEY" {
                    tags.key = MusicalKey.parse(text)
                }
            }
            offset = start + length
        }
        return tags.bpm == nil && tags.key == nil ? nil : tags
    }

    private static func decodeText(_ frame: [UInt8]) -> String? {
        guard let encoding = frame.first else { return nil }
        let payload = Data(frame.dropFirst())
        let text: String?
        switch encoding {
        case 0: text = String(data: payload, encoding: .isoLatin1)
        case 1: text = String(data: payload, encoding: .utf16)
        case 2: text = String(data: payload, encoding: .utf16BigEndian)
        default: text = String(data: payload, encoding: .utf8)
        }
        return text?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
    }

    private static func syncsafe(_ data: Data, at index: Int) -> Int {
        let bytes = [UInt8](data)
        guard index + 4 <= bytes.count else { return 0 }
        return (Int(bytes[index]) << 21) | (Int(bytes[index + 1]) << 14) | (Int(bytes[index + 2]) << 7) | Int(bytes[index + 3])
    }
}

private extension Int {
    init(bigEndian bytes: [UInt8], at index: Int) {
        guard index + 4 <= bytes.count else {
            self = 0
            return
        }
        self = (Int(bytes[index]) << 24) | (Int(bytes[index + 1]) << 16) | (Int(bytes[index + 2]) << 8) | Int(bytes[index + 3])
    }
}

// MARK: - Binäre Ausgabe

/// Startet ein Programm und sammelt seine (binäre) Standardausgabe. Abbruch beendet den Prozess.
enum BinaryRunner {
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let buffer = DataBuffer()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let closed = DispatchGroup()
                for (pipe, isOutput) in [(output, true), (errors, false)] {
                    closed.enter()
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                            closed.leave()
                        } else {
                            buffer.append(chunk, isOutput: isOutput)
                        }
                    }
                }
                process.terminationHandler = { finished in
                    DispatchQueue.global(qos: .utility).async {
                        _ = closed.wait(timeout: .now() + 3)
                        RunningProcesses.shared.remove(finished)
                        if finished.terminationStatus == 0 {
                            continuation.resume(returning: buffer.output)
                        } else {
                            continuation.resume(throwing: AudioDecoder.DecodeError.failed(buffer.errorText))
                        }
                    }
                }
                do {
                    try process.run()
                    RunningProcesses.shared.add(process)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning { process.terminate() }
                    }
                } catch {
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private final class DataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()

        func append(_ data: Data, isOutput: Bool) {
            lock.locked {
                if isOutput {
                    stdout.append(data)
                } else if stderr.count < 20_000 {
                    stderr.append(data)
                }
            }
        }

        var output: Data { lock.locked { stdout } }
        var errorText: String {
            lock.locked { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}
