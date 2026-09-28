import Foundation

enum RollPersistence {
    static func write<T: Encodable>(_ value: T, to url: URL, backup: Bool = true) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        if backup, fm.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            try previous.write(to: url.appendingPathExtension("backup"), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }

    static func saveMetadata(_ metadata: RollMetadata, to url: URL) throws {
        // Never replace an unreadable file with an apparently empty new roll.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try JSONDecoder().decode(RollMetadata.self, from: Data(contentsOf: url))
        }
        try write(metadata, to: url)
    }

    static func loadMetadata(from url: URL) throws -> RollMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else { return RollMetadata() }
        return try JSONDecoder().decode(RollMetadata.self, from: Data(contentsOf: url))
    }
}

/// Cooperative cancellation is shared by synchronous image workers and UI jobs.
final class RollCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}
