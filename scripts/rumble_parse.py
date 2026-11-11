"""Parse Rumble Videos-tab listings and player JSON.

Rumble does not publish a channel RSS feed. ``/feeds/c/{slug}``,
``/feeds/user/{slug}`` and ``/feeds/channel/{slug}`` answer HTTP 410 Gone.
Authenticated endpoints such as ``/api/Media/list`` are not usable here.
The Videos tab HTML is the listing source:

* Server HTML embeds ``<rum-videos-grid><script type="application/json">``.
* After client render, the same items exist as ``<rum-video-thumbnail>`` tags.
* Per-video MP4/HLS URLs come from oEmbed (embed id) plus the embed player
  object. The listing ``eid`` field is not an embed id.

This module is the contract the Swift parser mirrors. Both are checked
against the fixtures in ``FuentesArchiveTests/Fixtures``.
"""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from datetime import datetime
from html import unescape
from typing import Any, Iterable, Optional
from urllib.parse import urljoin, urlparse, urlunparse, parse_qsl, urlencode

CHANNEL_SLUG = "nickjfuentes"
CHANNEL_NAME = "Nicholas J. Fuentes"
VIDEOS_PAGE = "https://rumble.com/c/nickjfuentes/videos"
SHORTS_PAGE = "https://rumble.com/c/nickjfuentes/shorts"
LIVE_PAGE = "https://rumble.com/c/nickjfuentes/livestreams"
ABOUT_PAGE = "https://rumble.com/c/nickjfuentes/about"
ALL_PAGE = "https://rumble.com/c/nickjfuentes"

# Titles at the top of the Videos tab on 2026-11-11 (see the channel screenshot).
EXPECTED_TOP_TITLES = (
    "Nick Fuentes on the Alex Jones Show",
    "Trump CUCKS on Deportations, Embraces AMNESTY",
    "I WAS RIGHT ABOUT EVERYTHING!!!",
    "Trump BLAMES Voters for Crushing Defeat",
)

DOWNLOADABLE = "downloadable"
MEMBERS = "members"
PREMIERE = "premiere"
LIVE = "live"
SHORT = "short"
PROCESSING = "processing"
IGNORED = "ignored"

_LIVE_STATUSES = {"live", "streaming"}
_PREMIERE_STATUSES = {"upcoming", "scheduled", "premiere", "waiting"}
_PUBLIC_VISIBILITY = {"", "public"}


@dataclass
class ListedVideo:
    id: str
    permalink: str
    title: str
    watch: str
    thumb: Optional[str]
    published: Optional[str]
    duration: Optional[float]
    views: Optional[int]
    disposition: str
    channel: Optional[str] = None
    channel_url: Optional[str] = None

    def to_json(self) -> dict:
        return asdict(self)


@dataclass
class ListingPage:
    items: list[ListedVideo] = field(default_factory=list)
    next_url: Optional[str] = None
    canonical: Optional[str] = None
    challenged: bool = False

    def to_json(self) -> dict:
        return {
            "next": self.next_url,
            "canonical": self.canonical,
            "challenged": self.challenged,
            "items": [item.to_json() for item in self.items],
        }


@dataclass
class Variant:
    kind: str  # mp4, webm, hls, tar
    height: int
    bitrate: int
    size: int
    url: str
    timeline: bool = False
    audio_only: bool = False

    def to_json(self) -> dict:
        return asdict(self)


def strip_tracking(url: str) -> str:
    if not url:
        return url
    parts = urlparse(url)
    if not parts.query:
        return urlunparse(parts)
    kept = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k != "e9s"]
    query = urlencode(kept)
    return urlunparse(parts._replace(query=query))


def permalink_from_url(url: str) -> str:
    path = urlparse(url).path
    match = re.search(r"/(v[0-9a-z]+)(?:-|\.|$)", path, re.I)
    return match.group(1) if match else ""


def _brace_object(text: str, start: int) -> str:
    if start >= len(text) or text[start] != "{":
        raise ValueError("expected object")
    depth = 0
    in_str = False
    esc = False
    for index in range(start, len(text)):
        char = text[index]
        if in_str:
            if esc:
                esc = False
            elif char == "\\":
                esc = True
            elif char == '"':
                in_str = False
            continue
        if char == '"':
            in_str = True
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    raise ValueError("unterminated object")


