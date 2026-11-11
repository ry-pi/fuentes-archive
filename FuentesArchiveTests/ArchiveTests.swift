import XCTest
@testable import FuentesArchive

final class ArchiveTests: XCTestCase {
    func testLiveThumbnailFixtureMatchesTheVideosTab() throws {
        let page = ListingParser.parse(html: try fixture("videos-tab-live.html"), pageURL: Channel.videosPage)
        XCTAssertFalse(page.challenged)
        XCTAssertEqual(page.canonical, Channel.videosPage.absoluteString)
        XCTAssertEqual(page.nextURL?.absoluteString, "https://rumble.com/c/nickjfuentes/videos?page=2")
        XCTAssertEqual(page.items.count, 25)
        XCTAssertEqual(Set(page.items.map(\.id)).count, 25)
        XCTAssertEqual(page.items.prefix(4).map(\.title), [
            "Nick Fuentes on the Alex Jones Show",
            "Trump CUCKS on Deportations, Embraces AMNESTY",
            "I WAS RIGHT ABOUT EVERYTHING!!!",
            "Trump BLAMES Voters for Crushing Defeat"
        ])
        let first = try XCTUnwrap(page.items.first)
        XCTAssertEqual(first.id, "450098556")
        XCTAssertEqual(first.permalink, "v7i5j76")
        XCTAssertEqual(first.duration, 4023)
        XCTAssertEqual(first.views, 83714)
        XCTAssertEqual(first.published, "2026-11-10T19:43:12+00:00")
        XCTAssertEqual(first.watch, "https://rumble.com/v7i5j76-nick-fuentes-on-the-alex-jones-show.html")
        XCTAssertFalse(first.watch.contains("e9s="))
        XCTAssertEqual(first.channelURL, "https://rumble.com/c/nickjfuentes")
        XCTAssertTrue(page.items.allSatisfy { $0.disposition == .downloadable })
    }

