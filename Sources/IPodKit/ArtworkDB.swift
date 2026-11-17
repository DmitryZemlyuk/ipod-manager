import Foundation
import CoreGraphics
import ImageIO

/// One cover art size the iPod stores (pixels are RGB565, little-endian).
public struct ArtworkFormat: Sendable, Equatable {
    public let id: UInt32
    public let width: Int
    public let height: Int

    public var byteSize: Int { width * height * 2 }

    /// iPod 5th generation (iPod Video): 100×100 list thumbnail and 200×200 Now Playing cover.
    public static let video: [ArtworkFormat] = [
        ArtworkFormat(id: 1028, width: 100, height: 100),
        ArtworkFormat(id: 1029, width: 200, height: 200)
    ]

    public static func known(_ id: UInt32) -> ArtworkFormat? {
        video.first { $0.id == id }
    }
}

public enum ArtworkDBError: Error, LocalizedError {
    case bad(String)

    public var errorDescription: String? {
        switch self {
        case .bad(let s): return "ArtworkDB: \(s)"
        }
    }
}

/// iPod_Control/Artwork/ArtworkDB. Layout follows libgpod (db-artwork-parser/writer):
/// mhfd → mhsd(1) mhli → mhii…, mhsd(2) mhla, mhsd(3) mhlf → mhif…
/// Existing records are kept byte for byte; we only add and remove image items.
public struct ArtworkDB: Sendable {
    struct DataSet: Sendable {
        var header: Bytes
        var listHeader: Bytes
        var items: [Bytes]
        var index: UInt16 { header.u16(12) }
    }

    public struct ThumbRef: Sendable, Equatable {
        public let formatID: UInt32
        public let offset: Int
        public let size: Int
        public let fileName: String
    }

    var header: Bytes
    var sets: [DataSet]
    private var byImageID: [UInt32: Int] = [:]
    private var bySongID: [UInt64: Int] = [:]

    // MARK: Parsing

    public static func parse(_ d: Bytes) throws -> ArtworkDB {
        guard d.tag(0) == "mhfd" else { throw ArtworkDBError.bad("no mhfd header") }
        let hl = Int(d.u32(4))
        let n = Int(d.u32(20))
        guard hl >= 32, hl <= d.count else { throw ArtworkDBError.bad("bad header length") }
        var db = ArtworkDB(header: Array(d[0..<hl]), sets: [])
        var o = hl
        for _ in 0..<n {
            guard d.tag(o) == "mhsd" else { throw ArtworkDBError.bad("expected mhsd at \(o)") }
            let shl = Int(d.u32(o + 4)), stl = Int(d.u32(o + 8))
            guard shl >= 16, stl >= shl, o + stl <= d.count else { throw ArtworkDBError.bad("bad mhsd at \(o)") }
            let lo = o + shl
            let lhl = Int(d.u32(lo + 4)), count = Int(d.u32(lo + 8))
            guard lhl >= 12, lo + lhl <= o + stl else { throw ArtworkDBError.bad("bad list at \(lo)") }
            var set = DataSet(header: Array(d[o..<lo]), listHeader: Array(d[lo..<(lo + lhl)]), items: [])
            var p = lo + lhl
            for _ in 0..<count {
                let itl = Int(d.u32(p + 8))
                guard itl >= 12, p + itl <= o + stl else { throw ArtworkDBError.bad("bad item at \(p)") }
                set.items.append(Array(d[p..<(p + itl)]))
                p += itl
            }
            db.sets.append(set)
            o += stl
        }
        db.reindex()
        return db
    }

    public static func makeEmpty() -> ArtworkDB {
        var h = Bytes(repeating: 0, count: 0x84)
        h.setTag(0, "mhfd")
        h.setU32(16, 2)
        h.setU32(28, 100)
        h.setU8(48, 2)
        func set(_ index: UInt16, _ tag: String) -> DataSet {
            var sh = Bytes(repeating: 0, count: 0x60)
            sh.setTag(0, "mhsd")
            sh.setU16(12, index)
            var lh = Bytes(repeating: 0, count: 0x5C)
            lh.setTag(0, tag)
            return DataSet(header: sh, listHeader: lh, items: [])
        }
        var db = ArtworkDB(header: h, sets: [set(1, "mhli"), set(2, "mhla"), set(3, "mhlf")])
        db.reindex()
        return db
    }

