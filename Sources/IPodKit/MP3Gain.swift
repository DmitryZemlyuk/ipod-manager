import Foundation

public enum MP3GainError: Error, LocalizedError {
    case notMP3
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notMP3: return "Not an MP3 file"
        case .unsupported(let s): return "Unsupported MP3: \(s)"
        }
    }
}

/// Lossless MP3 volume change, the way mp3gain does it: the 8-bit global_gain of every
/// granule is shifted by whole steps (1 step = 1.5 dB). Undo data goes into an APEv2 tag
/// using mp3gain's own keys, so mp3gain/MP3Gain Express can read and undo it as well.
public enum MP3Gain {
    /// One step multiplies the amplitude by 2^(1/4).
    public static let stepDB = 1.505149978

    struct Frame {
        let offset: Int
        let length: Int
        let sideInfo: Int       // offset of the side info
        let sideLength: Int
        let channels: Int
        let mpeg1: Bool
        let hasCRC: Bool
    }

    struct Header {
        let mpeg1: Bool
        let versionBits: UInt8
        let sampleRate: Int
        let channels: Int
        let hasCRC: Bool
        let length: Int
    }

    static let bitratesV1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    static let bitratesV2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

    /// Parses a Layer III frame header at `o`. Returns nil when it is not one.
    static func header(_ d: Bytes, _ o: Int) -> Header? {
        guard o >= 0, o + 4 <= d.count, d[o] == 0xFF, d[o + 1] & 0xE0 == 0xE0 else { return nil }
        let version = (d[o + 1] >> 3) & 3          // 0 = 2.5, 2 = MPEG2, 3 = MPEG1
        let layer = (d[o + 1] >> 1) & 3            // 1 = Layer III
        guard version != 1, layer == 1 else { return nil }
        let bitrateIndex = Int(d[o + 2] >> 4)
        let rateIndex = Int((d[o + 2] >> 2) & 3)
        guard bitrateIndex != 15, bitrateIndex != 0, rateIndex != 3 else { return nil }
        let mpeg1 = version == 3
        let base = [44100, 48000, 32000][rateIndex]
        let rate = mpeg1 ? base : (version == 2 ? base / 2 : base / 4)
        let kbps = (mpeg1 ? bitratesV1 : bitratesV2)[bitrateIndex]
        let padding = Int((d[o + 2] >> 1) & 1)
        let length = (mpeg1 ? 144000 : 72000) * kbps / rate + padding
        guard length > 4 else { return nil }
        return Header(mpeg1: mpeg1, versionBits: version, sampleRate: rate,
                      channels: (d[o + 3] >> 6) == 3 ? 1 : 2, hasCRC: d[o + 1] & 1 == 0, length: length)
    }

    /// Where the audio frames start (after any ID3v2 tags).
    static func audioStart(_ d: Bytes) -> Int {
        var o = 0
        while o + 10 <= d.count, d[o] == 0x49, d[o + 1] == 0x44, d[o + 2] == 0x33 {
            let size = (Int(d[o + 6] & 0x7F) << 21) | (Int(d[o + 7] & 0x7F) << 14) | (Int(d[o + 8] & 0x7F) << 7) | Int(d[o + 9] & 0x7F)
            o += 10 + size + (d[o + 5] & 0x10 != 0 ? 10 : 0)
        }
        return min(o, d.count)
    }

    /// Finds the next position where two consistent frame headers follow each other.
    static func sync(_ d: Bytes, from start: Int, limit: Int) -> Int? {
        var o = start
        let end = min(d.count - 4, start + limit)
        while o <= end {
            if d[o] == 0xFF, let h = header(d, o) {
                let next = o + h.length
                if next + 4 > d.count { return o }
                if let n = header(d, next), n.versionBits == h.versionBits, n.sampleRate == h.sampleRate { return o }
            }
            o += 1
        }
        return nil
    }

    static func frames(_ d: Bytes, audioEnd: Int) throws -> [Frame] {
        guard var o = sync(d, from: audioStart(d), limit: 1 << 20) else { throw MP3GainError.notMP3 }
        var out: [Frame] = []
        var first = true
        while o + 4 <= audioEnd {
            guard let h = header(d, o) else {
                // Junk between frames: look a little further, otherwise the audio is over.
                guard let next = sync(d, from: o + 1, limit: 8192), next < audioEnd else { break }
                o = next
                continue
            }
            if o + h.length > audioEnd { break }
            let side = o + 4 + (h.hasCRC ? 2 : 0)
            let sideLength = h.mpeg1 ? (h.channels == 1 ? 17 : 32) : (h.channels == 1 ? 9 : 17)
            guard side + sideLength <= o + h.length else { throw MP3GainError.unsupported("short frame") }
            var skip = false
            if first {
                // The Xing/Info/VBRI frame carries no audio; changing it would break its own checksum.
                let x = side + sideLength
                let tag = d.tag(x)
                if tag == "Xing" || tag == "Info" || d.tag(o + 36) == "VBRI" { skip = true }
                first = false
            }
            if !skip {
                out.append(Frame(offset: o, length: h.length, sideInfo: side, sideLength: sideLength,
                                 channels: h.channels, mpeg1: h.mpeg1, hasCRC: h.hasCRC))
            }
            o += h.length
        }
        guard !out.isEmpty else { throw MP3GainError.notMP3 }
        return out
    }

