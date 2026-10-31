import AVFoundation
import AppKit
import Combine
import Foundation

/// Vorhören direkt in Velvet: Vorschläge (ab etwa einem Drittel, wo der Titel meist losgeht)
/// und Titel aus der Bibliothek. Leertaste = Abspielen/Pause, solange kein Textfeld aktiv ist.
@MainActor
final class PreviewPlayer: ObservableObject {
    struct Item: Equatable {
        let id: String
        let title: String
        let subtitle: String?
        let artwork: URL?
        let candidate: VideoCandidate?
        let file: URL?
    }

    enum Phase: Equatable {
        case idle
        case loading(Double?)
        case playing
        case paused
        case failed(String)
    }

    @Published private(set) var item: Item?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval?

    /// Wird einmal gemeldet, wenn ein Vorschlag mindestens 30 Sekunden lief (für den Geschmack).
    var onListened: ((VideoCandidate) -> Void)?

    private let tools: ToolManager
    private let settings: AppSettings
    private let cache: PreviewCache
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: AnyCancellable?
    private var loadTask: Task<Void, Never>?
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    private var listened: TimeInterval = 0
    private var reportedListen = false
    private var keyMonitor: Any?

    init(tools: ToolManager, settings: AppSettings, cache: PreviewCache = .shared) {
        self.tools = tools
        self.settings = settings
        self.cache = cache
        installKeyMonitor()
    }

    var isActive: Bool { item != nil }
    var isPlaying: Bool { phase == .playing }

    func isCurrent(_ id: String) -> Bool { item?.id == id }

    func isLoading(_ id: String) -> Bool {
        guard item?.id == id, case .loading = phase else { return false }
        return true
    }

    // MARK: Abspielen

    /// Vorschlag vorhören. Ist er schon dran, wird pausiert bzw. fortgesetzt.
    func play(_ candidate: VideoCandidate) {
        if item?.id == candidate.id, phase != .idle {
            togglePlayPause()
            return
        }
        let version = candidate.version
        start(Item(
            id: candidate.id,
            title: version.artist.map { "\($0) – \(version.song)" } ?? candidate.title,
            subtitle: [version.mix, candidate.channel].compactMap { $0 }.joined(separator: " · "),
            artwork: candidate.thumbnailURL,
            candidate: candidate,
            file: nil
        ))
        guard let manager = tools.downloadManager else {
            phase = .failed("Die Werkzeuge sind noch nicht bereit.")
            return
        }
        let cookies = settings.cookieBrowser
        let id = candidate.id
        phase = .loading(cache.cachedFile(for: id) == nil ? 0 : nil)
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.showLoading(fraction, for: id) }
        }
        loadTask = Task { [weak self, cache] in
            do {
                let file = try await cache.file(for: candidate, manager: manager, cookies: cookies, onProgress: report)
                guard let self, !Task.isCancelled, self.item?.id == id else { return }
                await self.open(file, startAt: { duration in Self.previewStart(for: duration) })
            } catch {
                guard let self, !(error is CancellationError), self.item?.id == id else { return }
                self.phase = .failed((error as? DownloadFailure)?.message ?? error.localizedDescription)
            }
        }
    }

    private func showLoading(_ fraction: Double, for id: String) {
        guard item?.id == id, case .loading = phase else { return }
        phase = .loading(fraction)
    }

    /// Ein Titel aus der Bibliothek – von Anfang an.
    func play(file: URL, title: String, subtitle: String?) {
        if item?.id == file.path, phase != .idle {
            togglePlayPause()
            return
        }
        start(Item(id: file.path, title: title, subtitle: subtitle, artwork: nil, candidate: nil, file: file))
        loadTask = Task { [weak self] in
            await self?.open(file, startAt: { _ in 0 })
        }
    }

    /// Vorschau schon laden, bevor geklickt wird (z. B. beim Drüberfahren).
    func prefetch(_ candidate: VideoCandidate) {
        guard prefetchTasks[candidate.id] == nil, cache.cachedFile(for: candidate.id) == nil,
              let manager = tools.downloadManager else { return }
        let cookies = settings.cookieBrowser
        let id = candidate.id
        prefetchTasks[id] = Task { [weak self, cache] in
            _ = try? await cache.file(for: candidate, manager: manager, cookies: cookies)
            self?.prefetchTasks[id] = nil
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        switch phase {
        case .playing:
            player.pause()
            phase = .paused
        case .paused:
            player.play()
            phase = .playing
        default:
            break
        }
    }

    func skip(by seconds: TimeInterval) {
        seek(to: position + seconds)
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let upper = max((duration ?? seconds) - 1, 0)
        let target = min(max(seconds, 0), upper)
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        tearDownPlayer()
        item = nil
        phase = .idle
        position = 0
        duration = nil
    }

    // MARK: Intern

    /// Wo eine Vorschau beginnt: bei etwa 30 % – bei Extended Mixes nach dem Intro, bei Pop-Songs vorm Refrain.
    nonisolated static func previewStart(for duration: TimeInterval?) -> TimeInterval {
        guard let duration, duration > 90 else { return 0 }
        return min(duration * 0.3, duration - 45)
    }

    private func start(_ next: Item) {
        loadTask?.cancel()
        tearDownPlayer()
        item = next
        position = 0
        duration = next.candidate?.duration
        listened = 0
        reportedListen = false
        phase = .loading(nil)
    }

    private func open(_ file: URL, startAt: (TimeInterval?) -> TimeInterval) async {
        let asset = AVURLAsset(url: file)
        let loaded = try? await asset.load(.duration)
        guard !Task.isCancelled else { return }
        if let loaded, loaded.isNumeric, loaded.seconds > 0 { duration = loaded.seconds }

        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        let begin = startAt(duration)
        if begin > 0 {
            await player.seek(to: CMTime(seconds: begin, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        guard !Task.isCancelled, self.player === player else { return }
        position = begin
        observe(player)
        player.play()
        phase = .playing
    }

    private func observe(_ player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.player === player else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                if self.phase == .playing {
                    self.listened += 0.25
                    if !self.reportedListen, self.listened >= 30, let candidate = self.item?.candidate {
                        self.reportedListen = true
                        self.onListened?(candidate)
                    }
                }
                self.position = seconds
            }
        }
        statusObservation = NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.player === player else { return }
                self.phase = .paused
                self.seek(to: 0)
            }
    }

    private func tearDownPlayer() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        player?.pause()
        player = nil
    }

    /// Leertaste spielt/pausiert – außer beim Tippen in einem Textfeld.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            let isTyping = NSApp.keyWindow?.firstResponder is NSText
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, !isTyping, self.item != nil else { return false }
                self.togglePlayPause()
                return true
            }
            return handled ? nil : event
        }
    }
}
