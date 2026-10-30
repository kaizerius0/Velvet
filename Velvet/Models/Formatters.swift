import Foundation

/// Deutsche Formatierung für Dauer, Größe, Geschwindigkeit und Aufrufe.
enum Formatters {
    static let locale = Locale(identifier: "de_DE")

    /// 215 → „3:35“, 3725 → „1:02:05“
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    static func bytes(_ count: Int64) -> String {
        byteFormatter.string(fromByteCount: max(count, 0))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// „Heute, 14:05“ / „12.03.2026, 09:30“
    static func dateTime(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    /// „Heute“ / „12.03.2026“
    static func date(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    static func speed(_ bytesPerSecond: Double?) -> String? {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond > 0 else { return nil }
        return byteFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    static func eta(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 1 else { return nil }
        return duration(seconds).map { "noch \($0)" }
    }

    static func progressDetail(speed: Double?, eta: Double?) -> String? {
        let parts = [Self.speed(speed), Self.eta(eta)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down))) %"
    }

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    /// 1_234_567 → „1,2 Mio. Aufrufe“, 34_567 → „34.567 Aufrufe“
    static func views(_ count: Int?) -> String? {
        guard let count, count >= 0 else { return nil }
        let value = Double(count)
        let number: String
        switch value {
        case 1_000_000_000...:
            number = (decimalFormatter.string(from: NSNumber(value: value / 1_000_000_000)) ?? "") + " Mrd."
        case 1_000_000...:
            number = (decimalFormatter.string(from: NSNumber(value: value / 1_000_000)) ?? "") + " Mio."
        default:
            number = decimalFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        }
        return count == 1 ? "1 Aufruf" : "\(number) Aufrufe"
    }

    /// „1 Eintrag“ / „3 Einträge“
    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }
}
