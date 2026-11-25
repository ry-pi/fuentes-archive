import Foundation

struct RemoteVideo: Equatable {
    var embedID: String
    var title: String
    var author: String?
    var thumbnail: String?
    var watch: URL
}

enum RumbleLink {
    struct Parsed: Equatable {
        var watch: URL
        var permalink: String
    }

    enum LinkError: LocalizedError, Equatable {
        case empty
        case notRumble
        case notVideo

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Paste a Rumble video link first."
            case .notRumble:
                return "That is not a Rumble link."
            case .notVideo:
                return "That Rumble page is not a video. Paste a video, embed, or live replay link."
            }
        }
    }

    static func parse(_ raw: String) -> Result<Parsed, LinkError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let host = components.host?.lowercased(),
              host == "rumble.com" || host.hasSuffix(".rumble.com"),
              components.scheme == "http" || components.scheme == "https" else {
            return .failure(.notRumble)
        }
        let path = components.path
        if path.isEmpty || path == "/" { return .failure(.notVideo) }
        let lower = path.lowercased()
        let blocked = ["/c/", "/user/", "/account", "/search", "/browse", "/premium", "/login", "/register", "/settings", "/help"]
        if blocked.contains(where: { lower.hasPrefix($0) }) { return .failure(.notVideo) }
        guard let permalink = permalink(in: path) else { return .failure(.notVideo) }
        components.scheme = "https"
        components.host = "rumble.com"
        if lower.hasPrefix("/embed/") {
            components.path = "/embed/\(permalink)/"
            components.query = nil
            components.fragment = nil
        }
        guard let watch = components.url else { return .failure(.notVideo) }
        return .success(Parsed(watch: watch, permalink: permalink))
    }

    static func permalink(in path: String) -> String? {
        if let embed = first(#"/embed/([0-9A-Za-z]+)"#, in: path) { return embed }
        if let watch = first(#"/v([0-9A-Za-z]+)"#, in: path) { return "v" + watch }
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.count == 1 else { return nil }
        let slug = parts[0]
        let reserved = ["videos", "livestreams", "shorts", "feed", "about"]
        if reserved.contains(slug.lowercased()) || slug.count < 3 { return nil }
        return slug
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

enum ArchiveMatch {
    static func existingID(in videos: [String: VideoRecord], id: String, permalink: String, watch: String) -> String? {
        if videos[id] != nil { return id }
        let permalinkNeedle = permalink.lowercased()
        let watchNeedle = watch.lowercased()
        if permalinkNeedle.isEmpty && watchNeedle.isEmpty { return nil }
        return videos.values.first { video in
            let ownPermalink = video.permalink.lowercased()
            let ownID = video.id.lowercased()
            let ownWatch = video.watchURL.lowercased()
            if !permalinkNeedle.isEmpty && (ownPermalink == permalinkNeedle || ownID == permalinkNeedle) { return true }
            if !watchNeedle.isEmpty && ownWatch == watchNeedle { return true }
            if !permalinkNeedle.isEmpty && ownWatch.contains("/\(permalinkNeedle)") { return true }
            return false
        }?.id
    }
}

enum Retention {
    static func removable(_ records: [VideoRecord], settings: Settings, now: Date) -> [String] {
        records.compactMap { record in
            guard record.status == .downloaded, record.relativePath != nil, !record.manuallyAdded else { return nil }
            let watched = record.duration.map { duration in duration > 30 && record.playbackSeconds >= duration * 0.9 } ?? false
            if settings.deleteWatched && watched { return record.id }
            if settings.deleteAfterDays > 0 {
                let age = now.timeIntervalSince(record.updatedAt)
                if age > Double(settings.deleteAfterDays) * 86_400 { return record.id }
            }
            return nil
        }
    }
}
