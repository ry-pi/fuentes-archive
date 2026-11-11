import Foundation

/// Streams Rumble MPEG-TS pieces (H.264 + AAC) into an MP4 Photos can import.
/// Sample bytes are written as they are demuxed. Only timestamps and sizes stay in memory.
enum TSRemuxer {
    struct Info {
        var width: Int
        var height: Int
        var videoSamples: Int
        var audioSamples: Int
    }

    static func remux(files: [URL], to destination: URL) throws -> Info {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.write(contentsOf: box("ftyp", Data("isom".utf8) + u32(0x200) + Data("isomiso2avc1mp41".utf8)))
        let mdatAt = try handle.offset()
        try handle.write(contentsOf: u32(1) + Data("mdat".utf8) + u64(0))

        let demux = try Demuxer(handle: handle).run(files: files)
        guard demux.videoCount > 0, !demux.sps.isEmpty, !demux.pps.isEmpty else {
            throw RemuxError.noVideo
        }
        let end = try handle.offset()
        try handle.seek(toOffset: mdatAt + 8)
        try handle.write(contentsOf: u64(end - mdatAt))
        try handle.seek(toOffset: end)
        try handle.write(contentsOf: demux.moov())
        return Info(width: demux.width, height: demux.height, videoSamples: demux.videoCount, audioSamples: demux.audioCount)
    }

    enum RemuxError: LocalizedError {
        case noVideo
        var errorDescription: String? { "The video stream could not be remuxed to MP4." }
    }
}

private struct SampleMeta {
    var offset: UInt64
    var size: UInt32
    var dts: Int64
    var pts: Int64
    var key: Bool
}

private final class Demuxer {
    let handle: FileHandle
    var sps = Data()
    var pps = Data()
    var width = 0
    var height = 0
    var frequency = 44100
    var channels = 2
    var profile = 2
    var video: [SampleMeta] = []
    var audio: [SampleMeta] = []
    var videoCount: Int { video.count }
    var audioCount: Int { audio.count }
    private var videoPID: Int?
    private var audioPID: Int?
    private var pmtPID: Int?
    private var carry: [Int: Data] = [:]
    private var origin: Int64?

    init(handle: FileHandle) { self.handle = handle }

    func run(files: [URL]) throws -> Demuxer {
        for file in files {
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let packet = try Self.readPacket(input) {
                try consume(packet)
            }
            for pid in Array(carry.keys) { try finish(pid) }
        }
        normalize()
        return self
    }

    func moov() -> Data {
        let movieTimescale: Int64 = 1000
        let videoDuration = duration(video)
        let audioDuration90 = audio.count > 1 ? (audio.last!.dts - audio.first!.dts) : 0
        let movie = max(videoDuration, audioDuration90) * movieTimescale / 90000
        var tracks = trak(
            id: 1, samples: video, entry: videoEntry(), handler: "vide", name: "Video",
            timescale: 90000, duration: videoDuration, movie: movie,
            width: width, height: height, volume: 0
        )
        if !audio.isEmpty {
            let scaled = scaledAudio()
            let audioDuration = duration(scaled)
            tracks.append(trak(
                id: 2, samples: scaled, entry: audioEntry(), handler: "soun", name: "Audio",
                timescale: Int64(frequency), duration: audioDuration, movie: movie,
                width: 0, height: 0, volume: 0x0100
            ))
        }
        let mvhd = fullbox("mvhd", 0, 0, pack(
            u32(0), u32(0), u32(UInt32(movieTimescale)), u32(UInt32(movie)),
            u32(0x00010000), u16(0x0100), Data(count: 10), matrix(), Data(count: 24),
            u32(audio.isEmpty ? 2 : 3)
        ))
        return box("moov", mvhd + tracks)
    }

    private static func readPacket(_ input: FileHandle) throws -> Data? {
        var packet = Data()
        while packet.count < 188 {
            guard let chunk = try input.read(upToCount: 188 - packet.count), !chunk.isEmpty else {
                return nil
            }
            packet.append(chunk)
        }
        return packet
    }

    private func consume(_ packet: Data) throws {
        guard packet[0] == 0x47 else { return }
        let pid = Int(packet[1] & 0x1F) << 8 | Int(packet[2])
        let start = packet[1] & 0x40 != 0
        var offset = 4
        if packet[3] & 0x20 != 0 { offset += 1 + Int(packet[4]) }
        guard packet[3] & 0x10 != 0, offset < packet.count else { return }
        let payload = packet.subdata(in: offset..<packet.count)
        if pid == 0 && start && pmtPID == nil {
            pmtPID = programPID(payload)
            return
        }
        if let pmtPID, pid == pmtPID, start, videoPID == nil {
            let streams = elementaryStreams(payload)
            videoPID = streams.video
            audioPID = streams.audio
            return
        }
        guard pid == videoPID || pid == audioPID else { return }
        if start {
            try finish(pid)
            carry[pid] = payload
        } else if carry[pid] != nil {
            carry[pid]?.append(payload)
        }
    }

