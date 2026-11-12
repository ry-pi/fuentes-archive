import Foundation

/// Rotating on-device log for sync, HTTP, formats, and downloads. Capped near 2 MB.
enum DebugLog {
    static let limit = 2 * 1024 * 1024
    private static let lock = NSLock()

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FuentesArchive", isDirectory: true)
        return base.appendingPathComponent("debug.log")
    }

    static func event(_ message: String) {
        append(message)
    }

    static func detail(_ message: String) {
        guard LibraryStore.shared.snapshot().settings.verboseLog else { return }
        append(message)
    }

    static func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func append(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = Data((stamp + " " + message + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
        let size = (try? handle.offset()) ?? 0
        guard size > UInt64(limit) else { return }
        let keep = UInt64(limit / 2)
        try? handle.seek(toOffset: size - keep)
        let tail = (try? handle.readToEnd()) ?? Data()
        try? handle.truncate(atOffset: 0)
        try? handle.write(contentsOf: Data("…\n".utf8))
        try? handle.write(contentsOf: tail)
    }
}
