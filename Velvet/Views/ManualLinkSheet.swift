import AppKit
import SwiftUI

/// Falls alle Vorschläge falsch sind: den richtigen Link selbst eingeben.
struct ManualLinkSheet: View {
    @ObservedObject var item: DownloadItem
    let onSubmit: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Eigenen Link eingeben", systemImage: "link")
                .font(.title3.weight(.semibold))

            Text("Für „\(item.displayTitle)“ – füge den Link zum richtigen Video ein.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://www.youtube.com/watch?v=…", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Aus Zwischenablage einfügen") {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        text = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                        error = nil
                    }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Laden", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            // Liegt schon ein Link in der Zwischenablage, gleich vorschlagen.
            if let clip = NSPasteboard.general.string(forType: .string), ListParser.link(from: clip) != nil {
                text = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func submit() {
        guard let url = ListParser.link(from: text) else {
            error = "Das sieht nicht wie ein gültiger Link aus."
            return
        }
        if YouTubeLink.isPlaylist(url) || YouTubeLink.isChannel(url) {
            error = "Bitte den Link zu einem einzelnen Video eingeben (keine Playlist und kein Kanal)."
            return
        }
        onSubmit(url)
        dismiss()
    }
}