def _attrs(tag: str) -> dict[str, str]:
    found: dict[str, str] = {}
    for key, value in re.findall(r'([^\s=/>]+)="([^"]*)"', tag):
        found[key] = unescape(value)
    return found


def _thumbnail_tags(html: str) -> Iterable[str]:
    needle = "<rum-video-thumbnail"
    start = 0
    while True:
        index = html.find(needle, start)
        if index < 0:
            return
        cursor = index + len(needle)
        in_str = False
        while cursor < len(html):
            char = html[cursor]
            if char == '"':
                in_str = not in_str
            elif char == ">" and not in_str:
                yield html[index : cursor + 1]
                start = cursor + 1
                break
            cursor += 1
        else:
            return


def _json_listings(html: str) -> list[dict]:
    payloads: list[dict] = []
    for match in re.finditer(r"<script[^>]*type=[\"']application/json[\"'][^>]*>", html, re.I):
        body_start = match.end()
        body_end = html.find("</script>", body_start)
        if body_end < 0:
            continue
        body = unescape(html[body_start:body_end]).strip()
        if not body.startswith("{"):
            continue
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            continue
        if isinstance(data, dict) and isinstance(data.get("items"), list):
            payloads.append(data)
    return payloads


def _canonical(html: str) -> Optional[str]:
    match = re.search(r'rel=["\']canonical["\'][^>]*href=["\']([^"\']+)', html, re.I)
    if not match:
        match = re.search(r'href=["\']([^"\']+)["\'][^>]*rel=["\']canonical["\']', html, re.I)
    return unescape(match.group(1)) if match else None


def _next_url(html: str, page_url: str) -> Optional[str]:
    rel = re.search(r'rel=["\']next["\'][^>]*href=["\']([^"\']+)', html, re.I)
    if not rel:
        rel = re.search(r'href=["\']([^"\']+)["\'][^>]*rel=["\']next["\']', html, re.I)
    if rel:
        return urljoin(page_url, unescape(rel.group(1)))
    current = _page_number(page_url)
    numbers = []
    for href in re.findall(r'href=["\']([^"\']+)["\']', html, re.I):
        absolute = urljoin(page_url, unescape(href))
        if "/videos" not in urlparse(absolute).path:
            continue
        number = _page_number(absolute)
        if number > current:
            numbers.append((number, absolute))
    if not numbers:
        return None
    numbers.sort()
    return numbers[0][1]


def _page_number(url: str) -> int:
    query = dict(parse_qsl(urlparse(url).query))
    try:
        return max(1, int(query.get("page", "1")))
    except ValueError:
        return 1


def challenged(html: str) -> bool:
    sample = html[:8000].lower()
    return (
        "just a moment" in sample
        or "cf-browser-verification" in sample
        or "performing security verification" in sample
        or "challenge-platform" in sample
    )


def _disposition(item: dict) -> str:
    object_type = str(item.get("object_type") or "video").lower()
    if object_type not in {"video", ""}:
        return IGNORED
    if item.get("is_short") is True:
        return SHORT
    status = str(item.get("livestream_status") or "").lower()
    if item.get("live") is True or status in _LIVE_STATUSES:
        return LIVE
    if item.get("live_placeholder") is True or status in _PREMIERE_STATUSES:
        return PREMIERE
    visibility = str(item.get("visibility") or "public").lower()
    availability = str(item.get("availability") or "").lower()
    if visibility not in _PUBLIC_VISIBILITY or availability in {"premium", "subscribers", "members", "private"}:
        return MEMBERS
    if item.get("is_processing") is True:
        return PROCESSING
    return DOWNLOADABLE


def _from_json_item(item: dict) -> Optional[ListedVideo]:
    if not isinstance(item, dict):
        return None
    disposition = _disposition(item)
    if disposition in {SHORT, LIVE, IGNORED}:
        return None
    watch = strip_tracking(str(item.get("url") or ""))
    if watch.startswith("/"):
        watch = urljoin("https://rumble.com", watch)
    permalink = str(item.get("permalink_id") or "") or permalink_from_url(watch)
    raw_id = item.get("id")
    video_id = str(raw_id) if raw_id else permalink
    if not video_id or not item.get("title"):
        return None
    by = item.get("by") if isinstance(item.get("by"), dict) else {}
    published = item.get("upload_date") or item.get("live_datetime")
    duration = item.get("duration")
    views = item.get("views")
    return ListedVideo(
        id=video_id,
        permalink=permalink,
        title=unescape(str(item["title"])).strip(),
        watch=watch,
        thumb=item.get("thumb") or None,
        published=str(published) if published else None,
        duration=float(duration) if isinstance(duration, (int, float)) else None,
        views=int(views) if isinstance(views, (int, float)) else None,
        disposition=disposition,
        channel=(by or {}).get("name"),
        channel_url=(by or {}).get("url"),
    )


