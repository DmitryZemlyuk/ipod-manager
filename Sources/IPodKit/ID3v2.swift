import Foundation

/// ID3v2 tag reader/writer for MP3 files. Tags are kept in the version they were found in
/// (2.3 or 2.4; 2.2 is upgraded to 2.3) and frames we don't set are copied as they are.
enum ID3v2 {
    struct Frame: Equatable {
        var id: String
        var flags: Int
        var data: Bytes
    }

    struct Tag: Equatable {
        /// 3 or 4.
        var version: Int
        var frames: [Frame]
    }

    /// Padding left after the frames when the whole file has to be rewritten anyway.
    static let padding = 4096

    static func syncsafe(_ d: Bytes, _ o: Int) -> Int {
        Int(d[o] & 0x7F) << 21 | Int(d[o + 1] & 0x7F) << 14 | Int(d[o + 2] & 0x7F) << 7 | Int(d[o + 3] & 0x7F)
    }

    static func appendSyncsafe(_ out: inout Bytes, _ v: Int) {
        out.append(UInt8((v >> 21) & 0x7F))
        out.append(UInt8((v >> 14) & 0x7F))
        out.append(UInt8((v >> 7) & 0x7F))
        out.append(UInt8(v & 0x7F))
    }

    static func deunsync(_ d: Bytes) -> Bytes {
        var out = Bytes()
        out.reserveCapacity(d.count)
        var i = 0
        while i < d.count {
            out.append(d[i])
            if d[i] == 0xFF, i + 1 < d.count, d[i + 1] == 0x00 { i += 1 }
            i += 1
        }
        return out
    }

    static func validID(_ d: Bytes, _ o: Int, _ n: Int) -> Bool {
        guard o + n <= d.count else { return false }
        for i in 0..<n {
            let c = d[o + i]
            if !((c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)) { return false }
        }
        return true
    }

    /// Reads the tag at the start of a file. Returns the tag (nil when there is none) and the
    /// number of bytes all leading ID3v2 tags occupy.
    static func parse(_ d: Bytes) throws -> (Tag?, Int) {
        guard d.count >= 10, d[0] == 0x49, d[1] == 0x44, d[2] == 0x33 else { return (nil, 0) }
        let major = Int(d[3]), flags = d[5]
        let size = syncsafe(d, 6)
        var total = 10 + size + (major == 4 && flags & 0x10 != 0 ? 10 : 0)
        guard total <= d.count else { throw FileTagsError.unsupported("damaged ID3v2 tag") }
        guard (2...4).contains(major) else { throw FileTagsError.unsupported("ID3v2.\(major)") }
        if major == 2, flags & 0x40 != 0 { throw FileTagsError.unsupported("compressed ID3v2.2 tag") }

        var body = Array(d[10..<(10 + size)])
        if major < 4, flags & 0x80 != 0 { body = deunsync(body) }
        var o = 0
        if major >= 3, flags & 0x40 != 0 {
            // extended header
            guard body.count >= 4 else { throw FileTagsError.unsupported("damaged ID3v2 tag") }
            o = major == 3 ? 4 + body.be32(0) : syncsafe(body, 0)
            guard o <= body.count else { throw FileTagsError.unsupported("damaged ID3v2 tag") }
        }

        var frames: [Frame] = []
        if major == 2 {
            while o + 6 <= body.count, body[o] != 0, validID(body, o, 3) {
                let id = String(decoding: body[o..<(o + 3)], as: UTF8.self)
                let len = body.be24(o + 3)
                guard o + 6 + len <= body.count else { break }
                let data = Array(body[(o + 6)..<(o + 6 + len)])
                if let f = upgrade(id: id, data: data) { frames.append(f) }
                o += 6 + len
            }
        } else {
            while o + 10 <= body.count, body[o] != 0, validID(body, o, 4) {
                let id = String(decoding: body[o..<(o + 4)], as: UTF8.self)
                var len = major == 4 ? syncsafe(body, o + 4) : body.be32(o + 4)
                if major == 4 {
                    // Some writers (old iTunes) stored plain sizes in 2.4 tags. Pick the reading that lands on a frame.
                    let plain = body.be32(o + 4)
                    if plain != len, !landsOnFrame(body, o + 10 + len), landsOnFrame(body, o + 10 + plain) { len = plain }
                }
                let frameFlags = body.be16(o + 8)
                guard len >= 0, o + 10 + len <= body.count else { break }
                var data = Array(body[(o + 10)..<(o + 10 + len)])
                var keptFlags = frameFlags
                if major == 4, frameFlags & 0x0002 != 0 {
                    data = deunsync(data)
                    keptFlags &= ~0x0002
                }
                frames.append(Frame(id: id, flags: keptFlags, data: data))
                o += 10 + len
            }
        }

        // Further tags directly behind the first one are dropped (they are not valid anyway).
        while total + 10 <= d.count, d[total] == 0x49, d[total + 1] == 0x44, d[total + 2] == 0x33 {
            let more = 10 + syncsafe(d, total + 6) + (d[total + 5] & 0x10 != 0 ? 10 : 0)
            guard total + more <= d.count else { break }
            total += more
        }
        return (Tag(version: major == 4 ? 4 : 3, frames: frames), total)
    }

