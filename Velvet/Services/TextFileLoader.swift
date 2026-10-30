import Foundation
import UniformTypeIdentifiers

/// Liest Listen aus Textdateien – auch UTF-16 (Apple-Music-Export) und ältere Windows-Kodierungen.
enum TextFileLoader {
    static let supportedExtensions: Set<String> = ["txt", "text", "md", "markdown", "csv", "tsv", "m3u", "m3u8", "list", "lst"]

    static var contentTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .commaSeparatedText, .tabSeparatedText]
        for ext in ["md", "m3u", "m3u8", "list", "lst"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    enum LoadError: LocalizedError {
        case unsupported(String)
        case tooLarge(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case let .unsupported(name): return "„\(name)“ ist keine Textdatei."
            case let .tooLarge(name): return "„\(name)“ ist zu groß."
            case let .unreadable(name): return "„\(name)“ konnte nicht gelesen werden."
            }
        }
    }

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if supportedExtensions.contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .text) ?? false
    }

    static func load(_ url: URL) throws -> String {
        let name = url.lastPathComponent
        guard isSupported(url) else { throw LoadError.unsupported(name) }
        guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable(name) }
        guard data.count <= 20_000_000 else { throw LoadError.tooLarge(name) }
        if let text = decode(data) { return text }
        throw LoadError.unreadable(name)
    }

    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if let text = String(data: data, encoding: .utf8) { return text }
        // UTF-16 ohne BOM erkennt man an vielen Null-Bytes.
        if data.count >= 4, data.filter({ $0 == 0 }).count > data.count / 4 {
            let zeroAtOdd = bytes.count >= 2 && bytes[1] == 0
            if let text = String(data: data, encoding: zeroAtOdd ? .utf16LittleEndian : .utf16BigEndian) { return text }
        }
        for encoding: String.Encoding in [.windowsCP1252, .isoLatin1, .macOSRoman] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }
}