def _from_thumbnail(tag: str) -> Optional[ListedVideo]:
    attrs = _attrs(tag)
    title = (attrs.get("video-title") or "").strip()
    watch = strip_tracking(attrs.get("url") or "")
    if watch.startswith("/"):
        watch = urljoin("https://rumble.com", watch)
    if not title or not watch:
        return None
    kind = (attrs.get("kind") or "").lower()
    if "short" in kind or "/shorts" in watch:
        return None
    permalink = permalink_from_url(watch)
    video_id = attrs.get("video-id") or permalink
    scheduled = (attrs.get("scheduled-time") or "").strip()
    disposition = DOWNLOADABLE
    if scheduled:
        disposition = PREMIERE
    duration = _float_or_none(attrs.get("duration"))
    if duration == 0 and scheduled:
        disposition = PREMIERE
    channel = attrs.get("name") or attrs.get("creator-name")
    return ListedVideo(
        id=str(video_id),
        permalink=permalink,
        title=title,
        watch=watch,
        thumb=attrs.get("src") or None,
        published=attrs.get("time") or None,
        duration=duration,
        views=_int_or_none(attrs.get("views")),
        disposition=disposition,
        channel=channel,
        channel_url=attrs.get("creator-url"),
    )


def _float_or_none(value: Optional[str]) -> Optional[float]:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def _int_or_none(value: Optional[str]) -> Optional[int]:
    if value is None or value == "":
        return None
    try:
        return int(float(value))
    except ValueError:
        return None


def _merge(existing: ListedVideo, incoming: ListedVideo) -> ListedVideo:
    """Thumbnail markup repeats each card. Keep the copy that has duration."""
    if existing.duration is None and incoming.duration is not None:
        return incoming
    if incoming.duration is None and existing.duration is not None:
        return existing
    if existing.views is None and incoming.views is not None:
        return incoming
    return existing


def parse_listing(html: str, page_url: str = VIDEOS_PAGE) -> ListingPage:
    page = ListingPage(canonical=_canonical(html), next_url=_next_url(html, page_url))
    if challenged(html):
        page.challenged = True
        return page
    merged: dict[str, ListedVideo] = {}
    order: list[str] = []

    def add(item: Optional[ListedVideo]) -> None:
        if item is None:
            return
        key = item.id or item.permalink or item.watch
        if key in merged:
            merged[key] = _merge(merged[key], item)
            return
        merged[key] = item
        order.append(key)

    payloads = _json_listings(html)
    if payloads:
        for payload in payloads:
            for raw in payload.get("items") or []:
                add(_from_json_item(raw))
    else:
        for tag in _thumbnail_tags(html):
            add(_from_thumbnail(tag))
    page.items = [merged[key] for key in order]
    return page


def parse_oembed_embed_id(payload: dict) -> str:
    html = str(payload.get("html") or "")
    match = re.search(r"/embed/([0-9a-zA-Z]+)", html)
    if not match:
        raise ValueError("oEmbed payload has no embed id")
    return match.group(1)


def extract_player_object(html: str) -> dict:
    """Pull the embed player object out of an embed HTML page.

    The assignment looks like ``p.f["v7fz69o"]={... ,loaded:v()}``.
    ``loaded:v()`` is JavaScript, not JSON, and is stripped.
    """
    match = re.search(r'p\.f\[[^\]]+\]\s*=\s*\{', html)
    if not match:
        match = re.search(r'"ua"\s*:\s*\{', html)
        if not match:
            raise ValueError("player object not found")
        # Fall back to the surrounding object if the assignment was already extracted.
        start = html.rfind("{", 0, match.start())
        raw = _brace_object(html, start)
    else:
        raw = _brace_object(html, match.end() - 1)
    raw = re.sub(r",\s*loaded\s*:\s*v\(\)\s*", "", raw)
    return json.loads(raw)


