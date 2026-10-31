import Foundation

/// Schreibt eine rekordbox-XML-Datei: alle Titel eines Sticks (oder Ordners) mit Tempo und Tonart,
/// jeder Velvet-Ordner als Playlist. rekordbox liest sie unter
/// Einstellungen → Erweitert → Datenbank → „rekordbox xml“ ein.
enum RekordboxExporter {
    struct Entry {
        let url: URL
        let title: String
        let artist: String?
        let size: Int64
        let bpm: Double?
        let key: MusicalKey?
    }

    struct Playlist {
        let name: String
        let entries: [URL]
    }

    static func xml(entries: [Entry], playlists: [Playlist], version: String) -> String {
        var ids: [String: Int] = [:]
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<DJ_PLAYLISTS Version="1.0.0">"#,
            #"  <PRODUCT Name="Velvet" Version="\#(escape(version))" Company="Velvet"/>"#,
            #"  <COLLECTION Entries="\#(entries.count)">"#,
        ]
        for (index, entry) in entries.enumerated() {
            let id = index + 1
            ids[entry.url.standardizedFileURL.path] = id
            var attributes = [
                ("TrackID", "\(id)"),
                ("Name", entry.title),
                ("Artist", entry.artist ?? ""),
                ("Kind", kind(of: entry.url)),
                ("Size", "\(entry.size)"),
                ("Location", location(of: entry.url)),
            ]
            if let bpm = entry.bpm { attributes.append(("AverageBpm", String(format: "%.2f", bpm))) }
            if let key = entry.key { attributes.append(("Tonality", key.name)) }
            let text = attributes.map { "\($0.0)=\"\(escape($0.1))\"" }.joined(separator: " ")
            lines.append("    <TRACK \(text)/>")
        }
        lines.append("  </COLLECTION>")
        lines.append("  <PLAYLISTS>")
        lines.append(#"    <NODE Type="0" Name="ROOT" Count="\#(playlists.count)">"#)
        for playlist in playlists {
            let keys = playlist.entries.compactMap { ids[$0.standardizedFileURL.path] }
            lines.append(#"      <NODE Name="\#(escape(playlist.name))" Type="1" KeyType="0" Entries="\#(keys.count)">"#)
            lines += keys.map { #"        <TRACK Key="\#($0)"/>"# }
            lines.append("      </NODE>")
        }
        lines.append("    </NODE>")
        lines.append("  </PLAYLISTS>")
        lines.append("</DJ_PLAYLISTS>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// „file://localhost/Volumes/STICK/House/Track%20Name.mp3“ – so erwartet rekordbox die Pfade.
    static func location(of url: URL) -> String {
        let absolute = url.standardizedFileURL.absoluteString
        guard absolute.hasPrefix("file:///") else { return absolute }
        return "file://localhost/" + absolute.dropFirst("file:///".count)
    }

    private static func kind(of url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "MP3 File"
        case "m4a", "aac": return "M4A File"
        case "wav": return "WAV File"
        case "aif", "aiff": return "AIFF File"
        case "flac": return "FLAC File"
        default: return "\(url.pathExtension.uppercased()) File"
        }
    }

    private static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                // Steuerzeichen sind in XML 1.0 nicht erlaubt.
                if let scalar = character.unicodeScalars.first, scalar.value < 0x20, character != "\t" { continue }
                result.append(character)
            }
        }
        return result
    }
}
