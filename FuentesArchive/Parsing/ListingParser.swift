import Foundation

enum Channel {
    static let slug = "nickjfuentes"
    static let name = "Nicholas J. Fuentes"
    static let videosPage = URL(string: "https://rumble.com/c/nickjfuentes/videos")!
    static let shortsPage = URL(string: "https://rumble.com/c/nickjfuentes/shorts")!
    static let livePage = URL(string: "https://rumble.com/c/nickjfuentes/livestreams")!
}

enum Disposition: String, Codable {
    case downloadable
    case members
    case premiere
    case live
    case short
    case processing
    case ignored
}

struct ListedVideo: Equatable {
    var id: String
    var permalink: String
    var title: String
    var watch: String
    var thumb: String?
    var published: String?
    var duration: Double?
    var views: Int?
    var disposition: Disposition
    var channel: String?
    var channelURL: String?
}

struct ListingPage: Equatable {
    var items: [ListedVideo]
    var nextURL: URL?
    var canonical: String?
    var challenged: Bool
}

enum ListingParser {
    static func parse(html: String, pageURL: URL = Channel.videosPage) -> ListingPage {
        var page = ListingPage(
            items: [],
            nextURL: HTMLScanner.nextURL(in: html, pageURL: pageURL),
            canonical: HTMLScanner.canonical(in: html),
            challenged: HTMLScanner.challenged(html)
        )
        if page.challenged { return page }

        var merged: [String: ListedVideo] = [:]
        var order: [String] = []
        func add(_ item: ListedVideo?) {
            guard let item else { return }
            let key = item.id.isEmpty ? (item.permalink.isEmpty ? item.watch : item.permalink) : item.id
            if let existing = merged[key] {
                merged[key] = merge(existing, item)
                return
            }
            merged[key] = item
            order.append(key)
        }

        let payloads = HTMLScanner.jsonListings(in: html)
        if !payloads.isEmpty {
            for payload in payloads {
                let items = payload["items"] as? [Any] ?? []
                for raw in items {
                    add(fromJSON(raw as? [String: Any]))
                }
            }
        } else {
            for tag in HTMLScanner.thumbnailTags(in: html) {
                add(fromThumbnail(tag))
            }
        }
        page.items = order.compactMap { merged[$0] }
        return page
    }

    private static func merge(_ existing: ListedVideo, _ incoming: ListedVideo) -> ListedVideo {
        if existing.duration == nil, incoming.duration != nil { return incoming }
        if incoming.duration == nil, existing.duration != nil { return existing }
        if existing.views == nil, incoming.views != nil { return incoming }
        return existing
    }

    private static func fromJSON(_ item: [String: Any]?) -> ListedVideo? {
        guard let item else { return nil }
        let disposition = disposition(for: item)
        if disposition == .short || disposition == .live || disposition == .ignored { return nil }
        var watch = HTMLScanner.stripTracking(string(item["url"]) ?? "")
        watch = HTMLScanner.absoluteRumble(watch)
        let permalink = string(item["permalink_id"]).flatMap { $0.isEmpty ? nil : $0 } ?? HTMLScanner.permalink(from: watch)
        let videoID = string(item["id"]) ?? permalink
        guard !videoID.isEmpty, let title = string(item["title"])?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        let by = item["by"] as? [String: Any]
        let published = string(item["upload_date"]) ?? string(item["live_datetime"])
        return ListedVideo(
            id: videoID,
            permalink: permalink,
            title: HTMLScanner.unescape(title),
            watch: watch,
            thumb: string(item["thumb"]),
            published: published,
            duration: double(item["duration"]),
            views: int(item["views"]),
            disposition: disposition,
            channel: string(by?["name"]),
            channelURL: string(by?["url"])
        )
    }

    private static func disposition(for item: [String: Any]) -> Disposition {
        let objectType = (string(item["object_type"]) ?? "video").lowercased()
        if objectType != "video" && objectType != "" { return .ignored }
        if bool(item["is_short"]) { return .short }
        let status = (string(item["livestream_status"]) ?? "").lowercased()
        if bool(item["live"]) || status == "live" || status == "streaming" { return .live }
        if bool(item["live_placeholder"]) || ["upcoming", "scheduled", "premiere", "waiting"].contains(status) {
            return .premiere
        }
        let visibility = (string(item["visibility"]) ?? "public").lowercased()
        let availability = (string(item["availability"]) ?? "").lowercased()
        if !["", "public"].contains(visibility) || ["premium", "subscribers", "members", "private"].contains(availability) {
            return .members
        }
        if bool(item["is_processing"]) { return .processing }
        return .downloadable
    }

    private static func fromThumbnail(_ tag: String) -> ListedVideo? {
        let attrs = HTMLScanner.attributes(in: tag)
        let title = (attrs["video-title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var watch = HTMLScanner.stripTracking(attrs["url"] ?? "")
        watch = HTMLScanner.absoluteRumble(watch)
        guard !title.isEmpty, !watch.isEmpty else { return nil }
        let kind = (attrs["kind"] ?? "").lowercased()
        if kind.contains("short") || watch.contains("/shorts") { return nil }
        let permalink = HTMLScanner.permalink(from: watch)
        let videoID = attrs["video-id"].flatMap { $0.isEmpty ? nil : $0 } ?? permalink
        let scheduled = (attrs["scheduled-time"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var disposition = Disposition.downloadable
        let duration = double(attrs["duration"])
        if !scheduled.isEmpty || duration == 0 && !scheduled.isEmpty {
            disposition = .premiere
        }
        return ListedVideo(
            id: videoID,
            permalink: permalink,
            title: title,
            watch: watch,
            thumb: attrs["src"],
            published: attrs["time"],
            duration: duration,
            views: int(attrs["views"]),
            disposition: disposition,
            channel: attrs["name"] ?? attrs["creator-name"],
            channelURL: attrs["creator-url"]
        )
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as NSNumber: return number.intValue
        case let text as String:
            if let value = Int(text) { return value }
            if let value = Double(text) { return Int(value) }
            return nil
        default: return nil
        }
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }

    private static func bool(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String: return ["1", "true", "yes"].contains(text.lowercased())
        default: return false
        }
    }
}

struct SyncVideo: Equatable {
    var id: String
    var disposition: Disposition
}

enum AutoQueue {
    /// Walk pages until one is entirely videos we already know.
    /// Every new public video before that boundary is queued, including ones
    /// that spilled past page 1. Older pages are never a silent backfill.
    static func plan(
        pages: [[SyncVideo]],
        known: Set<String>,
        baseline: Bool,
        autoOn: Bool,
        maxPages: Int
    ) -> (queue: [String], seen: [String]) {
        var known = known
        var queue: [String] = []
        var seen: [String] = []
        for page in pages.prefix(max(1, maxPages)) {
            if page.isEmpty { break }
            if page.allSatisfy({ known.contains($0.id) }) { break }
            for item in page where !known.contains(item.id) {
                seen.append(item.id)
                known.insert(item.id)
                if autoOn && !baseline && item.disposition == .downloadable {
                    queue.append(item.id)
                }
            }
        }
        return (queue, seen)
    }

    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