def _height(key: Any, info: dict) -> int:
    meta = info.get("meta") if isinstance(info.get("meta"), dict) else {}
    height = meta.get("h")
    if isinstance(height, (int, float)) and height > 0:
        return int(height)
    if isinstance(key, str) and key.isdigit():
        return int(key)
    return 0


def variants_from_player(player: dict) -> list[Variant]:
    ua = player.get("ua") if isinstance(player.get("ua"), dict) else {}
    found: list[Variant] = []
    for kind, group in ua.items():
        if not isinstance(group, dict):
            continue
        entries = group.items()
        # A single stream is stored directly, without a quality key.
        if "url" in group and isinstance(group.get("url"), str):
            entries = [(kind, group)]
        for key, info in entries:
            if not isinstance(info, dict) or not info.get("url"):
                continue
            meta = info.get("meta") if isinstance(info.get("meta"), dict) else {}
            height = _height(key, info)
            bitrate = int(meta.get("bitrate") or 0)
            size = int(meta.get("size") or 0)
            timeline = kind == "timeline"
            audio_only = kind == "audio" or (height <= 0 and kind != "hls" and not timeline)
            found.append(
                Variant(
                    kind=str(kind),
                    height=height,
                    bitrate=bitrate,
                    size=size,
                    url=str(info["url"]).replace("\\/", "/"),
                    timeline=timeline,
                    audio_only=audio_only,
                )
            )
    return found


def select_variant(variants: Iterable[Variant], cap_height: Optional[int]) -> Optional[Variant]:
    """Pick a real video stream.

    Timeline MP4s are low-bitrate scrub previews, not the movie.
    Separate AAC tracks are not a video. Progressive MP4/WebM wins over
    HLS/tar when both exist, because it is one file.
    """
    usable = [item for item in variants if not item.timeline and not item.audio_only and item.height > 0 and item.url]
    progressive = [item for item in usable if item.kind in {"mp4", "webm"}]
    pool = progressive or usable
    if not pool:
        fallback = [item for item in variants if item.kind == "hls" and item.url and not item.timeline]
        return fallback[0] if fallback else None

    def rank(item: Variant) -> tuple:
        container = {"mp4": 3, "webm": 2, "hls": 1, "tar": 1}.get(item.kind, 0)
        return (item.height, item.bitrate, container)

    if cap_height is None:
        return max(pool, key=rank)
    under = [item for item in pool if item.height <= cap_height]
    if under:
        return max(under, key=rank)
    return min(pool, key=lambda item: (item.height, item.bitrate))


def parse_playlist(text: str, base_url: str) -> dict:
    variants = []
    segments = []
    init_url = None
    encrypted = False
    pending_stream: Optional[dict] = None
    pending_duration: Optional[float] = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("#EXT-X-STREAM-INF"):
            bandwidth = _attr_int(line, "BANDWIDTH")
            resolution = _attr(line, "RESOLUTION") or ""
            width, height = 0, 0
            if "x" in resolution.lower():
                w, h = resolution.lower().split("x", 1)
                width, height = int(w or 0), int(h or 0)
            pending_stream = {"bandwidth": bandwidth, "width": width, "height": height}
            pending_duration = None
        elif line.startswith("#EXTINF"):
            try:
                pending_duration = float(line.split(":", 1)[1].split(",")[0])
            except ValueError:
                pending_duration = 0
            pending_stream = None
        elif line.startswith("#EXT-X-MAP"):
            uri = _attr(line, "URI")
            if uri:
                init_url = urljoin(base_url, uri)
        elif line.startswith("#EXT-X-KEY"):
            method = (_attr(line, "METHOD") or "").upper()
            if method and method != "NONE":
                encrypted = True
        elif line.startswith("#"):
            continue
        else:
            absolute = urljoin(base_url, line)
            if pending_stream is not None:
                pending_stream["url"] = absolute
                variants.append(pending_stream)
                pending_stream = None
            elif pending_duration is not None:
                segments.append({"duration": pending_duration, "url": absolute})
                pending_duration = None
    return {
        "master": bool(variants),
        "variants": variants,
        "segments": segments,
        "init": init_url,
        "encrypted": encrypted,
    }