    func testServerJSONDropsShortsLivesAndKeepsMembersAndPremieres() throws {
        let page = ListingParser.parse(html: try fixture("videos-grid-server.html"), pageURL: Channel.videosPage)
        XCTAssertEqual(page.items.map { ($0.title, $0.disposition) }, [
            ("MAKE THE GOYIM GREAT AGAIN!!!", .downloadable),
            ("Governments Tell Citizens to Prepare for DISASTER", .downloadable),
            ("Leftist Hackers DOX ICE Agents", .downloadable),
            ("Members Only Strategy Stream", .members),
            ("Upcoming Premiere Example", .premiere)
        ])
        XCTAssertEqual(page.items[0].id, "449349028")
        XCTAssertEqual(page.items[0].permalink, "v7hpguy")
        XCTAssertEqual(page.items[0].channel, "Nicholas J. Fuentes")
        XCTAssertEqual(page.nextURL?.absoluteString, "https://rumble.com/c/nickjfuentes/videos?page=2")
        let second = ListingParser.parse(html: try fixture("videos-grid-page2.html"), pageURL: URL(string: "https://rumble.com/c/nickjfuentes/videos?page=2")!)
        XCTAssertEqual(second.nextURL?.absoluteString, "https://rumble.com/c/nickjfuentes/videos?page=3")
        XCTAssertEqual(second.items.first?.title, "I'M SICK OF THESE FREAKS!!!")
        XCTAssertEqual(second.items.first?.id, "446564796")
        XCTAssertTrue(Set(page.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
    }

    func testCloudflareChallengeIsNotAnEmptyLibrary() {
        let page = ListingParser.parse(html: "<html><title>Just a moment...</title>Performing security verification</html>")
        XCTAssertTrue(page.challenged)
        XCTAssertTrue(page.items.isEmpty)
    }

    func testAutoQueueDoesNotBackfillOlderPages() {
        XCTAssertFalse(AutoQueue.shouldQueue(isNew: true, pageIndex: 0, published: "2026-11-11T00:00:00+00:00", disposition: .downloadable, baseline: true, autoOn: true, watermark: nil))
        XCTAssertTrue(AutoQueue.shouldQueue(isNew: true, pageIndex: 0, published: "2026-11-01T00:00:00+00:00", disposition: .downloadable, baseline: false, autoOn: true, watermark: "2026-11-10T00:00:00+00:00"))
        XCTAssertFalse(AutoQueue.shouldQueue(isNew: true, pageIndex: 2, published: "2026-10-01T00:00:00+00:00", disposition: .downloadable, baseline: false, autoOn: true, watermark: "2026-11-10T00:00:00+00:00"))
        XCTAssertTrue(AutoQueue.shouldQueue(isNew: true, pageIndex: 2, published: "2026-11-12T00:00:00+00:00", disposition: .downloadable, baseline: false, autoOn: true, watermark: "2026-11-10T00:00:00+00:00"))
        XCTAssertFalse(AutoQueue.shouldQueue(isNew: true, pageIndex: 0, published: nil, disposition: .members, baseline: false, autoOn: true, watermark: nil))
    }

    func testProgressiveMP4BeatsWebM() throws {
        let player = try json("player-progressive.json")
        let variants = StreamResolver.variants(from: player)
        let best = try XCTUnwrap(StreamResolver.select(variants, capHeight: nil))
        XCTAssertEqual(best.kind, "mp4")
        XCTAssertEqual(best.height, 720)
        XCTAssertTrue(best.url.contains("5Mz1a.gaa.1.mp4"))
        let capped = try XCTUnwrap(StreamResolver.select(variants, capHeight: 480))
        XCTAssertEqual(capped.kind, "mp4")
        XCTAssertEqual(capped.height, 480)
        XCTAssertTrue(capped.url.contains("5Mz1a.caa.2.mp4"))
        XCTAssertFalse(capped.url.contains(".webm"))
    }

    func testCurrentVideoIgnoresTimelinePreview() throws {
        let player = try json("player-alex.json")
        XCTAssertEqual(player["title"] as? String, "Nick Fuentes on the Alex Jones Show")
        let variants = StreamResolver.variants(from: player)
        XCTAssertTrue(variants.contains { $0.timeline && $0.url.hasSuffix(".mp4") })
        let best = try XCTUnwrap(StreamResolver.select(variants, capHeight: nil))
        XCTAssertEqual(best.kind, "tar")
        XCTAssertEqual(best.height, 1080)
        XCTAssertTrue(best.url.contains("Y57cB.haa.tar"))
        XCTAssertFalse(best.url.contains("Faa.mp4"))
        let mid = try XCTUnwrap(StreamResolver.select(variants, capHeight: 720))
        XCTAssertEqual(mid.height, 720)
        XCTAssertTrue(mid.url.contains("Y57cB.gaa.tar"))
        let small = try XCTUnwrap(StreamResolver.select(variants, capHeight: 180))
        XCTAssertGreaterThanOrEqual(small.height, 360)
        XCTAssertFalse(small.timeline)
        XCTAssertTrue(small.url.contains("Y57cB.oaa.tar"))
    }

    func testOEmbedAndPlaylists() throws {
        let payload = try json("oembed-alex.json")
        XCTAssertEqual(StreamResolver.embedID(fromOEmbed: payload), "v7fz69o")
        let base = URL(string: "https://hugh.cdn.rumble.cloud/video/fww1/05/s8/2/A/6/e/a/A6eaB.oaa.tar?r_file=chunklist.m3u8&r_range=1-2")!
        let media = HLSPlaylist.parse(try fixture("media-playlist.m3u8"), baseURL: base)
        XCTAssertFalse(media.master)
        XCTAssertEqual(media.segments.count, 3)
        XCTAssertFalse(media.encrypted)
        XCTAssertTrue(media.segments[0].url.absoluteString.contains("r_file=media-0.ts"))
        XCTAssertEqual(HLSPlaylist.byteLength(of: media.segments[0].url), 296423 - 512 + 1)
        let master = HLSPlaylist.parse(try fixture("master-playlist.m3u8"), baseURL: URL(string: "https://rumble.com/hls-vod/cLbBwPVzWHE/playlist.m3u8")!)
        XCTAssertTrue(master.master)
        XCTAssertEqual(HLSPlaylist.select(master.variants, capHeight: 720)?.height, 720)
        XCTAssertTrue(HLSPlaylist.select(master.variants, capHeight: 720)?.url.absoluteString.contains("A6eaB.gaa.tar") == true)
    }

    func testFeedNamesAndRetries() throws {
        let page = ListingParser.parse(html: try fixture("videos-tab-live.html"))
        let xml = FeedBuilder.rss(items: Array(page.items.prefix(2)), generatedAt: "2026-11-11T02:50:00Z")
        XCTAssertTrue(xml.contains("<link>https://rumble.com/c/nickjfuentes/videos</link>"))
        XCTAssertTrue(xml.contains("Nick Fuentes on the Alex Jones Show"))
        XCTAssertFalse(xml.contains("/livestreams"))
        XCTAssertEqual(FileNames.safe(title: "A/B: C?", id: "450098556", ext: "ts"), "AB C [450098556].ts")
        XCTAssertEqual(RetryPolicy.delay(for: 0), 30)
        XCTAssertEqual(RetryPolicy.delay(for: 4), 7200)
        XCTAssertFalse(RetryPolicy.shouldRetry(httpStatus: 404, attempt: 0))
        XCTAssertTrue(RetryPolicy.shouldRetry(httpStatus: 403, attempt: 1))
        XCTAssertFalse(RetryPolicy.shouldRetry(httpStatus: 503, attempt: 5))
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: ArchiveTests.self).url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func json(_ name: String) throws -> [String: Any] {
        let text = try fixture(name)
        let data = Data(text.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