    /// Bit offsets (from the start of the side info) of every global_gain field.
    static func gainBitOffsets(_ f: Frame) -> [Int] {
        if f.mpeg1 {
            let base = 9 + (f.channels == 1 ? 5 : 3) + 4 * f.channels
            return (0..<(2 * f.channels)).map { base + 59 * $0 + 21 }
        }
        let base = 8 + (f.channels == 1 ? 1 : 2)
        return (0..<f.channels).map { base + 63 * $0 + 21 }
    }

    static func read8(_ d: Bytes, _ byteBase: Int, _ bit: Int) -> UInt8 {
        let i = byteBase + bit / 8, s = bit % 8
        if s == 0 { return d[i] }
        return (d[i] << s) | (d[i + 1] >> (8 - s))
    }

    static func write8(_ d: inout Bytes, _ byteBase: Int, _ bit: Int, _ v: UInt8) {
        let i = byteBase + bit / 8, s = bit % 8
        if s == 0 { d[i] = v; return }
        d[i] = (d[i] & ~(0xFF >> s)) | (v >> s)
        d[i + 1] = (d[i + 1] & (0xFF >> s)) | (v << (8 - s))
    }

    static func crc16(_ d: Bytes, _ ranges: [Range<Int>]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for r in ranges {
            for i in r {
                var byte = UInt16(d[i]) << 8
                for _ in 0..<8 {
                    if (crc ^ byte) & 0x8000 != 0 { crc = (crc << 1) ^ 0x8005 } else { crc <<= 1 }
                    byte <<= 1
                }
            }
        }
        return crc
    }

    public struct Result: Sendable, Equatable {
        public var frames: Int
        public var minGain: Int
        public var maxGain: Int
    }

    /// Shifts every global_gain by `steps` in place. Silent granules (gain 0) stay silent.
    @discardableResult
    static func shift(_ d: inout Bytes, frames: [Frame], steps: Int) -> Result {
        var minG = 255, maxG = 0
        for f in frames {
            for bit in gainBitOffsets(f) {
                let g = Int(read8(d, f.sideInfo, bit))
                guard g != 0 else { continue }
                let n = min(max(g + steps, 0), 255)
                if n != g { write8(&d, f.sideInfo, bit, UInt8(n)) }
                minG = min(minG, n)
                maxG = max(maxG, n)
            }
            if f.hasCRC, steps != 0 {
                let crc = crc16(d, [(f.offset + 2)..<(f.offset + 4), f.sideInfo..<(f.sideInfo + f.sideLength)])
                d[f.offset + 4] = UInt8(crc >> 8)
                d[f.offset + 5] = UInt8(crc & 0xFF)
            }
        }
        if minG > maxG { minG = 0; maxG = 0 }
        return Result(frames: frames.count, minGain: minG, maxGain: maxG)
    }

    // MARK: Tags at the end of the file

    struct Tail {
        var audioEnd: Int
        var apeItems: [APEItem]
        var id3v1: Bytes
    }

    struct APEItem: Equatable {
        var key: String
        var flags: UInt32
        var value: Bytes
    }

    static func tail(_ d: Bytes) -> Tail {
        var end = d.count
        var id3v1 = Bytes()
        if end >= 128, d[end - 128] == 0x54, d[end - 127] == 0x41, d[end - 126] == 0x47 {
            id3v1 = Array(d[(end - 128)..<end])
            end -= 128
        }
        var items: [APEItem] = []
        if end >= 32, d.tag(end - 32) == "APET", d.tag(end - 28) == "AGEX" {
            let size = Int(d.u32(end - 20))          // items + footer
            let count = Int(d.u32(end - 16))
            let flags = d.u32(end - 12)
            let start = end - size
            if size >= 32, start >= 0 {
                var o = start
                for _ in 0..<count {
                    guard o + 8 < end - 32 else { break }
                    let vlen = Int(d.u32(o)), iflags = d.u32(o + 4)
                    var k = o + 8
                    while k < end - 32, d[k] != 0 { k += 1 }
                    guard k < end - 32, k + 1 + vlen <= end - 32 else { break }
                    let key = String(decoding: d[(o + 8)..<k], as: UTF8.self)
                    items.append(APEItem(key: key, flags: iflags, value: Array(d[(k + 1)..<(k + 1 + vlen)])))
                    o = k + 1 + vlen
                }
                end = start - (flags & 0x8000_0000 != 0 && start >= 32 ? 32 : 0)
            }
        }
        return Tail(audioEnd: end, apeItems: items, id3v1: id3v1)
    }

