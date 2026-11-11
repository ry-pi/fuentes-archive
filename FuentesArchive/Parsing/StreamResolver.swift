import Foundation

struct Variant: Equatable {
    var kind: String
    var height: Int
    var bitrate: Int
    var size: Int64
    var url: String
    var timeline: Bool
    var audioOnly: Bool
}

enum StreamResolver {
    static func embedID(fromOEmbed payload: [String: Any]) -> String? {
        guard let html = payload["html"] as? String else { return nil }
        return HTMLScanner.firstCapture(#"/embed/([0-9a-zA-Z]+)"#, in: html)
    }

    /// The embed page assigns `p.f["id"] = {... ,loaded:v()}`. `loaded:v()` is script, not JSON.
    static func playerObject(from html: String) -> [String: Any]? {
        let pattern = #"p\.f\[[^\]]+\]\s*=\s*\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range, in: html) else { return nil }
        let brace = html.index(before: range.upperBound)
        guard var raw = HTMLScanner.braceObject(in: html, from: brace) else { return nil }
        raw = raw.replacingOccurrences(
            of: #",\s*loaded\s*:\s*v\(\)\s*"#,
            with: "",
            options: .regularExpression
        )
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    static func variants(from player: [String: Any]) -> [Variant] {
        guard let ua = player["ua"] as? [String: Any] else { return [] }
        var found: [Variant] = []
        for (kind, group) in ua {
            guard let group = group as? [String: Any] else { continue }
            let entries: [(Any, [String: Any])]
            if group["url"] is String {
                entries = [(kind, group)]
            } else {
                entries = group.compactMap { key, value in
                    (value as? [String: Any]).map { (key, $0) }
                }
            }
            for (key, info) in entries {
                guard let url = info["url"] as? String, !url.isEmpty else { continue }
                let meta = info["meta"] as? [String: Any] ?? [:]
                let height = heightValue(key: key, meta: meta)
                let bitrate = (meta["bitrate"] as? NSNumber)?.intValue ?? 0
                let size = (meta["size"] as? NSNumber)?.int64Value ?? 0
                let timeline = kind == "timeline"
                let audioOnly = kind == "audio" || (height <= 0 && kind != "hls" && !timeline)
                found.append(Variant(
                    kind: kind,
                    height: height,
                    bitrate: bitrate,
                    size: size,
                    url: url.replacingOccurrences(of: "\\/", with: "/"),
                    timeline: timeline,
                    audioOnly: audioOnly
                ))
            }
        }
        return found
    }

    /// Timeline MP4s are scrub previews. A separate AAC track is not the movie.
    /// Progressive MP4/WebM wins over HLS packaged in a tar, because it is one file.
    static func select(_ variants: [Variant], capHeight: Int?) -> Variant? {
        let usable = variants.filter { !$0.timeline && !$0.audioOnly && $0.height > 0 && !$0.url.isEmpty }
        let progressive = usable.filter { $0.kind == "mp4" || $0.kind == "webm" }
        let pool = progressive.isEmpty ? usable : progressive
        if pool.isEmpty {
            return variants.first { $0.kind == "hls" && !$0.url.isEmpty && !$0.timeline }
        }
        func rank(_ item: Variant) -> (Int, Int, Int) {
            let container = ["mp4": 3, "webm": 2, "hls": 1, "tar": 1][item.kind] ?? 0
            return (item.height, item.bitrate, container)
        }
        if let capHeight {
            let under = pool.filter { $0.height <= capHeight }
            if !under.isEmpty { return under.max { rank($0) < rank($1) } }
            return pool.min { ($0.height, $0.bitrate) < ($1.height, $1.bitrate) }
        }
        return pool.max { rank($0) < rank($1) }
    }

    private static func heightValue(key: Any, meta: [String: Any]) -> Int {
        if let height = meta["h"] as? NSNumber, height.intValue > 0 { return height.intValue }
        if let key = key as? String, let height = Int(key), height > 0 { return height }
        return 0
    }
}

struct HLSPlaylist {
    var master: Bool
    var variants: [MasterVariant]
    var segments: [Segment]
    var mapURL: URL?
    var encrypted: Bool

    struct MasterVariant: Equatable {
        var bandwidth: Int
        var width: Int
        var height: Int
        var url: URL
    }

    struct Segment: Equatable {
        var duration: Double
        var url: URL
    }

    static func parse(_ text: String, baseURL: URL) -> HLSPlaylist {
        var variants: [MasterVariant] = []
        var segments: [Segment] = []
        var mapURL: URL?
        var encrypted = false
        var pendingStream: (bandwidth: Int, width: Int, height: Int)?
        var pendingDuration: Double?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                let bandwidth = attrInt("BANDWIDTH", line)
                let resolution = attr("RESOLUTION", line) ?? ""
                var width = 0
                var height = 0
                let parts = resolution.lowercased().split(separator: "x", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    width = Int(parts[0]) ?? 0
                    height = Int(parts[1]) ?? 0
                }
                pendingStream = (bandwidth, width, height)
                pendingDuration = nil
            } else if line.hasPrefix("#EXTINF") {
                let value = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "0"
                pendingDuration = Double(value.split(separator: ",").first.map(String.init) ?? "0") ?? 0
                pendingStream = nil
            } else if line.hasPrefix("#EXT-X-MAP") {
                if let uri = attr("URI", line) {
                    mapURL = resolve(uri, base: baseURL)
                }
            } else if line.hasPrefix("#EXT-X-KEY") {
                let method = (attr("METHOD", line) ?? "").uppercased()
                if !method.isEmpty && method != "NONE" { encrypted = true }
            } else if line.hasPrefix("#") {
                continue
            } else if let absolute = resolve(line, base: baseURL) {
                if let stream = pendingStream {
                    variants.append(MasterVariant(
                        bandwidth: stream.bandwidth,
                        width: stream.width,
                        height: stream.height,
                        url: absolute
                    ))
                } else if let duration = pendingDuration {
                    segments.append(Segment(duration: duration, url: absolute))
                }
                pendingStream = nil
                pendingDuration = nil
            }
        }
        return HLSPlaylist(master: !variants.isEmpty, variants: variants, segments: segments, mapURL: mapURL, encrypted: encrypted)
    }