    private func finish(_ pid: Int) throws {
        guard let buf = carry.removeValue(forKey: pid) else { return }
        guard buf.count >= 9, buf.prefix(3) == Data([0, 0, 1]) else { return }
        let streamID = buf[3]
        guard let times = timestamps(buf) else { return }
        let header = Int(buf[8])
        let es = buf.subdata(in: (9 + header)..<buf.count)
        if streamID >= 0xE0 && streamID <= 0xEF {
            try writeVideo(es, dts: times.dts, pts: times.pts)
        } else if streamID >= 0xC0 && streamID <= 0xDF {
            try writeAudio(es, dts: times.dts)
        }
    }

    private func writeVideo(_ es: Data, dts: Int64, pts: Int64) throws {
        let nals = nalUnits(es)
        var kept = Data()
        var key = false
        for nal in nals {
            let kind = nal[0] & 0x1F
            if kind == 7 && sps.isEmpty {
                sps = nal
                if let size = spsSize(nal) { width = size.0; height = size.1 }
            } else if kind == 8 && pps.isEmpty {
                pps = nal
            } else if kind == 5 {
                key = true
            }
            if [1, 5, 6, 7, 8].contains(kind) {
                kept.append(u32(UInt32(nal.count)))
                kept.append(nal)
            }
        }
        guard !kept.isEmpty else { return }
        let offset = try handle.offset()
        try handle.write(contentsOf: kept)
        video.append(SampleMeta(offset: offset, size: UInt32(kept.count), dts: dts, pts: pts, key: key))
    }

    private func writeAudio(_ es: Data, dts: Int64) throws {
        var index = 0
        var frameIndex = 0
        let bytes = [UInt8](es)
        while index + 7 < bytes.count {
            if bytes[index] != 0xFF || bytes[index + 1] & 0xF0 != 0xF0 {
                index += 1
                continue
            }
            let length = (Int(bytes[index + 3] & 0x03) << 11) | (Int(bytes[index + 4]) << 3) | (Int(bytes[index + 5] & 0xE0) >> 5)
            guard length >= 7, index + length <= bytes.count else { break }
            profile = Int((bytes[index + 2] & 0xC0) >> 6) + 1
            let freqIndex = Int((bytes[index + 2] & 0x3C) >> 2)
            frequency = freqIndex < frequencies.count ? frequencies[freqIndex] : 44100
            channels = Int((bytes[index + 2] & 1) << 2 | (bytes[index + 3] & 0xC0) >> 6)
            let header = 7 + ((bytes[index + 1] & 1) == 0 ? 2 : 0)
            let frame = Data(bytes[(index + header)..<(index + length)])
            let step = Int64(1024 * 90000 / max(frequency, 1))
            let stamp = dts + Int64(frameIndex) * step
            let offset = try handle.offset()
            try handle.write(contentsOf: frame)
            audio.append(SampleMeta(offset: offset, size: UInt32(frame.count), dts: stamp, pts: stamp, key: false))
            frameIndex += 1
            index += length
        }
    }

    private func normalize() {
        let first = min(video.first?.dts ?? Int64.max, audio.first?.dts ?? Int64.max)
        origin = first
        for i in video.indices {
            video[i].dts -= first
            video[i].pts -= first
        }
        for i in audio.indices {
            audio[i].dts -= first
            audio[i].pts -= first
        }
    }

    private func scaledAudio() -> [SampleMeta] {
        let scale = Double(frequency) / 90000
        var scaled: [SampleMeta] = audio.map { sample in
            var copy = sample
            copy.dts = Int64((Double(sample.dts) * scale).rounded())
            copy.pts = copy.dts
            return copy
        }
        for i in 1..<scaled.count where scaled[i].dts <= scaled[i - 1].dts {
            scaled[i].dts = scaled[i - 1].dts + 1
            scaled[i].pts = scaled[i].dts
        }
        return scaled
    }
}

private let frequencies = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

