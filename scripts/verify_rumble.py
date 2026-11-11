#!/usr/bin/env python3
"""Fixture tests and a live check of the Nicholas J. Fuentes Videos tab.

Usage:
  python3 scripts/verify_rumble.py            # fixtures only
  python3 scripts/verify_rumble.py --live     # fixtures, then the live site
"""

from __future__ import annotations

import argparse
import json
import sys
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from rumble_parse import (  # noqa: E402
    ABOUT_PAGE,
    ALL_PAGE,
    EXPECTED_TOP_TITLES,
    LIVE_PAGE,
    SHORTS_PAGE,
    VIDEOS_PAGE,
    parse_listing,
    parse_oembed_embed_id,
    parse_playlist,
    retry_delay,
    rss_xml,
    safe_filename,
    segment_bytes,
    select_master_variant,
    select_variant,
    should_retry,
    variants_from_player,
)

FIXTURES = ROOT / "FuentesArchiveTests" / "Fixtures"


def load(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


class ListingTests(unittest.TestCase):
    def test_live_thumbnail_fixture_matches_screenshot_titles(self) -> None:
        page = parse_listing(load("videos-tab-live.html"), VIDEOS_PAGE)
        self.assertFalse(page.challenged)
        self.assertEqual(page.canonical, VIDEOS_PAGE)
        self.assertEqual(page.next_url, VIDEOS_PAGE + "?page=2")
        titles = [item.title for item in page.items]
        self.assertEqual(tuple(titles[:4]), EXPECTED_TOP_TITLES)
        self.assertEqual(len(page.items), 25)
        self.assertEqual(len({item.id for item in page.items}), 25)
        first = page.items[0]
        self.assertEqual(first.id, "450098556")
        self.assertEqual(first.permalink, "v7i5j76")
        self.assertEqual(first.duration, 4023)
        self.assertEqual(first.views, 83714)
        self.assertEqual(first.published, "2026-11-10T19:43:12+00:00")
        self.assertEqual(
            first.watch,
            "https://rumble.com/v7i5j76-nick-fuentes-on-the-alex-jones-show.html",
        )
        self.assertNotIn("e9s=", first.watch)
        self.assertTrue(first.thumb)
        self.assertEqual(first.channel_url, "https://rumble.com/c/nickjfuentes")
        self.assertTrue(all(item.disposition == "downloadable" for item in page.items))

    def test_server_json_filters_members_premieres_shorts_and_live(self) -> None:
        page = parse_listing(load("videos-grid-server.html"), VIDEOS_PAGE)
        titles = [(item.title, item.disposition) for item in page.items]
        self.assertEqual(
            titles,
            [
                ("MAKE THE GOYIM GREAT AGAIN!!!", "downloadable"),
                ("Governments Tell Citizens to Prepare for DISASTER", "downloadable"),
                ("Leftist Hackers DOX ICE Agents", "downloadable"),
                ("Members Only Strategy Stream", "members"),
                ("Upcoming Premiere Example", "premiere"),
            ],
        )
        self.assertNotIn("A Short That Must Be Ignored", [item.title for item in page.items])
        self.assertNotIn("Live Right Now", [item.title for item in page.items])
        self.assertNotIn("Wrong Object Type", [item.title for item in page.items])
        self.assertEqual(page.next_url, VIDEOS_PAGE + "?page=2")
        self.assertEqual(page.items[0].channel, "Nicholas J. Fuentes")
        self.assertEqual(page.items[0].id, "449349028")
        self.assertEqual(page.items[0].permalink, "v7hpguy")
        page_two = parse_listing(load("videos-grid-page2.html"), VIDEOS_PAGE + "?page=2")
        self.assertEqual(page_two.next_url, VIDEOS_PAGE + "?page=3")
        self.assertGreaterEqual(len(page_two.items), 4)
        self.assertTrue(set(item.id for item in page.items).isdisjoint(item.id for item in page_two.items))
        self.assertEqual(page_two.items[0].title, "I'M SICK OF THESE FREAKS!!!")
        self.assertEqual(page_two.items[0].id, "446564796")

    def test_cloudflare_challenge_is_not_an_empty_library(self) -> None:
        page = parse_listing("<html><title>Just a moment...</title><body>Performing security verification</body></html>")
        self.assertTrue(page.challenged)
        self.assertEqual(page.items, [])

    def test_auto_queue_rules(self) -> None:
        from rumble_parse import plan_sync
        new = {"id": "new", "disposition": "downloadable"}
        old = {"id": "old", "disposition": "downloadable"}
        member = {"id": "member", "disposition": "members"}
        spilled = {"id": "spilled", "disposition": "downloadable"}
        queue, seen = plan_sync([[new, member], [spilled, old], [old]], {"old"}, baseline=False, auto_on=True, max_pages=10)
        self.assertEqual(queue, ["new", "spilled"])
        self.assertEqual(seen, ["new", "member", "spilled"])
        baseline_queue, baseline_seen = plan_sync([[new]], set(), baseline=True, auto_on=True, max_pages=2)
        self.assertEqual(baseline_queue, [])
        self.assertEqual(baseline_seen, ["new"])
        self.assertEqual(plan_sync([[old]], {"old"}, baseline=False, auto_on=True, max_pages=10)[0], [])


class StreamTests(unittest.TestCase):
    def test_progressive_mp4_beats_webm_and_respects_cap(self) -> None:
        player = json.loads(load("player-progressive.json"))
        variants = variants_from_player(player)
        best = select_variant(variants, None)
        self.assertIsNotNone(best)
        assert best is not None
        self.assertEqual(best.kind, "mp4")
        self.assertEqual(best.height, 720)
        self.assertIn("5Mz1a.gaa.1.mp4", best.url)
        capped = select_variant(variants, 480)
        assert capped is not None
        self.assertEqual(capped.height, 480)
        self.assertEqual(capped.kind, "mp4")
        self.assertIn("5Mz1a.caa.2.mp4", capped.url)
        self.assertNotIn(".webm", capped.url)

    def test_current_video_ignores_timeline_mp4_and_picks_quality(self) -> None:
        player = json.loads(load("player-alex.json"))
        self.assertEqual(player["title"], EXPECTED_TOP_TITLES[0])
        variants = variants_from_player(player)
        self.assertTrue(any(item.timeline and item.url.endswith(".mp4") for item in variants))
        best = select_variant(variants, None)
        assert best is not None
        self.assertEqual(best.kind, "tar")
        self.assertEqual(best.height, 1080)
        self.assertIn("Y57cB.haa.tar", best.url)
        self.assertNotIn("Faa.mp4", best.url)
        mid = select_variant(variants, 720)
        assert mid is not None
        self.assertEqual(mid.height, 720)
        self.assertIn("Y57cB.gaa.tar", mid.url)
        small = select_variant(variants, 180)
        assert small is not None
        self.assertGreaterEqual(small.height, 360)
        self.assertFalse(small.timeline)
        self.assertNotIn("Faa.mp4", small.url)
        self.assertIn("Y57cB.oaa.tar", small.url)

    def test_oembed_embed_id(self) -> None:
        payload = json.loads(load("oembed-alex.json"))
        self.assertEqual(payload["author_url"], "https://rumble.com/c/nickjfuentes")
        self.assertEqual(parse_oembed_embed_id(payload), "v7fz69o")

    def test_hls_media_and_master_playlists(self) -> None:
        media = parse_playlist(load("media-playlist.m3u8"), "https://hugh.cdn.rumble.cloud/video/fww1/05/s8/2/A/6/e/a/A6eaB.oaa.tar?r_file=chunklist.m3u8&r_range=1-2")
        self.assertFalse(media["master"])
        self.assertEqual(len(media["segments"]), 3)
        self.assertFalse(media["encrypted"])
        first = media["segments"][0]["url"]
        self.assertIn("r_file=media-0.ts", first)
        self.assertTrue(first.startswith("https://hugh.cdn.rumble.cloud/video/fww1/05/s8/2/A/6/e/a/A6eaB.oaa.tar?"))
        self.assertEqual(segment_bytes(first), 296423 - 512 + 1)
        master = parse_playlist(load("master-playlist.m3u8"), "https://rumble.com/hls-vod/cLbBwPVzWHE/playlist.m3u8")
        self.assertTrue(master["master"])
        heights = sorted(item["height"] for item in master["variants"])
        self.assertIn(1080, heights)
        self.assertIn(720, heights)
        self.assertIn(480, heights)
        chosen = select_master_variant(master["variants"], 720)
        assert chosen is not None
        self.assertEqual(chosen["height"], 720)
        self.assertIn("A6eaB.gaa.tar", chosen["url"])

    def test_rss_retry_and_filenames(self) -> None:
        page = parse_listing(load("videos-tab-live.html"))
        xml = rss_xml(page.items[:2], "2026-11-11T02:50:00+00:00")
        self.assertIn("<link>https://rumble.com/c/nickjfuentes/videos</link>", xml)
        self.assertIn(EXPECTED_TOP_TITLES[0], xml)
        self.assertNotIn("/livestreams", xml)
        self.assertEqual(safe_filename("A/B: C?", "450098556", "ts"), "AB C [450098556].ts")
        self.assertEqual(retry_delay(0), 30)
        self.assertEqual(retry_delay(4), 7200)
        self.assertFalse(should_retry(404, 0))
        self.assertTrue(should_retry(403, 1))
        self.assertFalse(should_retry(503, 5))

    def test_remux_real_segment_decodes(self) -> None:
        import shutil
        import subprocess
        from ts_remux import remux
        source = FIXTURES / "segment.ts"
        destination = Path("/tmp/archive-remux-test.mp4")
        media = remux([source], destination)
        self.assertEqual((media.width, media.height), (640, 360))
        self.assertGreater(len(media.video), 50)
        self.assertGreater(len(media.audio), 50)
        if shutil.which("ffmpeg"):
            subprocess.check_call(
                ["ffmpeg", "-v", "error", "-i", str(destination), "-f", "null", "-"],
                stdout=subprocess.DEVNULL,
            )


class LiveTests(unittest.TestCase):
    def test_live_videos_tab(self) -> None:
        html = fetch_html(VIDEOS_PAGE)
        page = parse_listing(html, VIDEOS_PAGE)
        self.assertFalse(page.challenged, "Videos tab returned a Cloudflare challenge")
        titles = [item.title for item in page.items]
        self.assertGreaterEqual(len(titles), 4, titles[:8])
        self.assertEqual(tuple(titles[:4]), EXPECTED_TOP_TITLES)
        self.assertEqual(page.canonical, VIDEOS_PAGE)
        self.assertEqual(page.next_url, VIDEOS_PAGE + "?page=2")
        self.assertGreaterEqual(len(page.items), 20)
        self.assertIn("page=48", html)
        video_ids = {item.id for item in page.items}
        page_two_note = "not fetched"
        try:
            page_two_html = fetch_html(VIDEOS_PAGE + "?page=2")
            page_two = parse_listing(page_two_html, VIDEOS_PAGE + "?page=2")
            if page_two.challenged or not page_two.items:
                page_two_note = "Cloudflare blocked the rendered page; pagination links on page 1 were checked instead"
            else:
                self.assertNotEqual(page_two.items[0].id, page.items[0].id)
                self.assertNotIn(page_two.items[0].title, EXPECTED_TOP_TITLES)
                page_two_note = f"starts with {page_two.items[0].title} ({len(page_two.items)} items)"
        except AssertionError as exc:
            if "Cloudflare" not in str(exc) and "failed to fetch" not in str(exc):
                raise
            page_two_note = f"reader could not render page 2 ({exc}). Page 1 exposes rel=next and links through page 48."
        short_note = "not fetched"
        live_note = "not fetched"
        try:
            shorts = parse_listing(fetch_html(SHORTS_PAGE), SHORTS_PAGE)
            short_ids = {item.id for item in shorts.items}
            self.assertTrue(video_ids.isdisjoint(short_ids), sorted(video_ids & short_ids)[:5])
            short_note = f"{len(shorts.items)} items, overlap {len(video_ids & short_ids)}"
        except AssertionError as exc:
            if "Cloudflare" not in str(exc) and "failed to fetch" not in str(exc):
                raise
            short_note = f"could not render ({exc})"
        try:
            lives = parse_listing(fetch_html(LIVE_PAGE), LIVE_PAGE)
            live_ids = {item.id for item in lives.items}
            live_note = f"{len(lives.items)} items, overlap {len(video_ids & live_ids)}"
        except AssertionError as exc:
            if "Cloudflare" not in str(exc) and "failed to fetch" not in str(exc):
                raise
            live_note = f"could not render ({exc})"
        print(f"\nVideos page 1: {len(page.items)} items, next={page.next_url}")
        print("Top titles:")
        for item in page.items[:4]:
            print(f"  - {item.title}  id={item.id}  {item.duration}s  {item.views} views")
        print(f"Page 2: {page_two_note}")
        print(f"Shorts: {short_note}")
        print(f"Live: {live_note}")

    def test_live_stream_resolution(self) -> None:
        watch = "https://rumble.com/v7i5j76-nick-fuentes-on-the-alex-jones-show.html"
        payload = json.loads(fetch_bytes("https://rumble.com/api/Media/oembed.json?url=" + watch).decode())
        embed_id = parse_oembed_embed_id(payload)
        self.assertEqual(embed_id, "v7fz69o")
        self.assertEqual(payload["author_url"], "https://rumble.com/c/nickjfuentes")
        embed_html = fetch_html(f"https://rumble.com/embed/{embed_id}")
        from rumble_parse import extract_player_object

        player = extract_player_object(embed_html)
        self.assertEqual(player["title"], EXPECTED_TOP_TITLES[0])
        variants = variants_from_player(player)
        heights = sorted({item.height for item in variants if not item.timeline and not item.audio_only and item.height})
        self.assertIn(1080, heights)
        self.assertIn(720, heights)
        self.assertGreaterEqual(len(heights), 3)
        best = select_variant(variants, None)
        assert best is not None
        self.assertEqual(best.height, 1080)
        self.assertNotEqual(best.kind, "timeline")
        self.assertFalse(best.url.endswith(".mp4") and "timeline" in best.url)
        # Timeline preview must not win just because it is an MP4.
        self.assertFalse(best.timeline)
        print(f"Qualities for {EXPECTED_TOP_TITLES[0]}: {heights}")
        print(f"Selected best: {best.kind} {best.height}p {best.bitrate}kbps {best.size} bytes")

    def test_removed_feeds_and_no_public_listing_api(self) -> None:
        for path in ("/feeds/c/nickjfuentes", "/feeds/user/nickjfuentes", "/feeds/channel/nickjfuentes"):
            status = status_only("https://rumble.com" + path)
            self.assertEqual(status, 410, path)
        listing = status_only("https://rumble.com/api/Media/list?channel=nickjfuentes&type=videos")
        # The route exists but requires a signed-in user. It is not a public listing.
        self.assertIn(listing, {200, 401, 403})
        print("\nFeed routes /feeds/{c,user,channel}/nickjfuentes -> 410 Gone")


def fetch_html(url: str) -> str:
    return fetch_bytes(url).decode("utf-8", "replace")


def fetch_bytes(url: str) -> bytes:
    direct_error = None
    try:
        return _request(url)
    except Exception as exc:  # noqa: BLE001 - fall back to the reader proxy
        direct_error = exc
        body = _request(url).lower() if False else b""
    # Channel HTML is often a Cloudflare challenge from this network.
    # r.jina.ai renders it. oEmbed and embed pages usually work directly.
    try:
        # Quote the target so ?page= stays part of the Rumble URL, not the reader URL.
        rendered = _request(
            "https://r.jina.ai/" + urllib.parse.quote(url, safe=":/"),
            {"X-Return-Format": "html", "Accept": "text/html"},
        )
    except Exception as exc:  # noqa: BLE001
        raise AssertionError(f"failed to fetch {url}: direct={direct_error}; reader={exc}") from exc
    text = rendered.decode("utf-8", "replace")
    if "Just a moment" in text[:4000] and "rum-video-thumbnail" not in text and "application/json" not in text:
        raise AssertionError(f"Cloudflare challenge for {url} ({direct_error})")
    return rendered


def _request(url: str, headers: dict | None = None) -> bytes:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
            "Accept": "text/html,application/json,application/vnd.apple.mpegurl,*/*",
            "Accept-Language": "en-US,en;q=0.9",
            **(headers or {}),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read()
        if exc.code == 410:
            return body
        raise


def status_only(url: str) -> int:
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "FuentesArchiveVerifier/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=45) as response:
            response.read(200)
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true", help="also fetch rumble.com")
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    if not args.live:
        suite = unittest.TestSuite(test for test in _iter(suite) if test.__class__.__name__ != "LiveTests")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
    print("\nChannel slug: nickjfuentes")
    print(f"Videos tab: {VIDEOS_PAGE}")
    print(f"Shorts:     {SHORTS_PAGE}")
    print(f"Live:       {LIVE_PAGE}")
    print(f"About:      {ABOUT_PAGE}")
    print(f"All:        {ALL_PAGE}")


def _iter(suite: unittest.TestSuite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from _iter(item)
        else:
            yield item


if __name__ == "__main__":
    main()
