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
        // Compare the fields separately. A tuple does not satisfy XCTAssertEqual's Equatable constraint.
        XCTAssertEqual(page.items.map(\.title), [
            "MAKE THE GOYIM GREAT AGAIN!!!",
            "Governments Tell Citizens to Prepare for DISASTER",
            "Leftist Hackers DOX ICE Agents",
            "Members Only Strategy Stream",
            "Upcoming Premiere Example"
        ])
        XCTAssertEqual(page.items.map(\.disposition), [
            .downloadable, .downloadable, .downloadable, .members, .premiere
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

    func testSyncPlanKeepsBackCatalogAndStillCatchesSpill() {
        let new = SyncVideo(id: "new", disposition: .downloadable)
        let old = SyncVideo(id: "old", disposition: .downloadable)
        let member = SyncVideo(id: "member", disposition: .members)
        let spilled = SyncVideo(id: "spilled", disposition: .downloadable)
        let decision = AutoQueue.plan(
            pages: [[new, member], [spilled, old], [old]],
            known: ["old"],
            baseline: false,
            autoOn: true,
            maxPages: 10
        )
        XCTAssertEqual(decision.queue, ["new", "spilled"])
        XCTAssertEqual(decision.seen, ["new", "member", "spilled"])
        let baseline = AutoQueue.plan(pages: [[new]], known: [], baseline: true, autoOn: true, maxPages: 2)
        XCTAssertTrue(baseline.queue.isEmpty)
        XCTAssertEqual(baseline.seen, ["new"])
        let quiet = AutoQueue.plan(pages: [[old]], known: ["old"], baseline: false, autoOn: true, maxPages: 10)
        XCTAssertTrue(quiet.queue.isEmpty)
    }

    func testRemuxesRealSegmentToMP4() throws {
        let source = try XCTUnwrap(Bundle(for: ArchiveTests.self).url(forResource: "segment", withExtension: "ts"))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("remux-test.mp4")
        let info = try TSRemuxer.remux(files: [source], to: destination)
        XCTAssertEqual(info.width, 640)
        XCTAssertEqual(info.height, 360)
        XCTAssertGreaterThan(info.videoSamples, 50)
        XCTAssertGreaterThan(info.audioSamples, 50)
        let header = try Data(contentsOf: destination).prefix(8)
        XCTAssertEqual(String(decoding: header.dropFirst(4), as: UTF8.self), "ftyp")
        let blob = try Data(contentsOf: destination)
        XCTAssertTrue(blob.range(of: Data("avc1".utf8)) != nil)
        XCTAssertTrue(blob.range(of: Data("mp4a".utf8)) != nil)
        try? FileManager.default.removeItem(at: destination)
    }

    func testPlaylistRelativeURLKeepsTheTarQuery() {
        let base = URL(string: "https://hugh.cdn.rumble.cloud/video/a/A6eaB.oaa.tar?r_file=chunklist.m3u8&r_range=1-2")!
        let resolved = HLSPlaylist.resolve("A6eaB.oaa.tar?r_file=media-0.ts&r_type=video%2Fmp2t&r_range=512-296423", base: base)
        XCTAssertEqual(
            resolved?.absoluteString,
            "https://hugh.cdn.rumble.cloud/video/a/A6eaB.oaa.tar?r_file=media-0.ts&r_type=video%2Fmp2t&r_range=512-296423"
        )
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
        XCTAssertEqual(best.kind, "hls")
        XCTAssertTrue(best.url.contains("playlist.m3u8"))
        XCTAssertFalse(best.timeline)
        XCTAssertFalse(best.url.contains("Faa.mp4"))
        XCTAssertFalse(best.url.contains(".tar"))
        let capped = try XCTUnwrap(StreamResolver.select(variants, capHeight: 180))
        XCTAssertEqual(capped.kind, "hls")
        XCTAssertFalse(capped.timeline)
    }

    func testProgressiveFileBeatsTarPlaylist() {
        let mp4 = Variant(kind: "mp4", height: 720, bitrate: 2000, size: 50_000_000, url: "https://cdn.example/a.gaa.mp4", timeline: false, audioOnly: false)
        let tar = Variant(kind: "tar", height: 1080, bitrate: 4000, size: 90_000_000, url: "https://cdn.example/a.haa.tar?r_file=chunklist.m3u8", timeline: false, audioOnly: false)
        let chosen = StreamResolver.select([tar, mp4], capHeight: nil)
        XCTAssertEqual(chosen?.kind, "mp4")
        XCTAssertEqual(chosen?.height, 720)
        XCTAssertTrue(DownloadOffers.isDirectFile(mp4.url))
        XCTAssertFalse(DownloadOffers.isDirectFile(tar.url))
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

    func testDownloadOffersUseExactSizesAndKeepEveryHeight() throws {
        let player = try json("player-alex.json")
        let choices = DownloadOffers.build(variants: StreamResolver.variants(from: player), duration: 4023)
        let video = choices.filter { !$0.audioOnly }
        XCTAssertEqual(video.map(\.height), [360, 480, 720, 1080])
        XCTAssertEqual(video.map(\.estimated), [false, false, false, false])
        XCTAssertEqual(video.map(\.detail), ["HLS", "HLS", "HLS", "HLS"])
        XCTAssertEqual(video.map(\.bytes), [341_995_520, 532_541_440, 1_076_561_920, 2_070_835_200])
        XCTAssertTrue(video.allSatisfy { $0.bytes > 1_000_000 })
        let progressive = DownloadOffers.build(variants: StreamResolver.variants(from: try json("player-progressive.json")), duration: 234)
        let files = progressive.filter { !$0.audioOnly }
        XCTAssertEqual(files.map(\.height), [360, 480, 720])
        XCTAssertEqual(files.map(\.kind), ["mp4", "mp4", "mp4"])
        XCTAssertEqual(files.map(\.bytes), [18_488_017, 23_720_936, 57_283_801])
        XCTAssertFalse(files.contains { $0.detail == "MPEG-TS" })
        let audio = choices.filter(\.audioOnly)
        XCTAssertEqual(audio.count, 1)
        XCTAssertEqual(audio.map(\.bytes), [96_550_801])
        XCTAssertEqual(audio.map(\.estimated), [false])
        XCTAssertEqual(audio.map(\.container), ["m4a"])
        let exact = DownloadOffers.estimate(exact: 50, bitrateKbps: 1000, duration: 8)
        XCTAssertEqual(exact.bytes, 50)
        XCTAssertFalse(exact.estimated)
        let guessed = DownloadOffers.estimate(exact: 0, bitrateKbps: 1000, duration: 8)
        XCTAssertEqual(guessed.bytes, 1_000_000)
        XCTAssertTrue(guessed.estimated)
        let unknown = DownloadOffers.estimate(exact: 0, bitrateKbps: 0, duration: nil)
        XCTAssertEqual(unknown.bytes, 0)
        XCTAssertTrue(unknown.estimated)
    }

    func testPlaylistByteSumReplacesAnEstimate() throws {
        let playlist = try fixture("media-playlist.m3u8")
        let summed = DownloadOffers.summedRangeBytes(playlist)
        XCTAssertEqual(summed, 295_912 + 298_168 + 290_460)
        let seed = DownloadChoice(
            id: "video-360-mp4", title: "360p", detail: "MP4", height: 360, audioOnly: false,
            container: "mp4", kind: "tar", url: "https://example.invalid/a", bitrate: 680,
            bytes: 1, estimated: true
        )
        let applied = DownloadOffers.applyingPlaylistBytes(seed, playlistBytes: summed)
        XCTAssertEqual(applied.bytes, summed)
        XCTAssertFalse(applied.estimated)
        XCTAssertEqual(DownloadOffers.applyingPlaylistBytes(seed, playlistBytes: 0).estimated, true)
    }

    func testSavedLibraryWithoutRequestStillDecodes() throws {
        let json = """
        {"id":"1","permalink":"v1","title":"T","watchURL":"https://rumble.com/v1","disposition":"downloadable","status":"paused","progress":0.25,"bytesWritten":10,"bytesExpected":40,"attemptCount":0,"segmentTotal":4,"segmentDone":1,"updatedAt":"2026-11-11T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(VideoRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.status, .paused)
        XCTAssertNil(record.request)
        XCTAssertEqual(record.bytesPerSecond, 0)
        XCTAssertEqual(record.segmentDone, 1)
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
