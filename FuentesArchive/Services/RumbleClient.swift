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
    func resolve(watch: URL, capHeight: Int?) async throws -> Variant {
        var components = URLComponents(string: "https://rumble.com/api/Media/oembed.json")!
        components.queryItems = [URLQueryItem(name: "url", value: watch.absoluteString)]
        guard let oembedURL = components.url else { throw RumbleError.noStream }
        let payload = try await jsonObject(oembedURL)
        guard let embed = StreamResolver.embedID(fromOEmbed: payload) else { throw RumbleError.noStream }

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
        let chosen = StreamResolver.select(StreamResolver.variants(from: player), capHeight: capHeight)
        if let chosen { return chosen }
        let message = ((player["sys"] as? [String: Any])?["msg"] as? String)?.lowercased() ?? ""
        if message.contains("subscriber") || message.contains("premium") || message.contains("members") {
            throw RumbleError.members
        }
        throw RumbleError.noStream
    }

    func text(_ url: URL) async throws -> String {
        String(decoding: try await fetch(url, accept: "*/*"), as: UTF8.self)
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