    static func landsOnFrame(_ body: Bytes, _ o: Int) -> Bool {
        if o == body.count { return true }
        if o > body.count { return false }
        if body[o] == 0 { return true }
        return validID(body, o, 4)
    }

    static let v22Map: [String: String] = [
        "TT1": "TIT1", "TT2": "TIT2", "TT3": "TIT3", "TP1": "TPE1", "TP2": "TPE2", "TP3": "TPE3", "TP4": "TPE4",
        "TAL": "TALB", "TCO": "TCON", "TCM": "TCOM", "TYE": "TYER", "TRK": "TRCK", "TPA": "TPOS", "TCP": "TCMP",
        "TEN": "TENC", "TSS": "TSSE", "TBP": "TBPM", "TCR": "TCOP", "TDA": "TDAT", "TIM": "TIME", "TKE": "TKEY",
        "TLA": "TLAN", "TLE": "TLEN", "TMT": "TMED", "TOA": "TOPE", "TOF": "TOFN", "TOL": "TOLY", "TOR": "TORY",
        "TOT": "TOAL", "TPB": "TPUB", "TRC": "TSRC", "TRD": "TRDA", "TXT": "TEXT", "TXX": "TXXX", "TSA": "TSOA",
        "TSP": "TSOP", "TST": "TSOT", "TS2": "TSO2", "TSC": "TSOC",
        "COM": "COMM", "ULT": "USLT", "UFI": "UFID", "WXX": "WXXX", "WAR": "WOAR", "WCM": "WCOM", "CNT": "PCNT",
        "POP": "POPM", "MCI": "MCDI"
    ]

    /// Converts an ID3v2.2 frame into its 2.3 form. Unknown frames are dropped.
    static func upgrade(id: String, data: Bytes) -> Frame? {
        if id == "PIC" {
            guard data.count > 5 else { return nil }
            let format = String(decoding: data[1..<4], as: UTF8.self).uppercased()
            let mime = format == "PNG" ? "image/png" : "image/jpeg"
            var out: Bytes = [data[0]]
            out.append(contentsOf: Array(mime.utf8))
            out.append(0)
            out.append(contentsOf: data[4...])
            return Frame(id: "APIC", flags: 0, data: out)
        }
        guard let new = v22Map[id] else { return nil }
        return Frame(id: new, flags: 0, data: data)
    }

    // MARK: Text frames