private func timestamps(_ buf: Data) -> (dts: Int64, pts: Int64)? {
    guard buf.count >= 14 else { return nil }
    let flags = buf[7]
    var offset = 9
    func read() -> Int64 {
        let b = buf.subdata(in: offset..<(offset + 5))
        offset += 5
        return (Int64(b[0] & 0x0E) << 29) | (Int64(b[1]) << 22) | (Int64(b[2] & 0xFE) << 14) | (Int64(b[3]) << 7) | (Int64(b[4]) >> 1)
    }
    guard flags & 0x80 != 0 else { return nil }
    let pts = read()
    let dts = flags & 0x40 != 0 ? read() : pts
    return (dts, pts)
}

private func nalUnits(_ es: Data) -> [Data] {
    let bytes = [UInt8](es)
    var starts: [Int] = []
    var i = 0
    while i + 3 < bytes.count {
        if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
            starts.append(i + 3)
            i += 3
        } else {
            i += 1
        }
    }
    var units: [Data] = []
    for index in starts.indices {
        var end = index + 1 < starts.count ? starts[index + 1] - 3 : bytes.count
        if end > starts[index] && bytes[end - 1] == 0 { end -= 1 }
        if end > starts[index] { units.append(Data(bytes[starts[index]..<end])) }
    }
    return units
}

private func programPID(_ payload: Data) -> Int? {
    guard let section = section(payload) else { return nil }
    let body = section.body
    var i = 8
    while i + 4 <= body.count {
        let program = Int(body[i]) << 8 | Int(body[i + 1])
        let pid = Int(body[i + 2] & 0x1F) << 8 | Int(body[i + 3])
        if program != 0 { return pid }
        i += 4
    }
    return nil
}

private func elementaryStreams(_ payload: Data) -> (video: Int?, audio: Int?) {
    guard let section = section(payload), section.body.count > 12 else { return (nil, nil) }
    let body = section.body
    let info = (Int(body[10] & 0x0F) << 8) | Int(body[11])
    var i = 12 + info
    let end = min(body.count, section.lengthEnd)
    var video: Int?
    var audio: Int?
    while i + 5 <= end {
        let kind = body[i]
        let pid = Int(body[i + 1] & 0x1F) << 8 | Int(body[i + 2])
        let infoLen = (Int(body[i + 3] & 0x0F) << 8) | Int(body[i + 4])
        if kind == 0x1B { video = pid }
        if kind == 0x0F || kind == 0x11 { audio = pid }
        i += 5 + infoLen
    }
    return (video, audio)
}

private func section(_ payload: Data) -> (body: Data, lengthEnd: Int)? {
    guard !payload.isEmpty else { return nil }
    let pointer = Int(payload[0])
    let start = 1 + pointer
    guard start + 3 < payload.count else { return nil }
    let body = payload.subdata(in: start..<payload.count)
    let length = (Int(body[1] & 0x0F) << 8) | Int(body[2])
    return (body, 3 + length - 4)
}

private func spsSize(_ nal: Data) -> (Int, Int)? {
    guard nal.count > 4 else { return nil }
    let reader = BitReader(rbsp(nal.subdata(in: 1..<nal.count)))
    do {
        let profile = try reader.read(8)
        _ = try reader.read(8)
        _ = try reader.read(8)
        _ = try reader.ue()
        var chroma = 1
        let high: Set<Int> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
        if high.contains(profile) {
            chroma = try reader.ue()
            if chroma == 3 { _ = try reader.read(1) }
            _ = try reader.ue(); _ = try reader.ue(); _ = try reader.read(1)
            if try reader.read(1) == 1 {
                let count = chroma == 3 ? 12 : 8
                for index in 0..<count where try reader.read(1) == 1 {
                    try skipScaling(reader, index < 6 ? 16 : 64)
                }
            }
        }
        _ = try reader.ue()
        let poc = try reader.ue()
        if poc == 0 {
            _ = try reader.ue()
        } else if poc == 1 {
            _ = try reader.read(1); _ = try reader.ue(); _ = try reader.ue()
            let cycles = try reader.ue()
            for _ in 0..<cycles { _ = try reader.ue() }
        }
        _ = try reader.ue(); _ = try reader.read(1)
        var width = (try reader.ue() + 1) * 16
        let heightMap = try reader.ue() + 1
        let frameOnly = try reader.read(1) == 1
        if !frameOnly { _ = try reader.read(1) }
        var height = heightMap * (frameOnly ? 1 : 2) * 16
        _ = try reader.read(1)
        if try reader.read(1) == 1 {
            let left = try reader.ue(), right = try reader.ue(), top = try reader.ue(), bottom = try reader.ue()
            let crop = chroma <= 1 ? 2 : 1
            width -= (left + right) * crop
            height -= (top + bottom) * crop * (frameOnly ? 1 : 2)
        }
        return (width, height)
    } catch {
        return nil
    }
}

