import Foundation

/// iTunes-style metadata writer for M4A files (moov › udta › meta › ilst).
/// Only the moov atom is rebuilt; audio data (mdat) is never modified. When moov changes size
/// and sits in front of the audio, the chunk offset tables (stco/co64) are shifted accordingly.
enum MP4Tags {
    struct Atom {
        var type: String
        var offset: Int
        var header: Int
        var size: Int

        var end: Int { offset + size }
        var payload: Int { offset + header }
    }

    struct Item: Equatable {
        var type: String
        var raw: Bytes
    }

    /// Padding added when the file has to be rewritten, so later edits fit in place.
    static let padding = 4096

    static let kTitle = "\u{A9}nam", kArtist = "\u{A9}ART", kAlbum = "\u{A9}alb", kAlbumArtist = "aART"
    static let kGenre = "\u{A9}gen", kComposer = "\u{A9}wrt", kYear = "\u{A9}day"

    static func typeString(_ d: Bytes, _ o: Int) -> String {
        String(String.UnicodeScalarView(d[o..<(o + 4)].map { Unicode.Scalar($0) }))
    }

    static func typeBytes(_ s: String) -> Bytes {
        let b = s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
        return Array((b + [0x20, 0x20, 0x20, 0x20]).prefix(4))
    }

    /// The atom starting at `o`, if there is a well-formed one that fits before `to`.
    static func atomAt(_ d: Bytes, _ o: Int, _ to: Int) -> Atom? {
        guard o >= 0, o + 8 <= to, to <= d.count else { return nil }
        var size = d.be32(o)
        var header = 8
        if size == 1 {
            guard o + 16 <= to else { return nil }
            let big = d.be64(o + 8)
            guard big <= UInt64(to - o) else { return nil }
            size = Int(big)
            header = 16
        } else if size == 0 {
            size = to - o
        }
        guard size >= header, o + size <= to else { return nil }
        return Atom(type: typeString(d, o + 4), offset: o, header: header, size: size)
    }

    /// Child atoms in d[from..<to]. Throws when the structure doesn't add up.
    static func atoms(_ d: Bytes, _ from: Int, _ to: Int) throws -> [Atom] {
        var out: [Atom] = []
        var o = from
        while o < to {
            guard let a = atomAt(d, o, to) else { throw FileTagsError.unsupported("damaged MP4 structure") }
            out.append(a)
            o = a.end
        }
        return out
    }

    /// Top-level atoms; stops quietly at trailing junk (some files carry a stray tag at the end).
    static func topLevelAtoms(_ d: Bytes) -> [Atom] {
        var out: [Atom] = []
        var o = 0
        while o + 8 <= d.count {
            guard isAtomType(d, o + 4), let one = atomAt(d, o, d.count) else { break }
            out.append(one)
            o = one.end
        }
        return out
    }

    /// Atom types are four printable characters (or the © byte).
    static func isAtomType(_ d: Bytes, _ o: Int) -> Bool {
        guard o + 4 <= d.count else { return false }
        return d[o..<(o + 4)].allSatisfy { ($0 >= 0x20 && $0 < 0x7F) || $0 == 0xA9 }
    }

    static func atom(_ type: String, _ payload: Bytes) -> Bytes {
        var out = Bytes()
        out.reserveCapacity(payload.count + 8)
        out.appendBE32(payload.count + 8)
        out.append(contentsOf: typeBytes(type))
        out.append(contentsOf: payload)
        return out
    }

    static func free(_ size: Int) -> Bytes {
        atom("free", Bytes(repeating: 0, count: max(size, 8) - 8))
    }

    static func dataItem(_ key: String, type: Int, _ value: Bytes) -> Item {
        var payload = Bytes()
        payload.appendBE32(type)
        payload.appendBE32(0)
        payload.append(contentsOf: value)
        return Item(type: key, raw: atom(key, atom("data", payload)))
    }

    static func textItem(_ key: String, _ value: String) -> Item {
        dataItem(key, type: 1, Array(value.utf8))
    }

    /// Text stored in an item's data atom ("" when it is not text).
    static func text(_ item: Item) -> String {
        let r = item.raw
        guard r.count >= 24, typeString(r, 12) == "data", r.be32(16) == 1 else { return "" }
        return String(decoding: r[24...], as: UTF8.self)
    }

    // MARK: Applying changes