    public func serialize() -> Bytes {
        var body = Bytes()
        for s in sets {
            var list = s.listHeader
            list.setU32(4, UInt32(list.count))
            list.setU32(8, UInt32(s.items.count))
            for i in s.items { list.append(contentsOf: i) }
            var sh = s.header
            sh.setU32(4, UInt32(sh.count))
            sh.setU32(8, UInt32(sh.count + list.count))
            body.append(contentsOf: sh)
            body.append(contentsOf: list)
        }
        var h = header
        h.setU32(4, UInt32(h.count))
        h.setU32(8, UInt32(h.count + body.count))
        h.setU32(20, UInt32(sets.count))
        return h + body
    }

    private var imageSet: Int? { sets.firstIndex { $0.index == 1 } }
    private var fileSet: Int? { sets.firstIndex { $0.index == 3 } }

    mutating func reindex() {
        byImageID = [:]
        bySongID = [:]
        guard let si = imageSet else { return }
        for (i, item) in sets[si].items.enumerated() where item.tag(0) == "mhii" {
            byImageID[item.u32(16)] = i
            let song = item.u64(20)
            if song != 0 { bySongID[song] = i }
        }
    }

    // MARK: Queries

    public var imageCount: Int { imageSet.map { sets[$0].items.count } ?? 0 }

    /// Format ids listed in the file list (mhif).
    public var formatIDs: Set<UInt32> {
        guard let fi = fileSet else { return [] }
        return Set(sets[fi].items.filter { $0.tag(0) == "mhif" }.map { $0.u32(16) })
    }

    /// True when this database only uses the formats we can write.
    public var isWritable: Bool {
        formatIDs.isSubset(of: Set(ArtworkFormat.video.map { $0.id }))
    }

    func itemIndex(imageID: UInt32, songID: UInt64) -> Int? {
        if imageID != 0, let i = byImageID[imageID] { return i }
        if songID != 0, let i = bySongID[songID] { return i }
        return nil
    }

    public func hasImage(imageID: UInt32, songID: UInt64) -> Bool {
        itemIndex(imageID: imageID, songID: songID) != nil
    }

    public func thumbs(imageID: UInt32, songID: UInt64) -> [ThumbRef] {
        guard let si = imageSet, let i = itemIndex(imageID: imageID, songID: songID) else { return [] }
        return ArtworkDB.thumbs(in: sets[si].items[i])
    }

    static func thumbs(in mhii: Bytes) -> [ThumbRef] {
        var out: [ThumbRef] = []
        let n = Int(mhii.u32(12))
        var o = Int(mhii.u32(4))
        for _ in 0..<n {
            guard mhii.tag(o) == "mhod" else { break }
            let tl = Int(mhii.u32(o + 8))
            guard tl >= 24, o + tl <= mhii.count else { break }
            if mhii.u16(o + 12) == 2 {
                let ni = o + Int(mhii.u32(o + 4))
                if mhii.tag(ni) == "mhni" {
                    let nhl = Int(mhii.u32(ni + 4))
                    var name = ""
                    let so = ni + nhl
                    if mhii.tag(so) == "mhod", mhii.u16(so + 12) == 3 {
                        let len = Int(mhii.u32(so + 24))
                        let enc = mhii.u8(so + 28)
                        let start = so + 36
                        if len > 0, start + len <= mhii.count {
                            let raw = Array(mhii[start..<(start + len)])
                            if enc == 2 {
                                var units = [UInt16]()
                                var k = 0
                                while k + 1 < raw.count { units.append(UInt16(raw[k]) | UInt16(raw[k + 1]) << 8); k += 2 }
                                name = String(decoding: units, as: UTF16.self)
                            } else {
                                name = String(decoding: raw, as: UTF8.self)
                            }
                        }
                    }
                    out.append(ThumbRef(formatID: mhii.u32(ni + 16), offset: Int(mhii.u32(ni + 20)),
                                        size: Int(mhii.u32(ni + 24)), fileName: name))
                }
            }
            o += tl
        }
        return out
    }