private func rbsp(_ data: Data) -> Data {
    var out = Data()
    var i = 0
    let bytes = [UInt8](data)
    while i < bytes.count {
        if i + 2 < bytes.count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 3 {
            out.append(contentsOf: [0, 0])
            i += 3
            continue
        }
        out.append(bytes[i])
        i += 1
    }
    return out
}

private func skipScaling(_ reader: BitReader, _ size: Int) throws {
    var last = 8
    var nextScale = 8
    for _ in 0..<size {
        if nextScale != 0 {
            var delta = try reader.ue()
            if delta & 1 == 1 { delta = (delta + 1) / 2 } else { delta = -(delta / 2) }
            nextScale = (last + delta + 256) % 256
        }
        last = nextScale == 0 ? last : nextScale
    }
}

private final class BitReader {
    private let bytes: [UInt8]
    private var bit = 0
    init(_ data: Data) { bytes = [UInt8](data) }
    func read(_ count: Int) throws -> Int {
        var value = 0
        for _ in 0..<count {
            let index = bit / 8
            if index >= bytes.count { throw TSRemuxer.RemuxError.noVideo }
            value = (value << 1) | Int((bytes[index] >> (7 - (bit % 8))) & 1)
            bit += 1
        }
        return value
    }
    func ue() throws -> Int {
        var zeros = 0
        while try read(1) == 0 {
            zeros += 1
            if zeros > 31 { throw TSRemuxer.RemuxError.noVideo }
        }
        return (1 << zeros) - 1 + (zeros > 0 ? try read(zeros) : 0)
    }
}

private func duration(_ samples: [SampleMeta]) -> Int64 {
    guard samples.count > 1 else { return 3000 }
    return (samples[samples.count - 1].dts - samples[0].dts) + (samples[samples.count - 1].dts - samples[samples.count - 2].dts)
}

private func trak(id: UInt32, samples: [SampleMeta], entry: Data, handler: String, name: String, timescale: Int64, duration: Int64, movie: Int64, width: Int, height: Int, volume: UInt16) -> Data {
    let tkhd = fullbox("tkhd", 0, 3, pack(
        u32(0), u32(0), u32(id), u32(0), u32(UInt32(max(0, movie))),
        Data(count: 8), u16(0), u16(0), u16(volume), u16(0), matrix(),
        u32(UInt32(width) << 16), u32(UInt32(height) << 16)
    ))
    let mdhd = fullbox("mdhd", 0, 0, pack(u32(0), u32(0), u32(UInt32(timescale)), u32(UInt32(max(0, duration))), u16(0x55C4), u16(0)))
    let hdlr = fullbox("hdlr", 0, 0, pack(u32(0), Data(handler.utf8), Data(count: 12), Data(name.utf8), Data([0])))
    let mediaHeader: Data = handler == "vide"
        ? fullbox("vmhd", 0, 1, u16(0) + u16(0) + u16(0) + u16(0))
        : fullbox("smhd", 0, 0, u16(0) + u16(0))
    let url = fullbox("url ", 0, 1, Data())
    let dinf = box("dinf", fullbox("dref", 0, 0, u32(1) + url))
    let stbl = sampleTable(samples, entry: entry)
    let mdia = box("mdia", mdhd + hdlr + box("minf", mediaHeader + dinf + stbl))
    return box("trak", tkhd + mdia)
}

