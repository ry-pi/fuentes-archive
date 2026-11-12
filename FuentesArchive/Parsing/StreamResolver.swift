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

    /// Timeline MP4s are scrub previews. yt-dlp skips `ua.tar` (those URLs are HLS playlists)
    /// and downloads a direct `ua.mp4` / `ua.webm` when one exists. HLS is only the fallback.
    static func select(_ variants: [Variant], capHeight: Int?) -> Variant? {
        let video = variants.filter { !$0.timeline && !$0.audioOnly && $0.height > 0 && !$0.url.isEmpty }
        let progressive = video.filter { $0.kind == "mp4" || $0.kind == "webm" }
        if !progressive.isEmpty {
            return pick(progressive, capHeight: capHeight)
        }
        if let hls = variants.first(where: { $0.kind == "hls" && !$0.url.isEmpty && !$0.timeline }) {
            return hls
        }
        let tar = video.filter { $0.kind == "tar" }
        if !tar.isEmpty { return pick(tar, capHeight: capHeight) }
        return nil
    }

    private static func pick(_ pool: [Variant], capHeight: Int?) -> Variant? {
        func rank(_ item: Variant) -> (Int, Int, Int) {
            let container = ["mp4": 3, "webm": 2, "hls": 1, "tar": 0][item.kind] ?? 0
            return (item.height, item.bitrate, container)
        }
        if let capHeight {
            let under = pool.filter { $0.height <= capHeight }
            if !under.isEmpty { return under.max { rank($0) < rank($1) } }
            return pool.min { ($0.height, $0.bitrate) < ($1.height, $1.bitrate) }
        }
        return pool.max { rank($0) < rank($1) }
    }

    static func videoCandidates(_ variants: [Variant]) -> [Variant] {
        variants.filter { !$0.timeline && !$0.audioOnly && $0.height > 0 && !$0.url.isEmpty }
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

struct ByteEstimate: Equatable {
    var bytes: Int64
    var estimated: Bool
}

struct DownloadChoice: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var height: Int
    var audioOnly: Bool
    var container: String
    var kind: String
    var url: String
    var bitrate: Int
    var bytes: Int64
    var estimated: Bool

    var sizeLabel: String {
        if bytes <= 0 { return "Size unknown" }
        let text = FormatBytes.string(bytes)
        return estimated ? "~\(text)" : text
    }
}

enum FormatBytes {
    static func string(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }
}

enum DownloadOffers {
    /// Exact embed sizes win. Otherwise bitrate (kbps) times duration, marked as an estimate.
    static func estimate(exact: Int64, bitrateKbps: Int, duration: Double?) -> ByteEstimate {
        if exact > 0 {
            return ByteEstimate(bytes: exact, estimated: false)
        }
        guard bitrateKbps > 0, let duration, duration > 0 else {
            return ByteEstimate(bytes: 0, estimated: true)
        }
        let bytes = Int64((Double(bitrateKbps) * 1000.0 / 8.0) * duration)
        return ByteEstimate(bytes: max(0, bytes), estimated: true)
    }

    static func summedRangeBytes(_ playlist: String) -> Int64 {
        var total: Int64 = 0
        for raw in playlist.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let probe = line.contains("://") ? line : "https://example.com/" + line
            guard let url = URL(string: probe), let bytes = HLSPlaylist.byteLength(of: url) else { continue }
            total += bytes
        }
        return total
    }

    /// A single media file, not an m3u8 or a tar chunklist. HEAD is only valid for these.
    static func isDirectFile(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.contains(".m3u8") || lower.contains("r_file=") || lower.contains(".tar") { return false }
        return lower.contains(".mp4") || lower.contains(".webm") || lower.contains(".aac") || lower.contains(".m4a")
    }

    static func sourceRank(_ kind: String) -> Int {
        switch kind {
        case "mp4": return 4
        case "webm": return 3
        case "hls": return 2
        case "tar": return 1
        default: return 0
        }
    }

    static func build(variants: [Variant], duration: Double?) -> [DownloadChoice] {
        var bestByHeight: [Int: Variant] = [:]
        for item in StreamResolver.videoCandidates(variants) {
            if let existing = bestByHeight[item.height] {
                let betterSource = sourceRank(item.kind) > sourceRank(existing.kind)
                let sameSourceHigherBitrate = sourceRank(item.kind) == sourceRank(existing.kind) && item.bitrate > existing.bitrate
                if !betterSource && !sameSourceHigherBitrate { continue }
            }
            bestByHeight[item.height] = item
        }
        var choices: [DownloadChoice] = []
        for height in bestByHeight.keys.sorted() {
            guard let item = bestByHeight[height] else { continue }
            let estimate = estimate(exact: item.size, bitrateKbps: item.bitrate, duration: duration)
            let direct = item.kind == "mp4" || item.kind == "webm"
            let container = direct ? item.kind : "mp4"
            let detail = direct ? item.kind.uppercased() : "HLS"
            choices.append(choice(item, height: height, container: container, title: "\(height)p", detail: detail, estimate: estimate))
        }
        if choices.isEmpty, let hls = variants.first(where: { $0.kind == "hls" && !$0.url.isEmpty && !$0.timeline }) {
            let estimate = estimate(exact: hls.size, bitrateKbps: hls.bitrate, duration: duration)
            choices.append(choice(hls, height: 0, container: "mp4", title: "Best available", detail: "HLS", estimate: estimate))
        }
        let audios = variants.filter { $0.audioOnly && !$0.timeline && !$0.url.isEmpty }
        if let audio = audios.max(by: { $0.bitrate < $1.bitrate }) {
            let estimate = estimate(exact: audio.size, bitrateKbps: audio.bitrate, duration: duration)
            choices.append(DownloadChoice(
                id: "audio-m4a",
                title: "Audio only",
                detail: "AAC · M4A",
                height: 0,
                audioOnly: true,
                container: "m4a",
                kind: audio.kind,
                url: audio.url,
                bitrate: audio.bitrate,
                bytes: estimate.bytes,
                estimated: estimate.estimated
            ))
        }
        return choices
    }

    static func applyingPlaylistBytes(_ choice: DownloadChoice, playlistBytes: Int64) -> DownloadChoice {
        guard playlistBytes > 0 else { return choice }
        var copy = choice
        copy.bytes = playlistBytes
        copy.estimated = false
        return copy
    }

    private static func choice(_ item: Variant, height: Int, container: String, title: String, detail: String, estimate: ByteEstimate) -> DownloadChoice {
        DownloadChoice(
            id: "video-\(height)-\(container)",
            title: title,
            detail: detail,
            height: height,
            audioOnly: false,
            container: container,
            kind: item.kind,
            url: item.url,
            bitrate: item.bitrate,
            bytes: estimate.bytes,
            estimated: estimate.estimated
        )
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
