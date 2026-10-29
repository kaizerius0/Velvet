import SwiftUI

enum Theme {
    static let cornerRadius: CGFloat = 12
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let deepVelvet = Color(red: 0.29, green: 0.05, blue: 0.18)

    static var velvetGradient: LinearGradient {
        LinearGradient(colors: [.accentColor, deepVelvet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Weiße bzw. dunkle Karte mit feinem Rand.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Theme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border.opacity(0.6)))
    }
}

struct SectionTitle: View {
    let title: String
    let systemImage: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct LogoMark: View {
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27)
            .fill(Theme.velvetGradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            )
            .shadow(color: Theme.deepVelvet.opacity(0.25), radius: 3, y: 1)
    }
}

/// Vorschaubild im 16:9-Format mit Platzhalter.
struct Thumbnail: View {
    let url: URL?
    var placeholderSymbol = "play.rectangle"
    var cornerRadius: CGFloat = 6

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if phase.error != nil {
                            placeholder
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        Image(systemName: placeholderSymbol)
            .font(.title2)
            .foregroundStyle(.secondary)
    }
}

/// Kleine Kennzahl für die Zusammenfassung.
struct StatPill: View {
    let value: Int
    let title: String
    let color: Color
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.1)))
    }
}

extension View {
    /// Hinweisleiste in Akzentfarbe (oder einer anderen Farbe).
    func bannerStyle(_ color: Color = .accentColor) -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.35)))
    }
}
