import Foundation

/// Commit record for the rebuildable inverted masters. A master is only marked
/// complete after its TIFF has been atomically renamed into the cache.
struct CacheManifest: Codable {
    enum State: String { case absent, complete, incomplete, stale }

    static let version = 4
    var version = Self.version
    var sourceStamp: String
    var settingsStamp: String
    var layout: String
    var perFrameBase: Bool
    var useBorder: Bool
    var externalSources: [String]
    var externalSourceStamp: String
    var expected: [String]
    var completed: [String]
    var finalized = false

    static func url(cache: URL) -> URL {
        cache.appendingPathComponent("manifest.json")
    }

    static func read(cache: URL) -> CacheManifest? {
        guard let data = try? Data(contentsOf: url(cache: cache)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func write(cache: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(cache: cache), options: .atomic)
    }

    /// A cheap change detector for local captures. Paths, byte counts, and file
    /// modification times are included so a changed source invalidates its cache.
    static func stamp(_ urls: [URL]) throws -> String {
        let fm = FileManager.default
        return try urls.sorted { $0.path < $1.path }.map { url in
            let a = try fm.attributesOfItem(atPath: url.path)
            let bytes = a[.size] as? NSNumber ?? 0
            let date = a[.modificationDate] as? Date ?? .distantPast
            return "\(url.standardizedFileURL.path)|\(bytes)|\(date.timeIntervalSince1970)"
        }.joined(separator: "\n")
    }

    /// GUI/open gate. `complete` means every committed master exists and all
    /// capture signatures still match. Settings are validated by `Invert.run`.
    static func status(captures: URL, cache: URL) -> State {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: captures,
                                                      includingPropertiesForKeys: nil),
              let stamp = try? stamp(files.filter(CaptureDecoder.isSupported)) else {
            return .absent
        }
        guard let manifest = read(cache: cache) else {
            let masters = (try? fm.contentsOfDirectory(at: cache,
                                                       includingPropertiesForKeys: nil)) ?? []
            return masters.contains { $0.lastPathComponent.hasSuffix(".ntg.tif") }
                ? .stale : .absent
        }
        guard manifest.version == version, manifest.sourceStamp == stamp else { return .stale }
        let external = manifest.externalSources.map { URL(fileURLWithPath: $0) }
        guard (try? Self.stamp(external)) == manifest.externalSourceStamp else { return .stale }
        let expected = Set(manifest.expected), completed = Set(manifest.completed)
        guard let session = Invert.loadSession(beside: cache) else { return .incomplete }
        guard session.layout == manifest.layout,
              session.perFrameBase == manifest.perFrameBase,
              session.useBorder == manifest.useBorder else { return .stale }
        guard manifest.finalized, !expected.isEmpty,
              expected.isSubset(of: completed),
              expected.allSatisfy({ stem in
                  let master = cache.appendingPathComponent(stem + ".ntg.tif")
                  let size = (try? fm.attributesOfItem(atPath: master.path)[.size] as? NSNumber)
                  return (size?.int64Value ?? 0) > 0
                      && Invert.imageSize(master) != nil
              }) else {
            return .incomplete
        }
        return .complete
    }
}
