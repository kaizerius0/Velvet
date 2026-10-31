import SwiftUI

/// Der Set-Builder: links Ausgangstitel und Filter, rechts das Set zum Vorhören und Abhaken,
/// unten Zielordner und „Auf den Stick“.
struct SetBuilderView: View {
    @ObservedObject var model: SetBuilderViewModel

    @EnvironmentObject private var discover: DiscoverViewModel
    @EnvironmentObject private var navigation: AppNavigation
    @EnvironmentObject private var library: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                SetOptionsPanel(model: model)
                    .frame(width: 290)
                Divider()
                VStack(spacing: 0) {
                    content
                    Divider()
                    footer
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                discover.closeSet()
            } label: {
                Label("Entdecken", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let progress = model.analysisProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Tempo & Tonart: \(progress.done) von \(progress.total)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .help("Velvet hört kurz in jeden Titel hinein und ermittelt Tempo und Tonart.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        switch model.phase {
        case .findingSeed: return "Ausgangstitel wird gesucht …"
        case let .collecting(text): return text
        case .ready: return "\(model.entries.count) Titel · \(model.selectedEntries.count) ausgewählt · \(totalDuration)"
        case let .failed(message): return message
        }
    }

    private var totalDuration: String {
        let seconds = model.selectedEntries.compactMap(\.candidate.duration).reduce(0, +)
        return Formatters.duration(seconds).map { "\($0) Spielzeit" } ?? "–"
    }

    // MARK: Liste

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .findingSeed, .collecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Velvet sucht passende Titel …")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Zurück zu Entdecken") { discover.closeSet() }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if model.entries.isEmpty {
                VStack(spacing: 10) {
                    if model.analysisProgress != nil {
                        ProgressView()
                        Text("Tempo und Tonart werden geprüft – passende Titel erscheinen gleich.")
                    } else {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("Mit diesen Filtern bleibt nichts übrig. Lockere Tempo, Tonart oder „Nur lange Versionen“.")
                    }
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, suggestion in
                            SetRow(model: model, index: index, suggestion: suggestion)
                            Divider().padding(.leading, 52)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    // MARK: Ziel und Laden

    private var footer: some View {
        HStack(spacing: 12) {
            if let done = model.committed {
                Label("\(Formatters.count(done.count, "Titel wird", "Titel werden")) in „\(library.locationText(forFolder: done.folder))“ geladen",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
                Spacer()
                Button("Zum Ordner") { open(done.folder) }
                Button("Downloads ansehen") { navigation.selection = .add }
            } else {
                targetPicker
                if case .newFolder = model.target {
                    TextField("Name des Ordners", text: $model.folderName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                }
                Spacer()
                Button {
                    if let folder = model.commit() { library.showNotice("Set wird in „\(folder.lastPathComponent)“ geladen") }
                } label: {
                    Text(model.selectedEntries.isEmpty ? "Auf den Stick" : "\(Formatters.count(model.selectedEntries.count, "Titel", "Titel")) auf den Stick")
                        .font(.headline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.selectedEntries.isEmpty || model.phase != .ready)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var targetPicker: some View {
        Menu {
            Section("Neuer Ordner") {
                ForEach(library.sources) { source in
                    Button {
                        model.target = .newFolder(sourceID: source.id)
                    } label: {
                        Label("Neuer Ordner auf „\(source.name)“", systemImage: source.isExternal ? "externaldrive" : "laptopcomputer")
                    }
                }
            }
            ForEach(library.sources) { source in
                let folders = library.folders(in: source.id)
                if !folders.isEmpty {
                    Section(source.name) {
                        ForEach(folders) { folder in
                            Button(folder.name) { model.target = .existing(folder.url) }
                        }
                    }
                }
            }
        } label: {
            Label(targetText, systemImage: targetSymbol)
        }
        .fixedSize()
    }

    private var targetText: String {
        switch model.target {
        case let .existing(url): return "In „\(library.locationText(forFolder: url))“"
        case let .newFolder(sourceID): return "Neuer Ordner auf „\(library.source(id: sourceID)?.name ?? "Dieser Mac")“"
        }
    }

    private var targetSymbol: String {
        switch model.target {
        case let .existing(url): return library.isOnStick(url) ? "externaldrive" : "folder"
        case let .newFolder(sourceID): return library.source(id: sourceID)?.isExternal == true ? "externaldrive.badge.plus" : "folder.badge.plus"
        }
    }

    private func open(_ folder: URL) {
        let id = folder.standardizedFileURL.path
        guard let source = library.source(containing: folder) else { return }
        discover.closeSet()
        navigation.selection = .folder(source: source.id, id: id)
    }
}

// MARK: - Optionen

private struct SetOptionsPanel: View {
    @ObservedObject var model: SetBuilderViewModel
    @EnvironmentObject private var player: PreviewPlayer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                seedCard
                VStack(alignment: .leading, spacing: 6) {
                    Text("Anzahl")
                        .font(.headline)
                    Picker("Anzahl", selection: $model.count) {
                        ForEach(SetBuilderViewModel.countOptions, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Filter")
                        .font(.headline)
                    Toggle("Nur lange Versionen (Extended, Club, Original Mix)", isOn: $model.onlyLong)
                    Toggle("Schon Vorhandenes ausblenden", isOn: $model.hideExisting)
                    Toggle(isOn: $model.matchTempo) {
                        Text(tempoTitle)
                    }
                    .disabled(model.seedAnalysis?.bpm == nil)
                    if model.matchTempo {
                        Stepper(value: $model.tempoTolerance, in: 2...20, step: 1) {
                            Text("± \(Int(model.tempoTolerance)) BPM")
                                .monospacedDigit()
                        }
                        .padding(.leading, 20)
                    }
                    Toggle(isOn: $model.matchKey) {
                        Text(keyTitle)
                    }
                    .disabled(model.seedAnalysis?.key == nil)
                    if model.seedAnalysis == nil {
                        Text(model.isAnalyzingSeed ? "Tempo und Tonart des Ausgangstitels werden ermittelt …" : "Tempo und Tonart des Ausgangstitels sind unbekannt.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reihenfolge")
                        .font(.headline)
                    Picker("Reihenfolge", selection: $model.order) {
                        ForEach(SetBuilderViewModel.Order.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    Text(orderHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Tempo und Tonart sind geschätzt – wie bei jeder Analyse-Software lohnt bei wichtigen Übergängen ein kurzer Check.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
    }

    private var tempoTitle: String {
        if let bpm = model.seedAnalysis?.bpmText { return "Tempo passend (um \(bpm) BPM)" }
        return "Tempo passend"
    }

    private var keyTitle: String {
        if let key = model.seedAnalysis?.key { return "Tonart passend (harmonisch zu \(key.camelot))" }
        return "Tonart passend (harmonisch)"
    }

    private var orderHint: String {
        switch model.order {
        case .recommended: return "Die besten Treffer zuerst."
        case .tempo: return "Vom langsamsten zum schnellsten – ideal zum Aufbauen."
        case .harmonic: return "Jeder Titel passt tonal zum vorherigen (Camelot-Rad)."
        }
    }

    @ViewBuilder
    private var seedCard: some View {
        if let seed = model.seed {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ausgangstitel")
                    .font(.headline)
                Button {
                    player.play(seed)
                } label: {
                    ZStack {
                        Thumbnail(url: seed.thumbnailURL, cornerRadius: 8)
                        Image(systemName: player.isCurrent(seed.id) && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white)
                            .shadow(radius: 3)
                    }
                }
                .buttonStyle(.plain)
                Text(seed.version.song)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Text([seed.version.artist ?? seed.channel, seed.version.mix].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                AnalysisLabel(analysis: model.seedAnalysis, isLoading: model.isAnalyzingSeed)
                if model.alternatives.count > 1 {
                    Menu("Anderer Ausgangstitel") {
                        ForEach(model.alternatives.filter { $0.id != seed.id }) { candidate in
                            Button(candidate.title) { model.useSeed(candidate) }
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        } else if case .folder = model.source {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ausgangspunkt")
                    .font(.headline)
                Text("Die neuesten Titel des Ordners")
                    .foregroundStyle(.secondary)
                AnalysisLabel(analysis: model.seedAnalysis)
            }
        }
    }
}

// MARK: - Zeile

private struct SetRow: View {
    @ObservedObject var model: SetBuilderViewModel
    let index: Int
    let suggestion: Suggestion

    @EnvironmentObject private var player: PreviewPlayer
    @EnvironmentObject private var queue: QueueViewModel
    @State private var isHovering = false

    var body: some View {
        let candidate = suggestion.candidate
        let selected = !model.deselected.contains(suggestion.id)
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { selected }, set: { _ in model.toggle(suggestion) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Button {
                player.play(candidate)
            } label: {
                ZStack {
                    Thumbnail(url: candidate.thumbnailURL, cornerRadius: 4)
                    if isHovering || player.isCurrent(candidate.id) {
                        Color.black.opacity(0.35).clipShape(RoundedRectangle(cornerRadius: 4))
                        if player.isLoading(candidate.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: player.isCurrent(candidate.id) && player.isPlaying ? "pause.fill" : "play.fill")
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 72)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(suggestion.version.song)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    VersionBadges(version: suggestion.version, limit: 2)
                }
                Text([suggestion.version.artist ?? candidate.channel, suggestion.version.mix].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.isExisting(suggestion) {
                Text("Schon da")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let queued = queue.item(forVideo: candidate.id) {
                QueueStatusLabel(item: queued)
                    .font(.caption)
            }
            AnalysisLabel(analysis: model.analyses[suggestion.id], isLoading: model.analyzing.contains(suggestion.id))
                .frame(width: 118, alignment: .trailing)
            Text(candidate.durationText ?? "–")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .opacity(selected ? 1 : 0.45)
        .background(player.isCurrent(candidate.id) ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { SuggestionMenu(candidate: candidate) }
    }
}
