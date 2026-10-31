import Foundation

/// Eine Tonart – mit Camelot-Schreibweise („8A“ = a-Moll), wie DJs sie zum harmonischen Mixen nutzen.
struct MusicalKey: Hashable, Codable, Sendable {
    /// 0 = C, 1 = C#/Db … 11 = B
    let pitchClass: Int
    let isMinor: Bool

    init(pitchClass: Int, isMinor: Bool) {
        self.pitchClass = ((pitchClass % 12) + 12) % 12
        self.isMinor = isMinor
    }

    private static let majorNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    private static let minorNames = ["Cm", "C#m", "Dm", "Ebm", "Em", "Fm", "F#m", "Gm", "G#m", "Am", "Bbm", "Bm"]

    /// „Am“, „F#“, „Ebm“
    var name: String {
        isMinor ? Self.minorNames[pitchClass] : Self.majorNames[pitchClass]
    }

    /// Zahl auf dem Camelot-Rad (1–12). C-Dur und a-Moll sind beide 8.
    var camelotNumber: Int {
        let majorPitch = isMinor ? (pitchClass + 3) % 12 : pitchClass
        return ((majorPitch * 7) % 12 + 7) % 12 + 1
    }

    /// „8A“ (Moll) oder „8B“ (Dur)
    var camelot: String { "\(camelotNumber)\(isMinor ? "A" : "B")" }

    /// „8A · Am“
    var displayText: String { "\(camelot) · \(name)" }

    // MARK: Harmonisch mixen

    /// Schritte auf dem Camelot-Rad: gleiche Tonart 0, Nachbar oder Paralleltonart 1 …
    func distance(to other: MusicalKey) -> Int {
        let diff = abs(camelotNumber - other.camelotNumber)
        let around = min(diff, 12 - diff)
        return around + (isMinor == other.isMinor ? 0 : 1)
    }

    /// Passt harmonisch: gleiche Tonart, ±1 auf dem Rad oder die Paralleltonart (8A ↔ 8B).
    func isCompatible(with other: MusicalKey) -> Bool {
        let diff = abs(camelotNumber - other.camelotNumber)
        let around = min(diff, 12 - diff)
        if isMinor == other.isMinor { return around <= 1 }
        return around == 0
    }

    // MARK: Lesen

    /// Versteht „8A“, „08B“, „Am“, „A minor“, „F#m“, „Gbm“, „C“, „Bb major“, „a-Moll“.
    static func parse(_ text: String) -> MusicalKey? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let key = camelot(trimmed) { return key }

        var lower = trimmed.lowercased()
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")
        lower = lower.replacingOccurrences(of: "-moll", with: "m").replacingOccurrences(of: "-dur", with: "")
        lower = lower.replacingOccurrences(of: " minor", with: "m").replacingOccurrences(of: " min", with: "m")
        lower = lower.replacingOccurrences(of: " major", with: "").replacingOccurrences(of: " maj", with: "")
        lower = lower.replacingOccurrences(of: " ", with: "")

        let letters: [Character: Int] = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11, "h": 11]
        guard let first = lower.first, let base = letters[first] else { return nil }
        var rest = lower.dropFirst()
        var pitch = base
        if rest.first == "#" {
            pitch += 1
            rest = rest.dropFirst()
        } else if rest.first == "b" {
            pitch -= 1
            rest = rest.dropFirst()
        }
        let isMinor: Bool
        switch rest {
        case "": isMinor = false
        case "m", "min", "moll": isMinor = true
        default: return nil
        }
        return MusicalKey(pitchClass: pitch, isMinor: isMinor)
    }

    private static func camelot(_ text: String) -> MusicalKey? {
        let upper = text.uppercased()
        guard let letter = upper.last, letter == "A" || letter == "B",
              let number = Int(upper.dropLast()), (1...12).contains(number) else { return nil }
        let isMinor = letter == "A"
        // Camelot-Zahl zurück in die Dur-Tonart: 8 → C, 9 → G …
        let majorPitch = ((number - 8) * 7 % 12 + 12) % 12
        let pitch = isMinor ? (majorPitch + 9) % 12 : majorPitch
        return MusicalKey(pitchClass: pitch, isMinor: isMinor)
    }
}
