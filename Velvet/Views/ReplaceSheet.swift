import SwiftUI

/// Einen Titel gegen eine andere Version tauschen – z. B. die Extended Version.
struct ReplaceSheet: View {
    @ObservedObject var model: ReplaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    private let columns = Array(repeating: GridItem(.flexible(minimum: 120), spacing: 12, alignment: .top), count: DownloadManager.searchPageSize)
    private let refinements = ["Extended", "Original Mix", "Live", "Remix", "Radio Edit", "Lyrics"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("„\(model.track.title)“ austauschen")
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    Text("Liegt in \(model.locationText). Die neue Version kommt in denselben Ordner, die alte wird danach gelöscht.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                TextField("Suchbegriff", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.search)
                Button("Suchen", action: model.search)
                    .disabled(model.isBusy)
            }
            HStack(spacing: 6) {
                Text("Schnell:").font(.caption).foregroundStyle(.secondary)
                ForEach(refinements, id: \.self) { word in
                    Button(word) { model.refine(with: word) }
                        .controlSize(.small)
                        .disabled(model.isBusy)
                }
            }

            content
                .frame(minHeight: 230)

            Divider()

            HStack(spacing: 10) {
                Button {
                    model.loadSuggestions()
                } label: {
                    Label("Andere Vorschläge", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.isBusy)

                TextField("Oder eigenen Link einfügen", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit { model.useLink(link) }
                Button("Laden") { model.useLink(link) }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)

                Spacer()

                if case .done = model.phase {
                    Button("Fertig") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Abbrechen") {
                        model.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(22)
        .frame(width: 960)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .searching:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Suche Versionen …").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noResults:
            Text("Keine (weiteren) Treffer – ändere den Suchbegriff oder füge einen Link ein.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .choosing:
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(model.candidates) { candidate in
                    CandidateCard(candidate: candidate) { model.choose(candidate) }
                }
            }
        case .downloading:
            VStack(alignment: .leading, spacing: 8) {
                Text("Neue Version wird geladen …").font(.headline)
                ProgressView(value: model.progress)
                Text(model.detail ?? "Startet …").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .done(title):
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.green)
                Text("Ausgetauscht").font(.title3.weight(.semibold))
                Text("Jetzt in \(model.locationText): „\(title)“")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                Button("Erneut suchen", action: model.search)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
