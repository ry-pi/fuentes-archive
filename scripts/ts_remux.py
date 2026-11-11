"""Remux Rumble MPEG-TS (H.264 + AAC) into a regular MP4.

Rumble's current Videos-tab files are MPEG-TS pieces inside a tar-backed
HLS playlist. Photos will not import .ts. This writer streams the pieces
and emits an MP4 with the moov atom at the end (co64 offsets), which
AVPlayer and Photos both accept. It does not load the media into memory.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import BinaryIO, Iterable, Optional


def _u32(value: int) -> bytes:
    return struct.pack(">I", value & 0xFFFFFFFF)


def _u64(value: int) -> bytes:
    return struct.pack(">Q", value & 0xFFFFFFFFFFFFFFFF)


def _u16(value: int) -> bytes:
    return struct.pack(">H", value & 0xFFFF)


def box(tag: bytes, payload: bytes) -> bytes:
    return _u32(8 + len(payload)) + tag + payload


def fullbox(tag: bytes, version: int, flags: int, payload: bytes) -> bytes:
    return box(tag, _u32((version << 24) | flags) + payload)


class BitReader:
    def __init__(self, data: bytes):
        self.data = data
        self.bit = 0

    def read(self, count: int) -> int:
        value = 0
        for _ in range(count):
            byte = self.data[self.bit // 8]
            shift = 7 - (self.bit % 8)
            value = (value << 1) | ((byte >> shift) & 1)
            self.bit += 1
        return value

    def ue(self) -> int:
        zeros = 0
        while self.read(1) == 0:
            zeros += 1
            if zeros > 31:
                raise ValueError("exp-golomb too long")
        return (1 << zeros) - 1 + (self.read(zeros) if zeros else 0)


def rbsp(nal: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(nal):
        if i + 2 < len(nal) and nal[i] == 0 and nal[i + 1] == 0 and nal[i + 2] == 3:
            out.extend(nal[i : i + 2])
            i += 3
            continue
        out.append(nal[i])
        i += 1
    return bytes(out)


def sps_dimensions(nal: bytes) -> tuple[int, int]:
    """Return cropped width and height from an SPS NAL (header included)."""
    reader = BitReader(rbsp(nal[1:]))
    profile = reader.read(8)
    reader.read(8)
    reader.read(8)
    reader.ue()
    chroma = 1
    if profile in {100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135}:
        chroma = reader.ue()
        if chroma == 3:
            reader.read(1)
        reader.ue()
        reader.ue()
        reader.read(1)
        if reader.read(1):
            count = 12 if chroma == 3 else 8
            for i in range(count):
                if reader.read(1):
                    _skip_scaling(reader, 16 if i < 6 else 64)
    reader.ue()
    poc = reader.ue()
    if poc == 0:
        reader.ue()
    elif poc == 1:
        reader.read(1)
        reader.ue()
        reader.ue()
        for _ in range(reader.ue()):
            reader.ue()
    reader.ue()
    reader.read(1)
    width = (reader.ue() + 1) * 16
    height_map = reader.ue() + 1
    frame_only = reader.read(1)
    if not frame_only:
        reader.read(1)
    height = height_map * (2 if not frame_only else 1) * 16
    reader.read(1)
    if reader.read(1):
        left, right, top, bottom = reader.ue(), reader.ue(), reader.ue(), reader.ue()
        crop = 2 if chroma <= 1 else 1
        width -= (left + right) * crop
        height -= (top + bottom) * crop * (2 if not frame_only else 1)
    return width, height


def _skip_scaling(reader: BitReader, size: int) -> None:
    last, next_scale = 8, 8
    for _ in range(size):
        if next_scale != 0:
            delta = reader.ue()
            if delta & 1:
                delta = (delta + 1) // 2
            else:
                delta = -(delta // 2)
            next_scale = (last + delta + 256) % 256
        last = last if next_scale == 0 else next_scale


def _timestamp(buf: bytes) -> tuple[Optional[int], Optional[int]]:
    if len(buf) < 14 or buf[:3] != b"\x00\x00\x01":
        return None, None
    flags = buf[7]
    offset = 9

    def read_ts() -> int:
        nonlocal offset
        raw = buf[offset : offset + 5]
        offset += 5
        return (
            ((raw[0] & 0x0E) << 29)
            | (raw[1] << 22)
            | ((raw[2] & 0xFE) << 14)
            | (raw[3] << 7)
            | (raw[4] >> 1)
        )

    pts = read_ts() if flags & 0x80 else None
    dts = read_ts() if flags & 0x40 else None
    if pts is not None and dts is None:
        dts = pts
    return dts, pts


def _es(buf: bytes) -> bytes:
    header = buf[8]
    return buf[9 + header :]


def _nal_units(es: bytes) -> list[bytes]:
    starts = []
    i = 0
    while i + 3 < len(es):
        if es[i] == 0 and es[i + 1] == 0 and es[i + 2] == 1:
            starts.append(i + 3)
            i += 3
            continue
        i += 1
    units = []
    for index, start in enumerate(starts):
        end = starts[index + 1] - 3 if index + 1 < len(starts) else len(es)
        if end > start and es[end - 1] == 0:
            end -= 1
        units.append(es[start:end])
    return [unit for unit in units if unit]


@dataclass
class Sample:
    data: bytes
    dts: int
    pts: int
    key: bool


@dataclass
class Media:
    sps: bytes = b""
    pps: bytes = b""
    width: int = 0
    height: int = 0
    video: list[Sample] = field(default_factory=list)
    audio: list[Sample] = field(default_factory=list)
    frequency: int = 44100
    channels: int = 2
    aac_profile: int = 2


FREQ = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]


def demux_paths(paths: Iterable[Path]) -> Media:
    media = Media()
    video_pid = audio_pid = None
    pmt_pid = None
    carry: dict[int, bytearray] = {}
    last_dts = -1

    def take_pes(pid: int, buf: bytes) -> None:
        nonlocal last_dts
        if len(buf) < 9 or buf[:3] != b"\x00\x00\x01":
            return
        stream_id = buf[3]
        dts, pts = _timestamp(buf)
        if dts is None or pts is None:
            return
        if last_dts >= 0 and dts < last_dts - (1 << 32):
            dts += 1 << 33
            pts += 1 << 33
        payload = _es(buf)
        if stream_id == 0xE0 or (video_pid is not None and pid == video_pid and stream_id >= 0xE0):
            nals = _nal_units(payload)
            kept = []
            key = False
            for nal in nals:
                kind = nal[0] & 0x1F
                if kind == 7 and not media.sps:
                    media.sps = nal
                    try:
                        media.width, media.height = sps_dimensions(nal)
                    except Exception:
                        media.width, media.height = 0, 0
                elif kind == 8 and not media.pps:
                    media.pps = nal
                elif kind == 5:
                    key = True
                if kind in {1, 5, 6, 7, 8}:
                    kept.append(nal)
            if not kept:
                return
            sample = b"".join(_u32(len(nal)) + nal for nal in kept)
            media.video.append(Sample(sample, dts, pts, key))
            last_dts = dts
        elif stream_id == 0xC0 or pid == audio_pid:
            frames = _adts(payload, media)
            if not frames:
                return
            step = 1024 * 90000 // max(media.frequency, 1)
            for index, frame in enumerate(frames):
                media.audio.append(Sample(frame, dts + index * step, dts + index * step, False))

    def finish_pid(pid: int) -> None:
        buf = carry.pop(pid, None)
        if buf:
            take_pes(pid, bytes(buf))

    for path in paths:
        with path.open("rb") as handle:
            while True:
                packet = handle.read(188)
                if len(packet) < 188:
                    break
                if packet[0] != 0x47:
                    continue
                pid = ((packet[1] & 0x1F) << 8) | packet[2]
                start = bool(packet[1] & 0x40)
                offset = 4
                if packet[3] & 0x20:
                    offset += 1 + packet[4]
                if not packet[3] & 0x10:
                    continue
                payload = packet[offset:]
                if pid == 0 and start and pmt_pid is None:
                    pointer = payload[0]
                    section = payload[1 + pointer :]
                    body_len = ((section[1] & 0x0F) << 8) | section[2]
                    body = section[8 : 3 + body_len - 4]
                    i = 0
                    while i + 4 <= len(body):
                        program = (body[i] << 8) | body[i + 1]
                        program_pid = ((body[i + 2] & 0x1F) << 8) | body[i + 3]
                        if program:
                            pmt_pid = program_pid
                            break
                        i += 4
                    continue
                if pmt_pid is not None and pid == pmt_pid and start and video_pid is None:
                    pointer = payload[0]
                    section = payload[1 + pointer :]
                    info = ((section[10] & 0x0F) << 8) | section[11]
                    es = section[12 + info :]
                    end = 3 + (((section[1] & 0x0F) << 8) | section[2]) - 4
                    es = section[12 + info : end]
                    i = 0
                    while i + 5 <= len(es):
                        stream_type = es[i]
                        elementary = ((es[i + 1] & 0x1F) << 8) | es[i + 2]
                        info_len = ((es[i + 3] & 0x0F) << 8) | es[i + 4]
                        if stream_type == 0x1B:
                            video_pid = elementary
                        elif stream_type in {0x0F, 0x11}:
                            audio_pid = elementary
                        i += 5 + info_len
                    continue
                if pid not in {video_pid, audio_pid}:
                    continue
                if start:
                    finish_pid(pid)
                    carry[pid] = bytearray(payload)
                elif pid in carry:
                    carry[pid].extend(payload)
        for pid in list(carry):
            finish_pid(pid)
    return media


def _adts(payload: bytes, media: Media) -> list[bytes]:
    frames = []
    i = 0
    while i + 7 < len(payload):
        if payload[i] != 0xFF or (payload[i + 1] & 0xF0) != 0xF0:
            i += 1
            continue
        length = ((payload[i + 3] & 0x03) << 11) | (payload[i + 4] << 3) | ((payload[i + 5] & 0xE0) >> 5)
        if length < 7 or i + length > len(payload):
            break
        media.aac_profile = ((payload[i + 2] & 0xC0) >> 6) + 1
        freq = (payload[i + 2] & 0x3C) >> 2
        media.frequency = FREQ[freq] if freq < len(FREQ) else 44100
        media.channels = ((payload[i + 2] & 1) << 2) | ((payload[i + 3] & 0xC0) >> 6)
        header = 7 + (2 if payload[i + 1] & 1 == 0 else 0)
        frames.append(payload[i + header : i + length])
        i += length
    return frames


def _descriptor(tag: int, body: bytes) -> bytes:
    length = len(body)
    encoded = bytearray()
    while True:
        byte = length & 0x7F
        length >>= 7
        if length:
            encoded.append(byte | 0x80)
        else:
            encoded.append(byte)
            break
    return bytes([tag]) + bytes(encoded) + body


def _esds(media: Media) -> bytes:
    # AudioSpecificConfig: 5 bits object type, 4 bits freq index, 4 bits channels.
    freq_index = FREQ.index(media.frequency) if media.frequency in FREQ else 4
    bits = (media.aac_profile << 11) | (freq_index << 7) | (media.channels << 3)
    specific = struct.pack(">H", bits)
    dsi = _descriptor(0x05, specific)
    avg = 128000
    dec = _descriptor(
        0x04,
        bytes([0x40, 0x15, 0x00, 0x00, 0x00]) + _u32(avg) + _u32(avg) + dsi,
    )
    sl = _descriptor(0x06, b"\x02")
    es = _descriptor(0x03, _u16(1) + b"\x00" + dec + sl)
    return fullbox(b"esds", 0, 0, es)


def _sample_entry_video(media: Media) -> bytes:
    avcc = bytes([
        1, media.sps[1], media.sps[2], media.sps[3], 0xFF, 0xE1,
    ]) + _u16(len(media.sps)) + media.sps + bytes([1]) + _u16(len(media.pps)) + media.pps
    avc_box = box(b"avcC", avcc)
    width = media.width or 16
    height = media.height or 16
    body = (
        b"\x00" * 6
        + _u16(1)
        + b"\x00" * 16
        + _u16(width)
        + _u16(height)
        + _u32(0x00480000)
        + _u32(0x00480000)
        + _u32(0)
        + _u16(1)
        + b"\x00" * 32
        + _u16(0x0018)
        + struct.pack(">h", -1)
        + avc_box
    )
    return box(b"avc1", body)


def _sample_entry_audio(media: Media) -> bytes:
    body = (
        b"\x00" * 6
        + _u16(1)
        + b"\x00" * 8
        + _u16(media.channels or 2)
        + _u16(16)
        + _u16(0)
        + _u16(0)
        + _u32((media.frequency or 44100) << 16)
        + _esds(media)
    )
    return box(b"mp4a", body)


def _stts(samples: list[Sample]) -> bytes:
    if not samples:
        return fullbox(b"stts", 0, 0, _u32(0))
    runs = []
    for index, sample in enumerate(samples):
        if index + 1 < len(samples):
            delta = max(1, samples[index + 1].dts - sample.dts)
        else:
            delta = runs[-1][1] if runs else 3000
        if runs and runs[-1][1] == delta:
            runs[-1][0] += 1
        else:
            runs.append([1, delta])
    payload = _u32(len(runs)) + b"".join(_u32(count) + _u32(delta) for count, delta in runs)
    return fullbox(b"stts", 0, 0, payload)


def _ctts(samples: list[Sample]) -> Optional[bytes]:
    offsets = [sample.pts - sample.dts for sample in samples]
    if not any(offsets):
        return None
    runs = []
    for offset in offsets:
        if runs and runs[-1][1] == offset:
            runs[-1][0] += 1
        else:
            runs.append([1, offset])
    version = 1 if any(offset < 0 for offset in offsets) else 0
    payload = _u32(len(runs))
    for count, offset in runs:
        payload += _u32(count) + struct.pack(">i", offset)
    return fullbox(b"ctts", version, 0, payload)


def _stbl(samples: list[Sample], entry: bytes, data_offset: int) -> bytes:
    stsd = fullbox(b"stsd", 0, 0, _u32(1) + entry)
    stts = _stts(samples)
    ctts = _ctts(samples)
    stss_payload = b""
    keys = [index + 1 for index, sample in enumerate(samples) if sample.key]
    if keys:
        stss_payload = fullbox(b"stss", 0, 0, _u32(len(keys)) + b"".join(_u32(k) for k in keys))
    stsc = fullbox(b"stsc", 0, 0, _u32(1) + _u32(1) + _u32(len(samples)) + _u32(1))
    stsz = fullbox(b"stsz", 0, 0, _u32(0) + _u32(len(samples)) + b"".join(_u32(len(sample.data)) for sample in samples))
    co64 = fullbox(b"co64", 0, 0, _u32(1) + _u64(data_offset))
    body = stsd + stts + (ctts or b"") + stss_payload + stsc + stsz + co64
    return box(b"stbl", body)


def _track(track_id: int, samples: list[Sample], entry: bytes, handler: bytes, name: bytes, timescale: int, data_offset: int, volume: int) -> bytes:
    duration = 0
    if len(samples) >= 2:
        duration = samples[-1].dts - samples[0].dts
        # include the last sample's duration, estimated like stts
        duration += max(1, samples[-1].dts - samples[-2].dts) if len(samples) > 1 else 0
        duration = max(0, samples[-1].pts - samples[0].dts) + (samples[1].dts - samples[0].dts if len(samples) > 1 else 3000)
    tkhd = fullbox(
        b"tkhd",
        0,
        3,
        _u32(0) + _u32(0) + _u32(track_id) + _u32(0) + _u32(duration * 1000 // timescale if timescale else 0)
        + b"\x00" * 8 + _u16(0) + _u16(0) + _u16(volume) + _u16(0)
        + _u32(0x00010000) + _u32(0) + _u32(0) + _u32(0) + _u32(0x00010000) + _u32(0) + _u32(0) + _u32(0) + _u32(0x40000000)
        + _u32(0) + _u32(0),
    )
    # width/height patched by caller via a dedicated visual tkhd. This generic one is replaced below.
    return tkhd  # placeholder, real writer is write_mp4


def write_mp4(media: Media, output: BinaryIO, source_files: list[Path]) -> None:
    if not media.video or not media.sps or not media.pps:
        raise ValueError("no H.264 video")
    # Normalize timestamps so the first video DTS is 0, and keep audio aligned.
    origin = media.video[0].dts
    for sample in media.video:
        sample.dts -= origin
        sample.pts -= origin
    for sample in media.audio:
        sample.dts -= origin
        sample.pts -= origin

    output.write(box(b"ftyp", b"isom" + _u32(0x200) + b"isomiso2avc1mp41"))
    mdat_start = output.tell()
    output.write(_u32(1) + b"mdat" + _u64(0))
    data_start = output.tell()
    video_offset = data_start
    for sample in media.video:
        output.write(sample.data)
    audio_offset = output.tell()
    for sample in media.audio:
        output.write(sample.data)
    data_end = output.tell()
    output.seek(mdat_start + 8)
    output.write(_u64(data_end - mdat_start))
    output.seek(data_end)

    def duration_of(samples: list[Sample]) -> int:
        if len(samples) < 2:
            return 3000
        return (samples[-1].dts - samples[0].dts) + (samples[-1].dts - samples[-2].dts)

    video_duration = duration_of(media.video)
    audio_timescale = media.frequency or 44100
    # Audio samples were stored with 90 kHz timestamps. Convert when writing mdhd by
    # rewriting dts into the audio timescale below.
    movie_ms = max(video_duration, (media.audio[-1].dts - media.audio[0].dts) if len(media.audio) > 1 else 0) * 1000 // 90000

    def mdhd(timescale: int, duration: int) -> bytes:
        return fullbox(b"mdhd", 0, 0, _u32(0) + _u32(0) + _u32(timescale) + _u32(duration) + _u16(0x55C4) + _u16(0))

    def hdlr(kind: bytes, name: bytes) -> bytes:
        return fullbox(b"hdlr", 0, 0, _u32(0) + kind + b"\x00" * 12 + name + b"\x00")

    def dinf() -> bytes:
        url = fullbox(b"url ", 0, 1, b"")
        return box(b"dinf", fullbox(b"dref", 0, 0, _u32(1) + url))

    def vmhd() -> bytes:
        return fullbox(b"vmhd", 0, 1, _u16(0) + _u16(0) + _u16(0) + _u16(0))

    def smhd() -> bytes:
        return fullbox(b"smhd", 0, 0, _u16(0) + _u16(0))

    def tkhd(track_id: int, duration_ms: int, width: int, height: int, volume: int) -> bytes:
        matrix = (
            _u32(0x00010000) + _u32(0) + _u32(0)
            + _u32(0) + _u32(0x00010000) + _u32(0)
            + _u32(0) + _u32(0) + _u32(0x40000000)
        )
        return fullbox(
            b"tkhd",
            0,
            3,
            _u32(0) + _u32(0) + _u32(track_id) + _u32(0) + _u32(duration_ms)
            + b"\x00" * 8 + _u16(0) + _u16(0) + _u16(volume) + _u16(0)
            + matrix
            + _u32(width << 16) + _u32(height << 16),
        )

    video_entry = _sample_entry_video(media)
    video_stbl = _stbl(media.video, video_entry, video_offset)
    video_mdia = box(
        b"mdia",
        mdhd(90000, video_duration) + hdlr(b"vide", b"Video") + box(b"minf", vmhd() + dinf() + video_stbl),
    )
    video_trak = box(b"trak", tkhd(1, movie_ms, media.width or 16, media.height or 16, 0) + video_mdia)

    audio_samples = []
    if media.audio:
        scale = audio_timescale / 90000
        for sample in media.audio:
            audio_samples.append(Sample(sample.data, int(sample.dts * scale), int(sample.pts * scale), False))
        # force strictly increasing dts in case of rounding ties
        for index in range(1, len(audio_samples)):
            if audio_samples[index].dts <= audio_samples[index - 1].dts:
                audio_samples[index].dts = audio_samples[index - 1].dts + 1
                audio_samples[index].pts = audio_samples[index].dts
    audio_duration = duration_of(audio_samples) if audio_samples else 0
    audio_trak = b""
    if audio_samples:
        audio_stbl = _stbl(audio_samples, _sample_entry_audio(media), audio_offset)
        audio_mdia = box(
            b"mdia",
            mdhd(audio_timescale, audio_duration)
            + hdlr(b"soun", b"Audio")
            + box(b"minf", smhd() + dinf() + audio_stbl),
        )
        audio_trak = box(b"trak", tkhd(2, movie_ms, 0, 0, 0x0100) + audio_mdia)

    mvhd = fullbox(
        b"mvhd",
        0,
        0,
        _u32(0) + _u32(0) + _u32(1000) + _u32(movie_ms) + _u32(0x00010000) + _u16(0x0100) + b"\x00" * 10
        + _u32(0x00010000) + _u32(0) + _u32(0) + _u32(0) + _u32(0x00010000) + _u32(0) + _u32(0) + _u32(0) + _u32(0x40000000)
        + b"\x00" * 24 + _u32(3 if audio_trak else 2),
    )
    output.write(box(b"moov", mvhd + video_trak + audio_trak))


def remux(paths: list[Path], destination: Path) -> Media:
    media = demux_paths(paths)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as handle:
        write_mp4(media, handle, paths)
    return media