    // MARK: Mutation

    var nextImageID: UInt32 {
        let maxID = byImageID.keys.max() ?? 0
        return max(header.u32(28), maxID + 1, 100)
    }

    public mutating func removeImage(imageID: UInt32, songID: UInt64) {
        guard let si = imageSet else { return }
        var remove = Set<Int>()
        if imageID != 0, let i = byImageID[imageID] { remove.insert(i) }
        if songID != 0, let i = bySongID[songID] { remove.insert(i) }
        guard !remove.isEmpty else { return }
        sets[si].items = sets[si].items.enumerated().filter { !remove.contains($0.offset) }.map { $0.element }
        reindex()
    }

    /// Adds an image item and returns its id.
    public mutating func addImage(songID: UInt64, sourceSize: UInt32, thumbs: [ThumbRef]) -> UInt32 {
        guard let si = imageSet else { return 0 }
        let id = nextImageID
        sets[si].items.append(ArtworkDB.makeImage(id: id, songID: songID, sourceSize: sourceSize, thumbs: thumbs))
        header.setU32(28, id + 1)
        byImageID[id] = sets[si].items.count - 1
        if songID != 0 { bySongID[songID] = sets[si].items.count - 1 }
        return id
    }

    /// Makes sure the file list names every format we write.
    public mutating func ensureFiles(_ formats: [ArtworkFormat]) {
        guard let fi = fileSet else { return }
        let have = formatIDs
        for f in formats where !have.contains(f.id) {
            var h = Bytes(repeating: 0, count: 0x7C)
            h.setTag(0, "mhif")
            h.setU32(4, 0x7C)
            h.setU32(8, 0x7C)
            h.setU32(16, f.id)
            h.setU32(20, UInt32(f.byteSize))
            sets[fi].items.append(h)
        }
    }

    static func makeImage(id: UInt32, songID: UInt64, sourceSize: UInt32, thumbs: [ThumbRef]) -> Bytes {
        var children = Bytes()
        for t in thumbs {
            guard let f = ArtworkFormat.known(t.formatID) else { continue }
            // File name string (mhod type 3, UTF-16LE)
            var name = Bytes()
            for u in t.fileName.utf16 {
                name.append(UInt8(truncatingIfNeeded: u))
                name.append(UInt8(truncatingIfNeeded: u >> 8))
            }
            let pad = (4 - (36 + name.count) % 4) % 4
            var s = Bytes(repeating: 0, count: 36)
            s.setTag(0, "mhod")
            s.setU32(4, 24)
            s.setU32(8, UInt32(36 + name.count + pad))
            s.setU16(12, 3)
            s.setU8(15, UInt8(pad))
            s.setU32(24, UInt32(name.count))
            s.setU8(28, 2)
            s.append(contentsOf: name)
            s.appendZeros(pad)

            var ni = Bytes(repeating: 0, count: 0x4C)
            ni.setTag(0, "mhni")
            ni.setU32(4, 0x4C)
            ni.setU32(8, UInt32(0x4C + s.count))
            ni.setU32(12, 1)
            ni.setU32(16, t.formatID)
            ni.setU32(20, UInt32(t.offset))
            ni.setU32(24, UInt32(t.size))
            ni.setU16(28, 0)                       // vertical padding
            ni.setU16(30, 0)                       // horizontal padding
            ni.setU16(32, UInt16(f.height))
            ni.setU16(34, UInt16(f.width))
            ni.setU32(40, UInt32(t.size))

            var m = Bytes(repeating: 0, count: 24)
            m.setTag(0, "mhod")
            m.setU32(4, 24)
            m.setU32(8, UInt32(24 + ni.count + s.count))
            m.setU16(12, 2)
            children.append(contentsOf: m)
            children.append(contentsOf: ni)
            children.append(contentsOf: s)
        }
        var h = Bytes(repeating: 0, count: 0x98)
        h.setTag(0, "mhii")
        h.setU32(4, 0x98)
        h.setU32(8, UInt32(0x98 + children.count))
        h.setU32(12, UInt32(thumbs.filter { ArtworkFormat.known($0.formatID) != nil }.count))
        h.setU32(16, id)
        h.setU64(20, songID)
        h.setU32(48, sourceSize)
        return h + children
    }
}