def select_master_variant(variants: list[dict], cap_height: Optional[int]) -> Optional[dict]:
    usable = [item for item in variants if item.get("url") and item.get("height")]
    if not usable:
        return variants[0] if variants else None
    if cap_height is None:
        return max(usable, key=lambda item: (item["height"], item.get("bandwidth") or 0))
    under = [item for item in usable if item["height"] <= cap_height]
    if under:
        return max(under, key=lambda item: (item["height"], item.get("bandwidth") or 0))
    return min(usable, key=lambda item: (item["height"], item.get("bandwidth") or 0))


def segment_bytes(url: str) -> Optional[int]:
    query = dict(parse_qsl(urlparse(url).query))
    span = query.get("r_range")
    if not span or "-" not in span:
        return None
    start, end = span.split("-", 1)
    try:
        return int(end) - int(start) + 1
    except ValueError:
        return None


def _attr(line: str, name: str) -> Optional[str]:
    match = re.search(rf'{name}=(?:"([^"]*)"|([^,\s]*))', line)
    if not match:
        return None
    return match.group(1) if match.group(1) is not None else match.group(2)


def _attr_int(line: str, name: str) -> int:
    raw = _attr(line, name)
    try:
        return int(raw or 0)
    except ValueError:
        return 0


def plan_sync(pages, known, *, baseline, auto_on, max_pages):
    """Queue every new public video until a page is entirely already known.

    A burst that spills past page 1 is still downloaded. Raising the page
    limit later does not download the back catalog, because the walk stops
    at the first page of videos that were seen before.
    """
    known = set(known)
    queue = []
    seen = []
    for page in list(pages)[: max(1, max_pages)]:
        if not page:
            break
        if all(item["id"] in known for item in page):
            break
        for item in page:
            if item["id"] in known:
                continue
            seen.append(item["id"])
            known.add(item["id"])
            if auto_on and not baseline and item.get("disposition") == DOWNLOADABLE:
                queue.append(item["id"])
    return queue, seen


def _parse_time(value: str) -> datetime:
    cleaned = value.replace("Z", "+00:00")
    return datetime.fromisoformat(cleaned)


def rss_xml(items: Iterable[ListedVideo], generated_at: str) -> str:
    """Local RSS 2.0 document for the Videos tab. Not an official Rumble feed."""
    rows = []
    for item in items:
        if item.disposition != DOWNLOADABLE:
            continue
        rows.append(
            "    <item>\n"
            f"      <title>{_xml(item.title)}</title>\n"
            f"      <link>{_xml(item.watch)}</link>\n"
            f"      <guid isPermaLink=\"false\">{_xml(item.id)}</guid>\n"
            + (f"      <pubDate>{_xml(item.published or '')}</pubDate>\n" if item.published else "")
            + f"      <description>{_xml(item.channel or CHANNEL_NAME)}</description>\n"
            "    </item>"
        )
    body = "\n".join(rows)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<rss version="2.0">\n'
        "  <channel>\n"
        f"    <title>{_xml(CHANNEL_NAME)} — Videos</title>\n"
        f"    <link>{VIDEOS_PAGE}</link>\n"
        "    <description>Videos tab only, generated locally by Fuentes Archive. "
        "Rumble does not publish an official feed for this channel.</description>\n"
        f"    <lastBuildDate>{_xml(generated_at)}</lastBuildDate>\n"
        f"{body}\n"
        "  </channel>\n"
        "</rss>\n"
    )


def _xml(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def safe_filename(title: str, video_id: str, extension: str) -> str:
    cleaned = re.sub(r"[^\w\s\-.,]+", "", title, flags=re.UNICODE)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" .")
    if not cleaned:
        cleaned = "video"
    cleaned = cleaned[:80]
    ext = extension.lstrip(".")
    return f"{cleaned} [{video_id}].{ext}"


def retry_delay(attempt: int) -> float:
    steps = (30, 120, 600, 1800, 7200)
    return float(steps[min(max(attempt, 0), len(steps) - 1)])


def should_retry(http_status: Optional[int], attempt: int, max_attempts: int = 5) -> bool:
    if attempt >= max_attempts:
        return False
    if http_status in {404, 410, 451}:
        return False
    return True