    /// RFC 3986 join for playlist URIs. Rumble media playlists use a relative
    /// `file.tar?r_file=…` against a base that already has a query string.
    static func resolve(_ reference: String, base: URL) -> URL? {
        if let absolute = URL(string: reference), absolute.scheme != nil {
            return absolute
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else { return nil }
        let hashParts = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let beforeHash = hashParts[0]
        let queryParts = beforeHash.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let relativePath = queryParts[0]
        if queryParts.count > 1 {
            components.percentEncodedQuery = queryParts[1].isEmpty ? nil : queryParts[1]
        } else if !relativePath.isEmpty {
            components.percentEncodedQuery = nil
        }
        if relativePath.hasPrefix("/") {
            components.path = relativePath
        } else if !relativePath.isEmpty {
            var segments = base.path.split(separator: "/").map(String.init)
            if !base.path.hasSuffix("/") && !segments.isEmpty {
                segments.removeLast()
            }
            for part in relativePath.split(separator: "/") {
                if part == "." { continue }
                if part == ".." { if !segments.isEmpty { segments.removeLast() } }
                else { segments.append(String(part)) }
            }
            components.path = "/" + segments.joined(separator: "/")
        }
        return components.url
    }

    static func select(_ variants: [MasterVariant], capHeight: Int?) -> MasterVariant? {
        let usable = variants.filter { $0.height > 0 }
        let pool = usable.isEmpty ? variants : usable
        guard !pool.isEmpty else { return nil }
        if let capHeight {
            let under = pool.filter { $0.height <= capHeight && $0.height > 0 }
            if !under.isEmpty {
                return under.max { ($0.height, $0.bandwidth) < ($1.height, $1.bandwidth) }
            }
            return pool.min { ($0.height == 0 ? Int.max : $0.height, $0.bandwidth) < ($1.height == 0 ? Int.max : $1.height, $1.bandwidth) }
        }
        return pool.max { ($0.height, $0.bandwidth) < ($1.height, $1.bandwidth) }
    }

    static func byteLength(of url: URL) -> Int64? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let span = items.first(where: { $0.name == "r_range" })?.value,
              let dash = span.firstIndex(of: "-") else { return nil }
        let start = Int64(span[..<dash])
        let end = Int64(span[span.index(after: dash)...])
        guard let start, let end, end >= start else { return nil }
        return end - start + 1
    }

    private static func attr(_ name: String, _ line: String) -> String? {
        let pattern = #"\#(name)=(?:"([^"]*)"|([^,\s]*))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        if let range = Range(match.range(at: 1), in: line), !range.isEmpty { return String(line[range]) }
        if let range = Range(match.range(at: 2), in: line) { return String(line[range]) }
        return nil
    }

    private static func attrInt(_ name: String, _ line: String) -> Int {
        Int(attr(name, line) ?? "") ?? 0
    }
}

enum FeedBuilder {
    static func rss(items: [ListedVideo], generatedAt: String) -> String {
        let rows = items.filter { $0.disposition == .downloadable }.map { item -> String in
            var row = """
                    <item>
                      <title>\(xml(item.title))</title>
                      <link>\(xml(item.watch))</link>
                      <guid isPermaLink="false">\(xml(item.id))</guid>
            """
            if let published = item.published {
                row += "\n      <pubDate>\(xml(published))</pubDate>"
            }
            row += "\n      <description>\(xml(item.channel ?? Channel.name))</description>\n    </item>"
            return row
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>\(xml(Channel.name)) — Videos</title>
            <link>\(Channel.videosPage.absoluteString)</link>
            <description>Videos tab only, generated locally by Fuentes Archive. Rumble does not publish an official feed for this channel.</description>
            <lastBuildDate>\(xml(generatedAt))</lastBuildDate>
        \(rows)
          </channel>
        </rss>
        """
    }

    static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

enum FileNames {
    static func safe(title: String, id: String, ext: String) -> String {
        let cleaned = title.replacingOccurrences(of: #"[^\w\s\-.,]+"#, with: "", options: .regularExpression)
        let collapsed = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let base = collapsed.isEmpty ? "video" : String(collapsed.prefix(80))
        return "\(base) [\(id)].\(ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")))"
    }
}

enum RetryPolicy {
    static let maxAutomaticAttempts = 5
    static func delay(for attempt: Int) -> TimeInterval {
        let steps: [TimeInterval] = [30, 120, 600, 1800, 7200]
        return steps[min(max(attempt, 0), steps.count - 1)]
    }

    static func shouldRetry(httpStatus: Int?, attempt: Int) -> Bool {
        if attempt >= maxAutomaticAttempts { return false }
        if let httpStatus, [404, 410, 451].contains(httpStatus) { return false }
        return true
    }
}
