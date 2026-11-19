import ActivityKit
import Foundation

struct SnapshotVideo: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var published: Date?
    var duration: Double?
    var isAudio: Bool
    var hasThumbnail: Bool
}

struct ArchiveSnapshot: Codable, Equatable {
    var updatedAt: Date
    var lastSync: Date?
    var videoCount: Int
    var downloadCount: Int
    var appBytes: Int64
    var downloadBytes: Int64
    var activeTitle: String
    var activePercent: Double
    var activeBytesWritten: Int64
    var activeBytesExpected: Int64
    var activeSpeed: Double
    var queueCount: Int
    var videos: [SnapshotVideo]

    static let empty = ArchiveSnapshot(
        updatedAt: .distantPast,
        lastSync: nil,
        videoCount: 0,
        downloadCount: 0,
        appBytes: 0,
        downloadBytes: 0,
        activeTitle: "",
        activePercent: 0,
        activeBytesWritten: 0,
        activeBytesExpected: 0,
        activeSpeed: 0,
        queueCount: 0,
        videos: []
    )
}

struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var percent: Double
        var bytesWritten: Int64
        var bytesExpected: Int64
        var bytesPerSecond: Double
        var queueCount: Int
    }

    var videoID: String
}

enum ArchiveLink {
    static var videos: URL { URL(string: "fuentesarchive://videos")! }
    static var downloads: URL { URL(string: "fuentesarchive://downloads")! }
    static var player: URL { URL(string: "fuentesarchive://player")! }

    static func video(_ id: String) -> URL {
        var components = URLComponents()
        components.scheme = "fuentesarchive"
        components.host = "video"
        components.path = "/" + id
        return components.url ?? videos
    }
}

enum AppGroup {
    static let fallback = "group.com.local.fuentesarchive"
    static let plistKey = "ArchiveAppGroup"

    static func resolvedID(bundle: Bundle = .main, fileManager: FileManager = .default) -> String {
        let fromProvision = groupIDs(inProvisionOf: bundle)
        for identifier in fromProvision where containerExists(identifier, fileManager: fileManager) {
            return identifier
        }
        if let listed = bundle.object(forInfoDictionaryKey: plistKey) as? String, containerExists(listed, fileManager: fileManager) {
            return listed
        }
        if let listed = bundle.object(forInfoDictionaryKey: plistKey) as? String, !listed.isEmpty {
            return listed
        }
        return fromProvision.first ?? fallback
    }

    static func containerURL(bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        let identifier = resolvedID(bundle: bundle, fileManager: fileManager)
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static func groupIDs(inProvision data: Data) -> [String] {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else { return [] }
        let slice = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(slice), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
        return groups
    }

    static func groupIDs(inProvisionOf bundle: Bundle) -> [String] {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return [] }
        return groupIDs(inProvision: data)
    }

    private static func containerExists(_ identifier: String, fileManager: FileManager) -> Bool {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil
    }
}

enum SnapshotStore {
    static let fileName = "snapshot.json"

    static func write(_ snapshot: ArchiveSnapshot, to root: URL) throws {
        let url = root.appendingPathComponent(fileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    static func read(from root: URL) -> ArchiveSnapshot {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ArchiveSnapshot.self, from: data)) ?? .empty
    }

    static func save(_ snapshot: ArchiveSnapshot) {
        guard let root = AppGroup.containerURL() else { return }
        try? write(snapshot, to: root)
    }

    static func load(bundle: Bundle = .main) -> ArchiveSnapshot {
        guard let root = AppGroup.containerURL(bundle: bundle) else { return .empty }
        return read(from: root)
    }

    static func thumbnailURL(id: String, root: URL) -> URL {
        root.appendingPathComponent("thumbnails", isDirectory: true).appendingPathComponent("\(id).jpg")
    }
}

enum SnapshotBytes {
    static func string(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(count, 0))
    }

    /// Compact progress such as "35/102 MB". Empty when nothing has been counted yet.
    static func progress(written: Int64, expected: Int64) -> String {
        if written <= 0 && expected <= 0 { return "" }
        func mega(_ bytes: Int64) -> String {
            if bytes <= 0 { return "0" }
            let value = Double(bytes) / (1024 * 1024)
            if value >= 10 { return String(format: "%.0f", value.rounded()) }
            return String(format: "%.1f", value)
        }
        if expected > 0 { return "\(mega(written))/\(mega(expected)) MB" }
        return "\(mega(written)) MB"
    }

    static func eta(remaining: Int64, rate: Double) -> String {
        guard rate > 1, remaining > 0 else { return "" }
        let seconds = Int(Double(remaining) / rate)
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
}