private func sampleTable(_ samples: [SampleMeta], entry: Data) -> Data {
    let stsd = fullbox("stsd", 0, 0, u32(1) + entry)
    var runs: [(UInt32, UInt32)] = []
    for index in samples.indices {
        let delta: UInt32
        if index + 1 < samples.count {
            delta = UInt32(max(1, samples[index + 1].dts - samples[index].dts))
        } else {
            delta = runs.last?.1 ?? 3000
        }
        if var last = runs.last, last.1 == delta {
            last.0 += 1
            runs[runs.count - 1] = last
        } else {
            runs.append((1, delta))
        }
    }
    var sttsBody = u32(UInt32(runs.count))
    for run in runs { sttsBody.append(u32(run.0) + u32(run.1)) }
    let stts = fullbox("stts", 0, 0, sttsBody)
    let offsets = samples.map { $0.pts - $0.dts }
    var ctts = Data()
    if offsets.contains(where: { $0 != 0 }) {
        var cruns: [(UInt32, Int32)] = []
        for offset in offsets {
            let value = Int32(offset)
            if var last = cruns.last, last.1 == value {
                last.0 += 1
                cruns[cruns.count - 1] = last
            } else {
                cruns.append((1, value))
            }
        }
        var body = u32(UInt32(cruns.count))
        for run in cruns { body.append(u32(run.0) + Data(u32(UInt32(bitPattern: run.1)))) }
        let version: UInt8 = offsets.contains(where: { $0 < 0 }) ? 1 : 0
        ctts = fullbox("ctts", version, 0, body)
    }
    let keys = samples.enumerated().compactMap { $0.element.key ? UInt32($0.offset + 1) : nil }
    let stss = keys.isEmpty ? Data() : fullbox("stss", 0, 0, u32(UInt32(keys.count)) + keys.reduce(Data()) { $0 + u32($1) })
    let stsc = fullbox("stsc", 0, 0, u32(1) + u32(1) + u32(1) + u32(1))
    var stszBody = u32(0) + u32(UInt32(samples.count))
    for sample in samples { stszBody.append(u32(sample.size)) }
    let stsz = fullbox("stsz", 0, 0, stszBody)
    var co64Body = u32(UInt32(samples.count))
    for sample in samples { co64Body.append(u64(sample.offset)) }
    let co64 = fullbox("co64", 0, 0, co64Body)
    return box("stbl", stsd + stts + ctts + stss + stsc + stsz + co64)
}

extension Demuxer {
    fileprivate func videoEntry() -> Data {
        var avcc = Data([1, sps.count > 1 ? sps[1] : 0x64, sps.count > 2 ? sps[2] : 0, sps.count > 3 ? sps[3] : 0x1F, 0xFF, 0xE1])
        avcc.append(u16(UInt16(sps.count)))
        avcc.append(sps)
        avcc.append(1)
        avcc.append(u16(UInt16(pps.count)))
        avcc.append(pps)
        let visual = pack(
            Data(count: 6), u16(1), Data(count: 16),
            u16(UInt16(width == 0 ? 16 : width)), u16(UInt16(height == 0 ? 16 : height)),
            u32(0x00480000), u32(0x00480000), u32(0), u16(1), Data(count: 32),
            u16(0x0018), u16(0xFFFF), box("avcC", avcc)
        )
        return box("avc1", visual)
    }

    fileprivate func audioEntry() -> Data {
        let freqIndex = frequencies.firstIndex(of: frequency) ?? 4
        let bits = (profile << 11) | (freqIndex << 7) | ((channels == 0 ? 2 : channels) << 3)
        let specific = u16(UInt16(bits))
        let dsi = descriptor(0x05, specific)
        let decBody = pack(Data([0x40, 0x15, 0, 0, 0]), u32(128000), u32(128000), dsi)
        let dec = descriptor(0x04, decBody)
        let sl = descriptor(0x06, Data([2]))
        let es = descriptor(0x03, pack(u16(1), Data([0]), dec, sl))
        let esds = fullbox("esds", 0, 0, es)
        let body = pack(
            Data(count: 6), u16(1), Data(count: 8),
            u16(UInt16(channels == 0 ? 2 : channels)), u16(16), u16(0), u16(0),
            u32(UInt32(frequency) << 16), esds
        )
        return box("mp4a", body)
    }
}

private func descriptor(_ tag: UInt8, _ body: Data) -> Data {
    var length = body.count
    var encoded = Data()
    while true {
        var byte = UInt8(length & 0x7F)
        length >>= 7
        if length > 0 { byte |= 0x80; encoded.append(byte) } else { encoded.append(byte); break }
    }
    return Data([tag]) + encoded + body
}

private func matrix() -> Data {
    pack(u32(0x00010000), u32(0), u32(0), u32(0), u32(0x00010000), u32(0), u32(0), u32(0), u32(0x40000000))
}

private func pack(_ parts: Data...) -> Data {
    var data = Data()
    for part in parts { data.append(part) }
    return data
}

private func box(_ tag: String, _ payload: Data) -> Data { u32(UInt32(8 + payload.count)) + Data(tag.utf8) + payload }
private func fullbox(_ tag: String, _ version: UInt8, _ flags: UInt32, _ payload: Data) -> Data {
    box(tag, u32((UInt32(version) << 24) | flags) + payload)
}
private func u16(_ value: UInt16) -> Data { var v = value.bigEndian; return Data(bytes: &v, count: 2) }
private func u32(_ value: UInt32) -> Data { var v = value.bigEndian; return Data(bytes: &v, count: 4) }
private func u64(_ value: UInt64) -> Data { var v = value.bigEndian; return Data(bytes: &v, count: 8) }
