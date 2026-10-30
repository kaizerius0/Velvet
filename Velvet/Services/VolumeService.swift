import AppKit
import Foundation

/// Erkennt Sticks und externe Laufwerke und wirft sie aus.
enum VolumeService {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeUUIDStringKey, .volumeIsInternalKey,
        .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsBrowsableKey,
        .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ]

    /// Alle eingehängten externen Laufwerke (Sticks, Festplatten, SD-Karten).
    static func externalVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls
            .compactMap(info(forVolume:))
            .filter(\.isExternal)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func info(forVolume url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsBrowsable != false else { return nil }
        let isInternal = values.volumeIsInternal ?? true
        let isExternal = !isInternal || values.volumeIsEjectable == true || values.volumeIsRemovable == true
        return VolumeInfo(
            url: url,
            name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
            uuid: values.volumeUUIDString,
            isExternal: isExternal && url.path != "/",
            fileSystem: values.volumeLocalizedFormatDescription,
            totalBytes: values.volumeTotalCapacity.map(Int64.init),
            availableBytes: values.volumeAvailableCapacity.map(Int64.init)
        )
    }

    /// Das Laufwerk, auf dem eine Datei oder ein Ordner liegt.
    static func volume(containing url: URL) -> VolumeInfo? {
        guard let volumeURL = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return nil }
        return info(forVolume: volumeURL)
    }

    /// Pfad innerhalb des Laufwerks, z. B. „Rock/Toto - Africa.mp3“.
    static func relativePath(of url: URL, in volume: VolumeInfo) -> String {
        let base = volume.url.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return path }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func eject(_ volume: VolumeInfo) async throws {
        let url = volume.url
        try await Task.detached(priority: .userInitiated) {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
        }.value
    }
}
