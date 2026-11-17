import Foundation

public enum ITunesDBError: Error, LocalizedError {
    case badMagic(expected: String, offset: Int)
    case truncated(offset: Int)
    case noTrackList

    public var errorDescription: String? {
        switch self {
        case .badMagic(let e, let o): return "iTunesDB: expected '\(e)' at offset \(o)"
        case .truncated(let o): return "iTunesDB: unexpected end of data at offset \(o)"
        case .noTrackList: return "iTunesDB: track list not found"
        }
    }
}

// MARK: - Data objects (mhod)

public struct MHOD: Equatable, Sendable {
    public var raw: Bytes

    public init(raw: Bytes) { self.raw = raw }

    public var type: UInt32 { raw.u32(12) }

    /// mhod types that carry a UTF-16 string with the 16-byte string sub-header.
    public static func isStringType(_ t: UInt32) -> Bool {
        (UInt32(1)...UInt32(14)).contains(t) || (UInt32(18)...UInt32(31)).contains(t)
    }

    public var string: String? {
        guard MHOD.isStringType(type), raw.count >= 40 else { return nil }
        let len = Int(raw.u32(28))
        let encoding = raw.u32(32)
        guard len >= 0, 40 + len <= raw.count else { return nil }
        let slice = Array(raw[40..<(40 + len)])
        if encoding == 2 {
            return String(decoding: slice, as: UTF8.self)
        }
        var units = [UInt16]()
        units.reserveCapacity(len / 2)
        var i = 0
        while i + 1 < slice.count {
            units.append(UInt16(slice[i]) | (UInt16(slice[i + 1]) << 8))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    public static func makeString(type: UInt32, _ s: String) -> MHOD {
        var body = Bytes()
        for u in s.utf16 {
            body.append(UInt8(truncatingIfNeeded: u))
            body.append(UInt8(truncatingIfNeeded: u >> 8))
        }
        var r = Bytes()
        r.appendTag("mhod")
        r.appendU32(24)
        r.appendU32(UInt32(40 + body.count))
        r.appendU32(type)
        r.appendU32(0)
        r.appendU32(0)
        r.appendU32(1)                    // position
        r.appendU32(UInt32(body.count))   // length in bytes
        r.appendU32(1)                    // 1 = UTF-16
        r.appendU32(0)
        r.append(contentsOf: body)
        return MHOD(raw: r)
    }

    /// mhod type 100 attached to playlist items: the item position.
    public static func makePosition(_ position: UInt32) -> MHOD {
        var r = Bytes()
        r.appendTag("mhod")
        r.appendU32(24)
        r.appendU32(44)
        r.appendU32(100)
        r.appendU32(0)
        r.appendU32(0)
        r.appendU32(position)
        r.appendZeros(16)
        return MHOD(raw: r)
    }
}

// MARK: - Model

public struct ITunesDB: Sendable {
    public var header: Bytes
    public var datasets: [DataSet]

    public init(header: Bytes, datasets: [DataSet]) {
        self.header = header
        self.datasets = datasets
    }
}

public struct DataSet: Sendable {
    public var header: Bytes
    public var trackList: TrackList?
    public var playlistList: PlaylistList?
    /// Body bytes kept verbatim for datasets we don't interpret (album lists etc.).
    public var rawBody: Bytes

    public var type: UInt32 { header.u32(12) }
}

public struct TrackList: Sendable {
    public var header: Bytes
    public var tracks: [Track]
}

public struct PlaylistList: Sendable {
    public var header: Bytes
    public var playlists: [Playlist]
}

public struct Playlist: Sendable {
    public var header: Bytes
    public var mhods: [MHOD]
    public var items: [PlaylistItem]

    public var isMaster: Bool { header.u8(20) == 1 }
    public var name: String? { mhods.first { $0.type == 1 }?.string }
}

public struct PlaylistItem: Sendable {
    public var header: Bytes
    public var mhods: [MHOD]

    public var trackID: UInt32 {
        get { header.u32(24) }
        set { header.setU32(24, newValue) }
    }
    public var groupID: UInt32 { header.u32(20) }

    public static func make(trackID: UInt32, position: UInt32, groupID: UInt32, timestamp: UInt32) -> PlaylistItem {
        var h = Bytes(repeating: 0, count: 0x4C)
        h.setTag(0, "mhip")
        h.setU32(4, 0x4C)
        h.setU32(20, groupID)
        h.setU32(24, trackID)
        h.setU32(28, timestamp)
        return PlaylistItem(header: h, mhods: [MHOD.makePosition(position)])
    }
}

// MARK: - Parsing

extension ITunesDB {
    public static func parse(_ d: Bytes) throws -> ITunesDB {
        try expect(d, "mhbd", 0)
        let hl = Int(d.u32(4))
        let tl = Int(d.u32(8))
        let n = Int(d.u32(20))
        guard hl >= 24, hl <= d.count else { throw ITunesDBError.truncated(offset: 0) }
        let end = min(tl > 0 ? tl : d.count, d.count)
        var db = ITunesDB(header: Array(d[0..<hl]), datasets: [])
        var o = hl
        for _ in 0..<n {
            guard o + 12 <= end else { break }
            let (ds, len) = try parseDataSet(d, at: o)
            db.datasets.append(ds)
            o += len
        }
        return db
    }

    static func expect(_ d: Bytes, _ tag: String, _ o: Int) throws {
        guard d.tag(o) == tag else { throw ITunesDBError.badMagic(expected: tag, offset: o) }
    }

    static func parseDataSet(_ d: Bytes, at o: Int) throws -> (DataSet, Int) {
        try expect(d, "mhsd", o)
        let hl = Int(d.u32(o + 4))
        let tl = Int(d.u32(o + 8))
        guard hl >= 16, tl >= hl, o + tl <= d.count else { throw ITunesDBError.truncated(offset: o) }
        let bodyStart = o + hl
        let end = o + tl
        var ds = DataSet(header: Array(d[o..<bodyStart]), trackList: nil, playlistList: nil,
                         rawBody: Array(d[bodyStart..<end]))
        switch d.tag(bodyStart) {
        case "mhlt":
            ds.trackList = try parseTrackList(d, at: bodyStart, end: end)
            ds.rawBody = []
        case "mhlp":
            ds.playlistList = try parsePlaylistList(d, at: bodyStart, end: end)
            ds.rawBody = []
        default:
            break
        }
        return (ds, tl)
    }

    static func parseTrackList(_ d: Bytes, at o: Int, end: Int) throws -> TrackList {
        let hl = Int(d.u32(o + 4))
        let n = Int(d.u32(o + 8))
        guard hl >= 12, o + hl <= end else { throw ITunesDBError.truncated(offset: o) }
        var list = TrackList(header: Array(d[o..<(o + hl)]), tracks: [])
        list.tracks.reserveCapacity(n)
        var p = o + hl
        for _ in 0..<n {
            let (t, len) = try parseTrack(d, at: p, end: end)
            list.tracks.append(t)
            p += len
        }
        return list
    }

    static func parseTrack(_ d: Bytes, at o: Int, end: Int) throws -> (Track, Int) {
        try expect(d, "mhit", o)
        let hl = Int(d.u32(o + 4))
        let tl = Int(d.u32(o + 8))
        let nm = Int(d.u32(o + 12))
        guard hl >= 16, o + hl <= end else { throw ITunesDBError.truncated(offset: o) }
        var t = Track(header: Array(d[o..<(o + hl)]), mhods: [])
        var p = o + hl
        for _ in 0..<nm {
            let m = try parseMHOD(d, at: p, end: end)
            t.mhods.append(m)
            p += m.raw.count
        }
        return (t, max(tl, p - o))
    }

    static func parseMHOD(_ d: Bytes, at o: Int, end: Int) throws -> MHOD {
        try expect(d, "mhod", o)
        let tl = Int(d.u32(o + 8))
        guard tl >= 24, o + tl <= end else { throw ITunesDBError.truncated(offset: o) }
        return MHOD(raw: Array(d[o..<(o + tl)]))
    }

    static func parsePlaylistList(_ d: Bytes, at o: Int, end: Int) throws -> PlaylistList {
        let hl = Int(d.u32(o + 4))
        let n = Int(d.u32(o + 8))
        guard hl >= 12, o + hl <= end else { throw ITunesDBError.truncated(offset: o) }
        var list = PlaylistList(header: Array(d[o..<(o + hl)]), playlists: [])
        var p = o + hl
        for _ in 0..<n {
            let (pl, len) = try parsePlaylist(d, at: p, end: end)
            list.playlists.append(pl)
            p += len
        }
        return list
    }

    static func parsePlaylist(_ d: Bytes, at o: Int, end: Int) throws -> (Playlist, Int) {
        try expect(d, "mhyp", o)
        let hl = Int(d.u32(o + 4))
        let tl = Int(d.u32(o + 8))
        let nm = Int(d.u32(o + 12))
        let ni = Int(d.u32(o + 16))
        guard hl >= 20, o + hl <= end else { throw ITunesDBError.truncated(offset: o) }
        var pl = Playlist(header: Array(d[o..<(o + hl)]), mhods: [], items: [])
        var p = o + hl
        for _ in 0..<nm {
            let m = try parseMHOD(d, at: p, end: end)
            pl.mhods.append(m)
            p += m.raw.count
        }
        for _ in 0..<ni {
            let (item, len) = try parseItem(d, at: p, end: end)
            pl.items.append(item)
            p += len
        }
        return (pl, max(tl, p - o))
    }

    static func parseItem(_ d: Bytes, at o: Int, end: Int) throws -> (PlaylistItem, Int) {
        try expect(d, "mhip", o)
        let hl = Int(d.u32(o + 4))
        let tl = Int(d.u32(o + 8))
        let nm = Int(d.u32(o + 12))
        guard hl >= 28, o + hl <= end else { throw ITunesDBError.truncated(offset: o) }
        var item = PlaylistItem(header: Array(d[o..<(o + hl)]), mhods: [])
        var p = o + hl
        for _ in 0..<nm {
            let m = try parseMHOD(d, at: p, end: end)
            item.mhods.append(m)
            p += m.raw.count
        }
        return (item, max(tl, p - o))
    }
}

// MARK: - Serialization

extension ITunesDB {
    public func serialize() -> Bytes {
        var body = Bytes()
        for ds in datasets { body.append(contentsOf: ds.serialize()) }
        var h = header
        h.setU32(4, UInt32(h.count))
        h.setU32(8, UInt32(h.count + body.count))
        h.setU32(20, UInt32(datasets.count))
        return h + body
    }
}

extension DataSet {
    func serialize() -> Bytes {
        let body: Bytes
        if let tl = trackList {
            body = tl.serialize()
        } else if let pl = playlistList {
            body = pl.serialize()
        } else {
            body = rawBody
        }
        var h = header
        h.setU32(4, UInt32(h.count))
        h.setU32(8, UInt32(h.count + body.count))
        return h + body
    }
}

extension TrackList {
    func serialize() -> Bytes {
        var h = header
        h.setU32(4, UInt32(h.count))
        h.setU32(8, UInt32(tracks.count))
        var out = h
        for t in tracks { out.append(contentsOf: t.serialize()) }
        return out
    }
}

extension Track {
    func serialize() -> Bytes {
        var body = Bytes()
        for m in mhods { body.append(contentsOf: m.raw) }
        var h = header
        h.setU32(4, UInt32(h.count))
        h.setU32(8, UInt32(h.count + body.count))
        h.setU32(12, UInt32(mhods.count))
        return h + body
    }
}

extension PlaylistList {
    func serialize() -> Bytes {
        var h = header
        h.setU32(4, UInt32(h.count))
        h.setU32(8, UInt32(playlists.count))
        var out = h
        for p in playlists { out.append(contentsOf: p.serialize()) }
        return out
    }
}

extension Playlist {
    func serialize() -> Bytes {
        var body = Bytes()
        for m in mhods { body.append(contentsOf: m.raw) }
        for i in items { body.append(contentsOf: i.serialize()) }
        var h = header
        h.setU32(4, UInt32(h.count))
        h.setU32(8, UInt32(h.count + body.count))
        h.setU32(12, UInt32(mhods.count))
        h.setU32(16, UInt32(items.count))
        return h + body
    }
}

extension PlaylistItem {
    func serialize() -> Bytes {
        var body = Bytes()
        for m in mhods { body.append(contentsOf: m.raw) }
        var h = header
        h.setU32(4, UInt32(h.count))
        h.setU32(8, UInt32(h.count + body.count))
        h.setU32(12, UInt32(mhods.count))
        return h + body
    }
}

// MARK: - High level operations

extension ITunesDB {
    public static func makeEmpty(name: String) -> ITunesDB {
        var h = Bytes(repeating: 0, count: 0xBC)
        h.setTag(0, "mhbd")
        h.setU32(12, 1)
        h.setU32(16, 0x13)
        h.setU64(24, UInt64.random(in: 1...UInt64.max))
        h.setU16(32, 2)
        h.setU8(0x46, UInt8(ascii: "e"))
        h.setU8(0x47, UInt8(ascii: "n"))

        func dataSet(_ type: UInt32) -> Bytes {
            var dh = Bytes(repeating: 0, count: 0x60)
            dh.setTag(0, "mhsd")
            dh.setU32(12, type)
            return dh
        }
        func listHeader(_ tag: String) -> Bytes {
            var lh = Bytes(repeating: 0, count: 0x5C)
            lh.setTag(0, tag)
            return lh
        }
        func master() -> Playlist {
            var ph = Bytes(repeating: 0, count: 0x6C)
            ph.setTag(0, "mhyp")
            ph.setU8(20, 1)
            ph.setU32(24, MacTime.now())
            ph.setU64(28, UInt64.random(in: 1...UInt64.max))
            ph.setU16(40, 1)
            return Playlist(header: ph, mhods: [MHOD.makeString(type: 1, name)], items: [])
        }

        let tracks = DataSet(header: dataSet(1), trackList: TrackList(header: listHeader("mhlt"), tracks: []),
                             playlistList: nil, rawBody: [])
        let podcasts = DataSet(header: dataSet(3), trackList: nil,
                               playlistList: PlaylistList(header: listHeader("mhlp"), playlists: [master()]), rawBody: [])
        let playlists = DataSet(header: dataSet(2), trackList: nil,
                                playlistList: PlaylistList(header: listHeader("mhlp"), playlists: [master()]), rawBody: [])
        return ITunesDB(header: h, datasets: [tracks, podcasts, playlists])
    }

    var trackListIndex: Int? { datasets.firstIndex { $0.trackList != nil } }

    public var tracks: [Track] {
        get { trackListIndex.flatMap { datasets[$0].trackList?.tracks } ?? [] }
        set {
            guard let i = trackListIndex else { return }
            datasets[i].trackList?.tracks = newValue
        }
    }

    public var nextTrackID: UInt32 {
        (tracks.map { $0.uniqueID }.max() ?? 0) + 1
    }

    public mutating func removeTracks(ids: Set<UInt32>) {
        guard !ids.isEmpty else { return }
        tracks.removeAll { ids.contains($0.uniqueID) }
        for di in datasets.indices {
            guard datasets[di].playlistList != nil else { continue }
            for pi in datasets[di].playlistList!.playlists.indices {
                datasets[di].playlistList!.playlists[pi].items.removeAll { ids.contains($0.trackID) }
            }
        }
    }

    /// Rebuilds every master playlist (one per playlist dataset): all tracks in
    /// track-list order plus fresh library index mhods (types 52/53).
    public mutating func rebuildMasterPlaylists() {
        let all = tracks
        var maxGroup: UInt32 = 0
        for ds in datasets {
            for pl in ds.playlistList?.playlists ?? [] {
                for item in pl.items { maxGroup = Swift.max(maxGroup, item.groupID) }
            }
        }
        maxGroup = Swift.max(maxGroup, all.map { $0.uniqueID }.max() ?? 0)
        let index = LibraryIndex.makeMHODs(all)
        let now = MacTime.now()

        for di in datasets.indices {
            guard var list = datasets[di].playlistList else { continue }
            var masterIdx = list.playlists.firstIndex { $0.isMaster }
            if masterIdx == nil {
                var ph = Bytes(repeating: 0, count: 0x6C)
                ph.setTag(0, "mhyp")
                ph.setU8(20, 1)
                ph.setU32(24, now)
                ph.setU64(28, UInt64.random(in: 1...UInt64.max))
                ph.setU16(40, 1)
                list.playlists.insert(Playlist(header: ph, mhods: [MHOD.makeString(type: 1, "iPod")], items: []), at: 0)
                masterIdx = 0
            }
            let mi = masterIdx!
            var master = list.playlists[mi]
            master.mhods = master.mhods.filter { $0.type != 52 && $0.type != 53 } + index
            var group = maxGroup
            master.items = all.enumerated().map { (i, t) -> PlaylistItem in
                group += 1
                return PlaylistItem.make(trackID: t.uniqueID, position: UInt32(i), groupID: group, timestamp: now)
            }
            list.playlists[mi] = master
            datasets[di].playlistList = list
        }
    }
}