// MARK: - Pixels

public enum ArtworkPixels {
    /// Scales an image (JPEG/PNG/…) to fit a width×height canvas and returns RGB565 LE pixels.
    public static func rgb565(from data: Data, width: Int, height: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height) * 2
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            guard iw > 0, ih > 0 else { return false }
            let scale = min(CGFloat(width) / iw, CGFloat(height) / ih)
            let w = iw * scale, h = ih * scale
            ctx.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return Data(pack565(rgba: rgba))
    }

    static func pack565(rgba: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: rgba.count / 2)
        var o = 0
        var i = 0
        while i + 3 < rgba.count {
            let r = UInt16(rgba[i]) >> 3, g = UInt16(rgba[i + 1]) >> 2, b = UInt16(rgba[i + 2]) >> 3
            let v = (r << 11) | (g << 5) | b
            out[o] = UInt8(truncatingIfNeeded: v)
            out[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
            o += 2
            i += 4
        }
        return out
    }

    static func unpack565(_ d: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: d.count * 2)
        var i = 0
        var o = 0
        while i + 1 < d.count {
            let v = UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
            let r = UInt8((v >> 11) & 0x1F), g = UInt8((v >> 5) & 0x3F), b = UInt8(v & 0x1F)
            out[o] = (r << 3) | (r >> 2)
            out[o + 1] = (g << 2) | (g >> 4)
            out[o + 2] = (b << 3) | (b >> 2)
            o += 4
            i += 2
        }
        return out
    }

    public static func image(rgb565 data: Data, width: Int, height: Int) -> CGImage? {
        guard data.count >= width * height * 2 else { return nil }
        let rgba = unpack565([UInt8](data.prefix(width * height * 2)))
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - On the device

extension IPodDevice {
    public var artworkURL: URL { controlURL.appendingPathComponent("Artwork", isDirectory: true) }
    public var artworkDBURL: URL { artworkURL.appendingPathComponent("ArtworkDB") }

    /// iPod Video model numbers (5G and 5.5G), used when there is no ArtworkDB to look at.
    public var looksLikeVideoModel: Bool {
        guard let m = sysInfo["ModelNumStr"]?.uppercased() else { return false }
        let known = ["A002", "A003", "A146", "A147", "A444", "A446", "A448", "A450", "A452", "A664"]
        return known.contains { m.hasSuffix($0) }
    }

    public func loadArtworkDB() -> ArtworkDB? {
        guard let data = try? Data(contentsOf: artworkDBURL) else { return nil }
        return try? ArtworkDB.parse(Bytes(data))
    }

    /// Reads the smallest stored thumbnail of a track straight from the .ithmb file.
    public func thumbnail(_ db: ArtworkDB, imageID: UInt32, songID: UInt64) -> CGImage? {
        let refs = db.thumbs(imageID: imageID, songID: songID)
            .compactMap { r in ArtworkFormat.known(r.formatID).map { (r, $0) } }
            .sorted { $0.1.byteSize < $1.1.byteSize }
        guard let (ref, format) = refs.first else { return nil }
        var name = ref.fileName
        while name.hasPrefix(":") { name.removeFirst() }
        guard !name.isEmpty, !name.contains(":"), !name.contains("/"),
              let h = try? FileHandle(forReadingFrom: artworkURL.appendingPathComponent(name)) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: UInt64(ref.offset))) != nil,
              let data = try? h.read(upToCount: format.byteSize), data.count == format.byteSize else { return nil }
        return ArtworkPixels.image(rgb565: data, width: format.width, height: format.height)
    }
}
