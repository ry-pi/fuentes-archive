import Foundation

enum HTMLScanner {
    static func unescape(_ text: String) -> String {
        var result = text
        let named = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&#39;": "'", "&nbsp;": " "
        ]
        for (entity, value) in named {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        let pattern = "&#(x?[0-9A-Fa-f]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let range = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, range: range).reversed()
        for match in matches {
            guard let full = Range(match.range, in: result),
                  let token = Range(match.range(at: 1), in: result) else { continue }
            let raw = String(result[token])
            let scalar: UInt32?
            if raw.lowercased().hasPrefix("x") {
                scalar = UInt32(raw.dropFirst(), radix: 16)
            } else {
                scalar = UInt32(raw)
            }
            if let scalar, let unicode = UnicodeScalar(scalar) {
                result.replaceSubrange(full, with: String(unicode))
            }
        }
        return result
    }

    static func braceObject(in text: String, from start: String.Index) -> String? {
        guard start < text.endIndex, text[start] == "{" else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func attributes(in tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([^\s=/>]+)="([^"]*)""#) else { return [:] }
        var found: [String: String] = [:]
        let range = NSRange(tag.startIndex..., in: tag)
        for match in regex.matches(in: tag, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: tag),
                  let valueRange = Range(match.range(at: 2), in: tag) else { continue }
            found[String(tag[keyRange])] = unescape(String(tag[valueRange]))
        }
        return found
    }

    static func thumbnailTags(in html: String) -> [String] {
        let needle = "<rum-video-thumbnail"
        var tags: [String] = []
        var search = html.startIndex
        while let start = html.range(of: needle, range: search..<html.endIndex)?.lowerBound {
            var index = html.index(start, offsetBy: needle.count)
            var inString = false
            var closed = false
            while index < html.endIndex {
                let character = html[index]
                if character == "\"" {
                    inString.toggle()
                } else if character == ">", !inString {
                    tags.append(String(html[start...index]))
                    search = html.index(after: index)
                    closed = true
                    break
                }
                index = html.index(after: index)
            }
            if !closed { break }
        }
        return tags
    }

    static func jsonListings(in html: String) -> [[String: Any]] {
        let pattern = #"<script[^>]*type=["']application/json["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var payloads: [[String: Any]] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let bodyStart = tagRange.upperBound
            guard let close = html.range(of: "</script>", range: bodyStart..<html.endIndex) else { continue }
            let body = unescape(String(html[bodyStart..<close.lowerBound])).trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.hasPrefix("{"), let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["items"] is [Any] else { continue }
            payloads.append(object)
        }
        return payloads
    }

    static func canonical(in html: String) -> String? {
        firstCapture(#"rel=["']canonical["'][^>]*href=["']([^"']+)"#, in: html)
            ?? firstCapture(#"href=["']([^"']+)["'][^>]*rel=["']canonical["']"#, in: html)
    }

    static func nextURL(in html: String, pageURL: URL) -> URL? {
        if let href = firstCapture(#"rel=["']next["'][^>]*href=["']([^"']+)"#, in: html)
            ?? firstCapture(#"href=["']([^"']+)["'][^>]*rel=["']next["']"#, in: html) {
            return URL(string: unescape(href), relativeTo: pageURL)?.absoluteURL
        }
        let current = pageNumber(pageURL)
        let pattern = #"href=["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        var candidates: [(Int, URL)] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, range: range) {
            guard let hrefRange = Range(match.range(at: 1), in: html) else { continue }
            let href = unescape(String(html[hrefRange]))
            guard let absolute = URL(string: href, relativeTo: pageURL)?.absoluteURL else { continue }
            guard absolute.path.contains("/videos") else { continue }
            let number = pageNumber(absolute)
            if number > current {
                candidates.append((number, absolute))
            }
        }
        return candidates.sorted { $0.0 < $1.0 }.first?.1
    }

    static func pageNumber(_ url: URL) -> Int {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
        let raw = items.first { $0.name == "page" }?.value ?? "1"
        return max(1, Int(raw) ?? 1)
    }

    static func challenged(_ html: String) -> Bool {
        let sample = html.prefix(8000).lowercased()
        return sample.contains("just a moment")
            || sample.contains("cf-browser-verification")
            || sample.contains("performing security verification")
            || sample.contains("challenge-platform")
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return unescape(String(text[capture]))
    }

    static func stripTracking(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return urlString }
        components.queryItems = components.queryItems?.filter { $0.name != "e9s" }
        if components.queryItems?.isEmpty == true {
            components.queryItems = nil
        }
        return components.string ?? urlString
    }

    static func permalink(from urlString: String) -> String {
        let path = URL(string: urlString)?.path ?? urlString
        guard let regex = try? NSRegularExpression(pattern: #"/(v[0-9a-z]+)(?:-|\.|$)"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let range = Range(match.range(at: 1), in: path) else { return "" }
        return String(path[range])
    }

    static func absoluteRumble(_ urlString: String) -> String {
        if urlString.hasPrefix("/") {
            return "https://rumble.com" + urlString
        }
        return urlString
    }
}
