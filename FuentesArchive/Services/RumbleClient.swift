import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum RumbleError: LocalizedError {
    case cloudflare
    case http(Int)
    case noStream
    case members
    case encrypted
    case diskSpace

    var errorDescription: String? {
        switch self {
        case .cloudflare:
            return "Rumble asked for a browser check (Cloudflare). Open the app again on Wi-Fi, or pull to refresh."
        case .http(let status):
            return "Rumble returned HTTP \(status)."
        case .noStream:
            return "No public video stream was published for this upload."
        case .members:
            return "Members-only. This app only saves public Videos-tab uploads."
        case .encrypted:
            return "The stream is encrypted, so it was not saved."
        case .diskSpace:
            return "Not enough free space for this quality. Pick a lower quality in Settings."
        }
    }
}

struct RumbleClient {
    var session: URLSession = .shared
    var userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    func fetchListing(_ url: URL) async throws -> String {
        let data = try await fetch(url, accept: "text/html")
        return String(decoding: data, as: UTF8.self)
    }

    /// Listing `eid` values are not embed ids. oEmbed returns the real `/embed/{id}`.
    func variants(for watch: URL) async throws -> [Variant] {
        try await loadVariants(watch: watch)
    }

    func resolve(watch: URL, capHeight: Int?) async throws -> Variant {
        var components = URLComponents(string: "https://rumble.com/api/Media/oembed.json")!
        components.queryItems = [URLQueryItem(name: "url", value: watch.absoluteString)]
        guard let oembedURL = components.url else { throw RumbleError.noStream }
        let payload = try await jsonObject(oembedURL)
        guard let embed = StreamResolver.embedID(fromOEmbed: payload) else { throw RumbleError.noStream }
        let variants = try await variants(embedID: embed)
        guard let chosen = StreamResolver.select(variants, capHeight: capHeight) else { throw RumbleError.noStream }
        return chosen
    }

    private func loadVariants(watch: URL) async throws -> [Variant] {
        var components = URLComponents(string: "https://rumble.com/api/Media/oembed.json")!
        components.queryItems = [URLQueryItem(name: "url", value: watch.absoluteString)]
        guard let oembedURL = components.url else { throw RumbleError.noStream }
        let payload = try await jsonObject(oembedURL)
        guard let embed = StreamResolver.embedID(fromOEmbed: payload) else { throw RumbleError.noStream }
        return try await variants(embedID: embed)
    }

    private func variants(embedID embed: String) async throws -> [Variant] {
        var player: [String: Any]?
        if let endpoint = URL(string: "https://rumble.com/embedJS/u3/?request=video&ver=2&v=\(embed)") {
            let data = try? await fetch(endpoint, accept: "application/json")
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["ua"] != nil {
                player = object
            }
        }
        if player == nil {
            let html = try await fetchListing(URL(string: "https://rumble.com/embed/\(embed)")!)
            if HTMLScanner.challenged(html) { throw RumbleError.cloudflare }
            player = StreamResolver.playerObject(from: html)
        }
        guard let player else { throw RumbleError.noStream }
        let found = StreamResolver.variants(from: player)
        if StreamResolver.select(found, capHeight: nil) != nil || found.contains(where: { $0.audioOnly && !$0.url.isEmpty }) {
            return found
        }
        let message = ((player["sys"] as? [String: Any])?["msg"] as? String)?.lowercased() ?? ""
        if message.contains("subscriber") || message.contains("premium") || message.contains("members") {
            throw RumbleError.members
        }
        throw RumbleError.noStream
    }

    func text(_ url: URL) async throws -> String {
        String(decoding: try await fetch(url, accept: "*/*"), as: UTF8.self)
    }

    func contentLength(_ url: URL) async -> Int64? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://rumble.com/", forHTTPHeaderField: "Referer")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        if let header = http.value(forHTTPHeaderField: "Content-Length"), let value = Int64(header), value > 0 {
            return value
        }
        return http.expectedContentLength > 0 ? http.expectedContentLength : nil
    }

    private func jsonObject(_ url: URL) async throws -> [String: Any] {
        let data = try await fetch(url, accept: "application/json")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RumbleError.noStream
        }
        return object
    }

    private func fetch(_ url: URL, accept: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://rumble.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 410 { throw RumbleError.http(410) }
        if !(200..<300).contains(status) { throw RumbleError.http(status) }
        return data
    }
}