    static func apply(_ w: TagWrite, to items: inout [Item]) {
        func put(_ item: Item?, key: String) {
            guard let item else {
                items.removeAll { $0.type == key }
                return
            }
            let existing = items.filter { $0.type == key }
            if existing.count == 1, existing[0] == item { return }
            if let i = items.firstIndex(where: { $0.type == key }) {
                items[i] = item
                var seen = false
                items.removeAll { x in
                    guard x.type == key else { return false }
                    if !seen { seen = true; return false }
                    return true
                }
            } else {
                items.append(item)
            }
        }
        func setText(_ key: String, _ value: String?) {
            guard let value else { return }
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            put(v.isEmpty ? nil : textItem(key, v), key: key)
        }
        setText(kTitle, w.title)
        setText(kArtist, w.artist)
        setText(kAlbum, w.album)
        setText(kAlbumArtist, w.albumArtist)
        setText(kComposer, w.composer)
        if let g = w.genre {
            items.removeAll { $0.type == "gnre" }     // numeric ID3v1 genre
            setText(kGenre, g)
        }
        if let y = w.year {
            let current = items.first { $0.type == kYear }.map { text($0) } ?? ""
            if y <= 0 {
                put(nil, key: kYear)
            } else if !current.hasPrefix(String(y)) {
                setText(kYear, String(y))
            }
        }
        if let t = w.track {
            var v = Bytes([0, 0])
            v.appendBE16(min(t.number, 0xFFFF))
            v.appendBE16(min(t.total, 0xFFFF))
            v.append(contentsOf: [0, 0])
            put(t.isEmpty ? nil : dataItem("trkn", type: 0, v), key: "trkn")
        }
        if let d = w.disc {
            var v = Bytes([0, 0])
            v.appendBE16(min(d.number, 0xFFFF))
            v.appendBE16(min(d.total, 0xFFFF))
            put(d.isEmpty ? nil : dataItem("disk", type: 0, v), key: "disk")
        }
        if let c = w.compilation {
            put(c ? dataItem("cpil", type: 21, [1]) : nil, key: "cpil")
        }
        switch w.artwork {
        case .remove:
            put(nil, key: "covr")
        case .set(let image):
            let type = FileTags.imageMIME(image) == "image/png" ? 14 : 13
            put(dataItem("covr", type: type, [UInt8](image)), key: "covr")
        case nil:
            break
        }
    }

    // MARK: Planning the write