    static func text(_ f: Frame) -> String {
        guard let enc = f.data.first else { return "" }
        let raw = Array(f.data.dropFirst())
        var s: String
        switch enc {
        case 1, 2:
            var bytes = raw
            var bigEndian = enc == 2
            if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE { bigEndian = false; bytes.removeFirst(2) }
            else if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { bigEndian = true; bytes.removeFirst(2) }
            var units: [UInt16] = []
            var i = 0
            while i + 1 < bytes.count {
                let u = bigEndian ? UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) : UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i])
                if u == 0 { break }
                units.append(u)
                i += 2
            }
            s = String(decoding: units, as: UTF16.self)
        case 3:
            s = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        default:
            s = String(String.UnicodeScalarView(raw.prefix { $0 != 0 }.map { Unicode.Scalar($0) }))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func textFrame(_ id: String, _ value: String, version: Int) -> Frame {
        var data = Bytes()
        if version == 4 {
            data.append(3)
            data.append(contentsOf: Array(value.utf8))
        } else if value.unicodeScalars.allSatisfy({ $0.value < 256 }) {
            data.append(0)
            data.append(contentsOf: value.unicodeScalars.map { UInt8($0.value) })
        } else {
            data.append(1)
            data.append(contentsOf: [0xFF, 0xFE])
            for u in value.utf16 {
                data.append(UInt8(truncatingIfNeeded: u))
                data.append(UInt8(truncatingIfNeeded: u >> 8))
            }
        }
        return Frame(id: id, flags: 0, data: data)
    }

    // MARK: Applying changes

    static func apply(_ w: TagWrite, to tag: inout Tag) {
        func set(_ id: String, _ value: String?) {
            guard let value else { return }
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let existing = tag.frames.filter { $0.id == id }
            if v.isEmpty {
                tag.frames.removeAll { $0.id == id }
            } else if existing.count == 1, text(existing[0]) == v {
                // already there: keep the original bytes
            } else {
                let frame = textFrame(id, v, version: tag.version)
                if let i = tag.frames.firstIndex(where: { $0.id == id }) {
                    tag.frames[i] = frame
                    var seen = false
                    tag.frames.removeAll { f in
                        guard f.id == id else { return false }
                        if !seen { seen = true; return false }
                        return true
                    }
                } else {
                    tag.frames.append(frame)
                }
            }
        }
        set("TIT2", w.title)
        set("TPE1", w.artist)
        set("TALB", w.album)
        set("TPE2", w.albumArtist)
        set("TCON", w.genre)
        set("TCOM", w.composer)
        if let y = w.year {
            if tag.version == 4 {
                tag.frames.removeAll { $0.id == "TYER" }
                let current = tag.frames.first { $0.id == "TDRC" }.map { text($0) } ?? ""
                if y <= 0 {
                    set("TDRC", "")
                } else if !current.hasPrefix(String(y)) {
                    set("TDRC", String(y))
                }
            } else {
                tag.frames.removeAll { $0.id == "TDRC" }
                set("TYER", y > 0 ? String(y) : "")
            }
        }
        if let t = w.track { set("TRCK", t.isEmpty ? "" : t.text) }
        if let d = w.disc { set("TPOS", d.isEmpty ? "" : d.text) }
        if let c = w.compilation { set("TCMP", c ? "1" : "") }
        switch w.artwork {
        case .remove:
            tag.frames.removeAll { $0.id == "APIC" }
        case .set(let image):
            var data: Bytes = [0]
            data.append(contentsOf: Array(FileTags.imageMIME(image).utf8))
            data.append(0)
            data.append(3)      // front cover
            data.append(0)      // empty description
            data.append(contentsOf: image)
            let frame = Frame(id: "APIC", flags: 0, data: data)
            let existing = tag.frames.filter { $0.id == "APIC" }
            if !(existing.count == 1 && existing[0] == frame) {
                tag.frames.removeAll { $0.id == "APIC" }
                tag.frames.append(frame)
            }
        case nil:
            break
        }
    }

    static func frameBytes(_ tag: Tag) -> Bytes {
        var out = Bytes()
        for f in tag.frames {
            out.append(contentsOf: Array(f.id.utf8))
            if tag.version == 4 { appendSyncsafe(&out, f.data.count) } else { out.appendBE32(f.data.count) }
            out.appendBE16(f.flags)
            out.append(contentsOf: f.data)
        }
        return out
    }

    /// A complete tag whose body (frames + padding) is `bodySize` bytes.
    static func serialize(_ tag: Tag, bodySize: Int) -> Bytes {
        let frames = frameBytes(tag)
        var out: Bytes = [0x49, 0x44, 0x33, UInt8(tag.version), 0, 0]
        appendSyncsafe(&out, max(bodySize, frames.count))
        out.append(contentsOf: frames)
        out.appendZeros(bodySize - frames.count)
        return out
    }

    /// Works out how to store the changes in an MP3 file. nil = nothing to change.
    static func plan(_ w: TagWrite, file d: Bytes) throws -> FileTags.Plan? {
        let (found, oldLength) = try parse(d)
        // Make sure this really is MP3 audio before touching anything.
        guard MP3Gain.sync(d, from: oldLength, limit: 1 << 20) != nil else { throw FileTagsError.unsupported("not an MP3 file") }
        var tag = found ?? Tag(version: 3, frames: [])
        let before = tag
        apply(w, to: &tag)
        if tag == before { return nil }
        let size = frameBytes(tag).count
        guard size < (1 << 28) - padding else { throw FileTagsError.unsupported("tag too large") }
        if found != nil, 10 + size <= oldLength {
            return .patch(offset: 0, bytes: serialize(tag, bodySize: oldLength - 10))
        }
        return .rewrite(serialize(tag, bodySize: size + padding) + Array(d[oldLength...]))
    }
}
