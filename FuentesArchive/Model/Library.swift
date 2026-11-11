import Foundation

enum Quality: String, Codable, CaseIterable, Identifiable {
    case best, p1080, p720, p480, p360
    var id: String { rawValue }
    var capHeight: Int? {
        switch self {
        case .best: return nil
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        case .p360: return 360
        }
    }
    var label: String {
        switch self {
        case .best: return "Best available"
        case .p1080: return "Up to 1080p"
        case .p720: return "Up to 720p"
        case .p480: return "Up to 480p"
        case .p360: return "Up to 360p"
        }
    }
}

enum DownloadStatus: String, Codable {
    case catalogued
    case queued
    case waitingForWiFi
    case downloading
    case downloaded
    case failed
    case waiting
    case skipped
}

struct VideoRecord: Codable, Identifiable, Equatable {
    var id: String
    var permalink: String
    var title: String
    var watchURL: String
    var thumbnailURL: String?
    var published: Date?
    var duration: Double?
    var views: Int?
    var channelName: String?
    var disposition: Disposition
    var status: DownloadStatus
    var progress: Double
    var bytesWritten: Int64
    var bytesExpected: Int64
    var relativePath: String?
    var qualityLabel: String?
    var errorMessage: String?
    var attemptCount: Int
    var nextRetryAt: Date?
    var segmentTotal: Int
    var segmentDone: Int
    var updatedAt: Date
}

struct LogEntry: Codable, Identifiable, Equatable {
    var id: String
    var date: Date
    var source: String
    var message: String
    var level: String
}

struct Settings: Codable, Equatable {
    var autoDownload: Bool = true
    var wifiOnly: Bool = true
    var quality: Quality = .p720
    var saveToPhotos: Bool = false
    var notify: Bool = true
    var maxPages: Int = 2
    var backfillCount: Int = 0
    var dismissedIntro: Bool = false

    enum CodingKeys: String, CodingKey {
        case autoDownload, wifiOnly, quality, saveToPhotos, notify, maxPages, backfillCount, dismissedIntro
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoDownload = try container.decodeIfPresent(Bool.self, forKey: .autoDownload) ?? true
        wifiOnly = try container.decodeIfPresent(Bool.self, forKey: .wifiOnly) ?? true
        quality = try container.decodeIfPresent(Quality.self, forKey: .quality) ?? .p720
        saveToPhotos = try container.decodeIfPresent(Bool.self, forKey: .saveToPhotos) ?? false
        notify = try container.decodeIfPresent(Bool.self, forKey: .notify) ?? true
        maxPages = try container.decodeIfPresent(Int.self, forKey: .maxPages) ?? 2
        backfillCount = try container.decodeIfPresent(Int.self, forKey: .backfillCount) ?? 0
        dismissedIntro = try container.decodeIfPresent(Bool.self, forKey: .dismissedIntro) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(autoDownload, forKey: .autoDownload)
        try container.encode(wifiOnly, forKey: .wifiOnly)
        try container.encode(quality, forKey: .quality)
        try container.encode(saveToPhotos, forKey: .saveToPhotos)
        try container.encode(notify, forKey: .notify)
        try container.encode(maxPages, forKey: .maxPages)
        try container.encode(backfillCount, forKey: .backfillCount)
        try container.encode(dismissedIntro, forKey: .dismissedIntro)
    }
}

struct LibraryState: Codable, Equatable {
    var videos: [String: VideoRecord] = [:]
    var settings: Settings = Settings()
    var watermark: Date?
    var baselineReady: Bool = false
    var lastSync: Date?
    var lastError: String?
    var log: [LogEntry] = []
    var ignoredIDs: [String] = []
    /// Ids ever seen, including ones the user hid. Stops a restore or a later
    /// page scan from treating the back catalog as brand new.
    var knownIDs: [String] = []

    enum CodingKeys: String, CodingKey {
        case videos, settings, watermark, baselineReady, lastSync, lastError, log, ignoredIDs, knownIDs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videos = try container.decodeIfPresent([String: VideoRecord].self, forKey: .videos) ?? [:]
        settings = try container.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        watermark = try container.decodeIfPresent(Date.self, forKey: .watermark)
        baselineReady = try container.decodeIfPresent(Bool.self, forKey: .baselineReady) ?? false
        lastSync = try container.decodeIfPresent(Date.self, forKey: .lastSync)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        log = try container.decodeIfPresent([LogEntry].self, forKey: .log) ?? []
        ignoredIDs = try container.decodeIfPresent([String].self, forKey: .ignoredIDs) ?? []
        knownIDs = try container.decodeIfPresent([String].self, forKey: .knownIDs) ?? []
        if baselineReady && knownIDs.isEmpty {
            knownIDs = Array(videos.keys)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(videos, forKey: .videos)
        try container.encode(settings, forKey: .settings)
        try container.encodeIfPresent(watermark, forKey: .watermark)
        try container.encode(baselineReady, forKey: .baselineReady)
        try container.encodeIfPresent(lastSync, forKey: .lastSync)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encode(log, forKey: .log)
        try container.encode(ignoredIDs, forKey: .ignoredIDs)
        try container.encode(knownIDs, forKey: .knownIDs)
    }
}

final class LibraryStore {
    static let shared = LibraryStore()
    private let lock = NSLock()
    private var state = LibraryState()
    var onChange: (() -> Void)?
    let supportURL: URL
    let documentsURL: URL

    private init() {
        let fileManager = FileManager.default
        supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FuentesArchive", isDirectory: true)
        documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: documentsURL.appendingPathComponent("Videos", isDirectory: true), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: libraryURL),
           let decoded = try? JSONDecoder.archive.decode(LibraryState.self, from: data) {
            state = decoded
            if state.baselineReady && state.knownIDs.isEmpty && !state.videos.isEmpty {
                state.knownIDs = Array(state.videos.keys)
                if let encoded = try? JSONEncoder.archive.encode(state) {
                    try? encoded.write(to: libraryURL, options: .atomic)
                }
            }
        }
    }

    var libraryURL: URL { supportURL.appendingPathComponent("library.json") }
    func partialURL(_ id: String) -> URL { supportURL.appendingPathComponent("Partial", isDirectory: true).appendingPathComponent(id, isDirectory: true) }
    func fileURL(relativePath: String) -> URL { documentsURL.appendingPathComponent(relativePath) }

    func snapshot() -> LibraryState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func update(_ body: (inout LibraryState) -> Void) {
        lock.lock()
        body(&state)
        if state.log.count > 200 {
            state.log.removeFirst(state.log.count - 200)
        }
        let data = try? JSONEncoder.archive.encode(state)
        lock.unlock()
        if let data {
            try? data.write(to: libraryURL, options: .atomic)
        }
        let callback = onChange
        if Thread.isMainThread {
            callback?()
        } else {
            DispatchQueue.main.async { callback?() }
        }
    }
}

extension JSONEncoder {
    static var archive: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var archive: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum Paths {
    static var documents: URL { LibraryStore.shared.documentsURL }
    static var videosDirectory: URL { documents.appendingPathComponent("Videos", isDirectory: true) }
    static func videoFile(title: String, id: String, ext: String) -> URL {
        videosDirectory.appendingPathComponent(FileNames.safe(title: title, id: id, ext: ext))
    }
}