    static func plan(_ w: TagWrite, file d: Bytes) throws -> FileTags.Plan? {
        let top = topLevelAtoms(d)
        guard top.first?.type == "ftyp" else { throw FileTagsError.unsupported("not an MP4 file") }
        guard !top.contains(where: { $0.type == "moof" }) else { throw FileTagsError.unsupported("fragmented MP4") }
        guard top.contains(where: { $0.type == "mdat" }) else { throw FileTagsError.unsupported("no audio data") }
        let moovIndexes = top.indices.filter { top[$0].type == "moov" }
        guard moovIndexes.count == 1, let moovIndex = moovIndexes.first, top[moovIndex].header == 8 else {
            throw FileTagsError.unsupported("unexpected MP4 layout")
        }
        let moov = top[moovIndex]

        // moov › udta › meta › ilst
        let moovKids = try atoms(d, moov.payload, moov.end)
        let udta = moovKids.first { $0.type == "udta" }
        var udtaKids: [Atom] = []
        var meta: Atom?
        var metaKids: [Atom] = []
        var items: [Item] = []
        if let udta {
            guard udta.header == 8 else { throw FileTagsError.unsupported("unexpected MP4 layout") }
            udtaKids = try atoms(d, udta.payload, udta.end)
            meta = udtaKids.first { $0.type == "meta" }
            if let meta {
                guard meta.header == 8, meta.size >= 12 else { throw FileTagsError.unsupported("unexpected MP4 layout") }
                metaKids = try atoms(d, meta.payload + 4, meta.end)
                guard metaKids.contains(where: { $0.type == "hdlr" }) else { throw FileTagsError.unsupported("unexpected MP4 metadata") }
                if let ilst = metaKids.first(where: { $0.type == "ilst" }) {
                    items = try atoms(d, ilst.payload, ilst.end).map { Item(type: $0.type, raw: Array(d[$0.offset..<$0.end])) }
                }
            }
        }

        let before = items
        apply(w, to: &items)
        if items == before { return nil }
        let newIlst = atom("ilst", items.flatMap { $0.raw })

        // Rebuild meta, letting a free atom inside it absorb the size change when possible.
        var metaParts: [(type: String, raw: Bytes)]
        var oldMetaSize = 0
        if let meta {
            oldMetaSize = meta.size
            metaParts = metaKids.map { ($0.type, Array(d[$0.offset..<$0.end])) }
            if let i = metaParts.firstIndex(where: { $0.type == "ilst" }) {
                metaParts[i].raw = newIlst
            } else {
                metaParts.append(("ilst", newIlst))
            }
        } else {
            var hdlr = Bytes(repeating: 0, count: 8)
            hdlr.append(contentsOf: typeBytes("mdir"))
            hdlr.append(contentsOf: typeBytes("appl"))
            hdlr.appendZeros(9)
            metaParts = [("hdlr", atom("hdlr", hdlr)), ("ilst", newIlst)]
        }
        func metaSize() -> Int { 12 + metaParts.reduce(0) { $0 + $1.raw.count } }
        if meta != nil {
            let diff = metaSize() - oldMetaSize
            if diff != 0 {
                if let fi = metaParts.firstIndex(where: { $0.type == "free" && $0.raw.count >= 8 && $0.raw.be32(0) == $0.raw.count }) {
                    let f = metaParts[fi].raw.count
                    if f - diff >= 8 {
                        metaParts[fi].raw = free(f - diff)
                    } else if f == diff {
                        metaParts.remove(at: fi)
                    }
                } else if -diff >= 8 {
                    metaParts.append(("free", free(-diff)))
                }
            }
        }
        var metaPayload = Bytes([0, 0, 0, 0])
        if let meta { metaPayload = Array(d[meta.payload..<(meta.payload + 4)]) }
        for p in metaParts { metaPayload.append(contentsOf: p.raw) }
        let newMeta = atom("meta", metaPayload)

        // udta and moov with the new pieces in place
        var udtaPayload = Bytes()
        if udta != nil {
            var replaced = false
            for k in udtaKids {
                if k.type == "meta", !replaced {
                    udtaPayload.append(contentsOf: newMeta)
                    replaced = true
                } else {
                    udtaPayload.append(contentsOf: d[k.offset..<k.end])
                }
            }
            if !replaced { udtaPayload.append(contentsOf: newMeta) }
        } else {
            udtaPayload = newMeta
        }
        let newUdta = atom("udta", udtaPayload)
        var moovPayload = Bytes()
        var placed = false
        for k in moovKids {
            if k.type == "udta", !placed {
                moovPayload.append(contentsOf: newUdta)
                placed = true
            } else {
                moovPayload.append(contentsOf: d[k.offset..<k.end])
            }
        }
        if !placed { moovPayload.append(contentsOf: newUdta) }
        var newMoov = atom("moov", moovPayload)
        let delta = newMoov.count - moov.size

        if delta == 0 { return .patch(offset: moov.offset, bytes: newMoov) }

        // A free atom right behind moov can absorb the difference too.
        let next: Atom? = moovIndex + 1 < top.count ? top[moovIndex + 1] : nil
        let nextFree = next.flatMap { $0.type == "free" && $0.header == 8 && d.be32($0.offset) == $0.size ? $0 : nil }
        if let nf = nextFree {
            if nf.size - delta >= 8 { return .patch(offset: moov.offset, bytes: newMoov + free(nf.size - delta)) }
            if nf.size == delta { return .patch(offset: moov.offset, bytes: newMoov) }
        } else if -delta >= 8 {
            return .patch(offset: moov.offset, bytes: newMoov + free(-delta))
        }

        // The file has to be rewritten. Everything behind the old moov moves by `shift`.
        let audioBehind = top.contains { $0.type == "mdat" && $0.offset > moov.offset }
        let shift = delta + padding
        if audioBehind {
            try shiftChunkOffsets(&newMoov, from: moov.end, by: shift)
        }
        var out = Bytes()
        out.reserveCapacity(d.count + shift)
        out.append(contentsOf: d[0..<moov.offset])
        out.append(contentsOf: newMoov)
        out.append(contentsOf: free(padding))
        out.append(contentsOf: d[moov.end...])
        return .rewrite(out)
    }

    /// Adds `shift` to every chunk offset that points at or behind `boundary` (old file positions).
    static func shiftChunkOffsets(_ moov: inout Bytes, from boundary: Int, by shift: Int) throws {
        func walk(_ from: Int, _ to: Int, _ depth: Int) throws {
            for a in try atoms(moov, from, to) {
                switch a.type {
                case "trak", "mdia", "minf", "stbl":
                    if depth < 8 { try walk(a.payload, a.end, depth + 1) }
                case "stco":
                    let n = moov.be32(a.payload + 4)
                    guard a.payload + 8 + n * 4 <= a.end else { throw FileTagsError.unsupported("damaged MP4 structure") }
                    for i in 0..<n {
                        let p = a.payload + 8 + i * 4
                        let v = moov.be32(p)
                        if v >= boundary {
                            guard v + shift >= 0, v + shift <= 0xFFFF_FFFF else { throw FileTagsError.unsupported("file too large for its offset table") }
                            moov.setBE32(p, v + shift)
                        }
                    }
                case "co64":
                    let n = moov.be32(a.payload + 4)
                    guard a.payload + 8 + n * 8 <= a.end else { throw FileTagsError.unsupported("damaged MP4 structure") }
                    for i in 0..<n {
                        let p = a.payload + 8 + i * 8
                        let v = moov.be64(p)
                        if v >= UInt64(boundary) { moov.setBE64(p, UInt64(Int64(v) + Int64(shift))) }
                    }
                case "saio":
                    throw FileTagsError.unsupported("protected MP4")
                default:
                    break
                }
            }
        }
        try walk(8, moov.count, 0)
    }
}