    static func apeTag(_ items: [APEItem]) -> Bytes {
        guard !items.isEmpty else { return [] }
        var body = Bytes()
        for i in items {
            body.appendU32(UInt32(i.value.count))
            body.appendU32(i.flags)
            body.append(contentsOf: Array(i.key.utf8))
            body.append(0)
            body.append(contentsOf: i.value)
        }
        func block(_ flags: UInt32) -> Bytes {
            var b = Bytes()
            b.append(contentsOf: Array("APETAGEX".utf8))
            b.appendU32(2000)
            b.appendU32(UInt32(body.count + 32))
            b.appendU32(UInt32(items.count))
            b.appendU32(flags)
            b.appendZeros(8)
            return b
        }
        return block(0xA000_0000) + body + block(0x8000_0000)
    }

    static func undoSteps(_ items: [APEItem]) -> Int? {
        guard let item = items.first(where: { $0.key.uppercased() == "MP3GAIN_UNDO" }) else { return nil }
        let text = String(decoding: item.value, as: UTF8.self)
        guard let first = text.split(separator: ",").first else { return nil }
        return Int(first.replacingOccurrences(of: "+", with: "").trimmingCharacters(in: .whitespaces))
    }

    // MARK: Whole files

    /// Applies `steps` to MP3 data and records the undo information. Returns the new file contents.
    public static func apply(to data: Bytes, steps: Int) throws -> (Bytes, Result) {
        var t = tail(data)
        let fr = try frames(data, audioEnd: t.audioEnd)
        var audio = Array(data[0..<t.audioEnd])
        let result = shift(&audio, frames: fr, steps: steps)
        let undo = (undoSteps(t.apeItems) ?? 0) - steps
        t.apeItems.removeAll { ["MP3GAIN_UNDO", "MP3GAIN_MINMAX"].contains($0.key.uppercased()) }
        if undo != 0 {
            let u = String(format: "%+04d,%+04d,N", undo, undo)
            let m = String(format: "%03d,%03d", result.minGain, result.maxGain)
            t.apeItems.append(APEItem(key: "MP3GAIN_MINMAX", flags: 0, value: Array(m.utf8)))
            t.apeItems.append(APEItem(key: "MP3GAIN_UNDO", flags: 0, value: Array(u.utf8)))
        }
        return (audio + apeTag(t.apeItems) + t.id3v1, result)
    }

    /// Steps that would restore the original volume, if the file was changed before.
    public static func pendingUndo(in data: Bytes) -> Int? {
        let u = undoSteps(tail(data).apeItems)
        return u == 0 ? nil : u
    }

    /// Restores the original volume. Returns nil when the file carries no undo information.
    public static func undo(_ data: Bytes) throws -> Bytes? {
        guard let u = pendingUndo(in: data) else { return nil }
        return try apply(to: data, steps: u).0
    }

    /// Rewrites a file through a temporary file next to it, so an interruption can't leave it half-written.
    static func replace(_ url: URL, with bytes: Bytes) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".ipm-" + url.lastPathComponent)
        let fm = FileManager.default
        try? fm.removeItem(at: tmp)
        do {
            try Data(bytes).write(to: tmp)
            if rename(tmp.path, url.path) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    static let maxFileSize = 300 * 1024 * 1024

    static func checkSize(_ url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size > maxFileSize { throw MP3GainError.unsupported("file is too large") }
    }

    /// Changes a file on disk. Returns its new size.
    public static func applyToFile(_ url: URL, steps: Int) throws -> Int {
        try checkSize(url)
        let data = Bytes(try Data(contentsOf: url))
        let (out, _) = try apply(to: data, steps: steps)
        try replace(url, with: out)
        return out.count
    }

    /// Restores a file on disk. Returns its new size, or nil when there was nothing to undo.
    public static func undoFile(_ url: URL) throws -> Int? {
        try checkSize(url)
        let data = Bytes(try Data(contentsOf: url))
        guard let out = try undo(data) else { return nil }
        try replace(url, with: out)
        return out.count
    }
}
