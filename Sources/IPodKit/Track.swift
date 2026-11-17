import Foundation

/// mhit record: fixed header with numeric fields followed by string mhods.
/// Offsets follow libgpod's itdb_itunesdb.c.
public struct Track: Sendable {
    public var header: Bytes
    public var mhods: [MHOD]

    public init(header: Bytes, mhods: [MHOD]) {
        self.header = header
        self.mhods = mhods
    }

    public static let defaultHeaderLength = 0x184

    // MARK: numeric fields

    public var uniqueID: UInt32 { get { header.u32(16) } set { header.setU32(16, newValue) } }
    public var fileTypeMarker: UInt32 { get { header.u32(24) } set { header.setU32(24, newValue) } }
    public var compilation: Bool { get { header.u8(30) != 0 } set { header.setU8(30, newValue ? 1 : 0) } }
    /// 0...100 in steps of 20.
    public var rating: UInt8 { get { header.u8(31) } set { header.setU8(31, newValue) } }
    public var timeModified: UInt32 { get { header.u32(32) } set { header.setU32(32, newValue) } }
    public var size: UInt32 { get { header.u32(36) } set { header.setU32(36, newValue) } }
    public var durationMs: UInt32 { get { header.u32(40) } set { header.setU32(40, newValue) } }
    public var trackNumber: UInt32 { get { header.u32(44) } set { header.setU32(44, newValue) } }
    public var trackCount: UInt32 { get { header.u32(48) } set { header.setU32(48, newValue) } }
    public var year: UInt32 { get { header.u32(52) } set { header.setU32(52, newValue) } }
    public var bitrate: UInt32 { get { header.u32(56) } set { header.setU32(56, newValue) } }
    public var sampleRate: UInt32 {
        get { header.u32(60) >> 16 }
        set { header.setU32(60, newValue << 16) }
    }
    /// 0 = no Sound Check value. gain(dB) = -10 * log10(value / 1000).
    public var soundCheck: UInt32 { get { header.u32(76) } set { header.setU32(76, newValue) } }
    public var playCount: UInt32 { get { header.u32(80) } set { header.setU32(80, newValue) } }
    public var playCount2: UInt32 { get { header.u32(84) } set { header.setU32(84, newValue) } }
    public var lastPlayed: UInt32 { get { header.u32(88) } set { header.setU32(88, newValue) } }
    public var discNumber: UInt32 { get { header.u32(92) } set { header.setU32(92, newValue) } }
    public var discCount: UInt32 { get { header.u32(96) } set { header.setU32(96, newValue) } }
    public var timeAdded: UInt32 { get { header.u32(104) } set { header.setU32(104, newValue) } }
    public var bookmarkTime: UInt32 { get { header.u32(108) } set { header.setU32(108, newValue) } }
    public var dbid: UInt64 { get { header.u64(112) } set { header.setU64(112, newValue) } }
    public var skipCount: UInt32 { get { header.u32(156) } set { header.setU32(156, newValue) } }
    public var lastSkipped: UInt32 { get { header.u32(160) } set { header.setU32(160, newValue) } }
    public var mediaType: UInt32 { get { header.u32(208) } set { header.setU32(208, newValue) } }

    // MARK: artwork link

    public var artworkCount: UInt16 { get { header.u16(124) } set { header.setU16(124, newValue) } }
    public var artworkSize: UInt32 { get { header.u32(128) } set { header.setU32(128, newValue) } }
    /// 1 = has artwork, 2 = none.
    public var hasArtworkFlag: UInt8 { get { header.u8(164) } set { header.setU8(164, newValue) } }
    /// Id of the image item (mhii) in ArtworkDB.
    public var mhiiLink: UInt32 {
        get { header.count >= 356 ? header.u32(352) : 0 }
        set {
            if header.count < Track.defaultHeaderLength { header.ensureSize(Track.defaultHeaderLength) }
            header.setU32(352, newValue)
        }
    }

    public mutating func setArtwork(imageID: UInt32, sourceSize: UInt32) {
        mhiiLink = imageID
        artworkCount = 1
        artworkSize = sourceSize
        hasArtworkFlag = 1
    }

    public mutating func clearArtwork() {
        mhiiLink = 0
        artworkCount = 0
        artworkSize = 0
        hasArtworkFlag = 2
    }

    // MARK: strings

    public func string(_ type: UInt32) -> String? {
        mhods.first { $0.type == type }?.string
    }

    public mutating func setString(_ type: UInt32, _ value: String?) {
        mhods.removeAll { $0.type == type }
        if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            mhods.append(MHOD.makeString(type: type, v))
        }
    }

    public enum Field: UInt32 {
        case title = 1, location = 2, album = 3, artist = 4, genre = 5, fileType = 6
        case comment = 8, composer = 12, albumArtist = 22
        case sortArtist = 23, sortTitle = 27, sortAlbum = 28, sortAlbumArtist = 29, sortComposer = 30
    }

    public var title: String { get { string(1) ?? "" } set { setString(1, newValue); setString(27, nil) } }
    public var location: String { get { string(2) ?? "" } set { setString(2, newValue) } }
    public var album: String { get { string(3) ?? "" } set { setString(3, newValue); setString(28, nil) } }
    public var artist: String { get { string(4) ?? "" } set { setString(4, newValue); setString(23, nil) } }
    public var genre: String { get { string(5) ?? "" } set { setString(5, newValue) } }
    public var fileTypeDescription: String { get { string(6) ?? "" } set { setString(6, newValue) } }
    public var composer: String { get { string(12) ?? "" } set { setString(12, newValue); setString(30, nil) } }
    public var albumArtist: String { get { string(22) ?? "" } set { setString(22, newValue); setString(29, nil) } }

    /// Location on the volume as a relative path, e.g. "iPod_Control/Music/F01/ABCD.mp3".
    public var relativePath: String {
        var p = location.replacingOccurrences(of: ":", with: "/")
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    public static func location(forRelativePath path: String) -> String {
        ":" + path.split(separator: "/").joined(separator: ":")
    }
}

// MARK: - Creating tracks

public enum AudioKind: Equatable, Hashable, Sendable {
    case mp3, aac, alac, wav, aiff
    case unsupported(String)

    public var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }

    public var label: String {
        switch self {
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .alac: return "ALAC"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .unsupported(let s): return s.uppercased()
        }
    }

    var marker: UInt32 {
        func m(_ s: String) -> UInt32 {
            let b = Array(s.utf8)
            return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        }
        switch self {
        case .mp3: return m("MP3 ")
        case .aac, .alac: return m("M4A ")
        case .wav: return m("WAV ")
        case .aiff: return m("AIFF")
        case .unsupported: return 0
        }
    }

    var typeDescription: String {
        switch self {
        case .mp3: return "MPEG audio file"
        case .aac: return "AAC audio file"
        case .alac: return "Apple Lossless audio file"
        case .wav: return "WAV audio file"
        case .aiff: return "AIFF audio file"
        case .unsupported: return ""
        }
    }

    public var fileExtension: String {
        switch self {
        case .mp3: return "mp3"
        case .aac, .alac: return "m4a"
        case .wav: return "wav"
        case .aiff: return "aif"
        case .unsupported(let s): return s.lowercased()
        }
    }
}

public struct AudioMeta: Equatable, Hashable, Sendable {
    public var title = ""
    public var artist = ""
    public var album = ""
    public var albumArtist = ""
    public var genre = ""
    public var composer = ""
    public var year = 0
    public var trackNumber = 0
    public var trackCount = 0
    public var discNumber = 0
    public var discCount = 0
    public var compilation = false
    public var durationMs = 0
    public var sampleRate = 44100
    public var bitrateKbps = 0
    public var fileSize: Int64 = 0
    public var sampleCount: Int64 = 0
    public var kind: AudioKind = .unsupported("")

    public init() {}
}

extension Track {
    public static func make(meta: AudioMeta, uniqueID: UInt32, relativePath: String, fileSize: UInt32) -> Track {
        var h = Bytes(repeating: 0, count: defaultHeaderLength)
        h.setTag(0, "mhit")
        h.setU32(4, UInt32(defaultHeaderLength))
        var t = Track(header: h, mhods: [])
        let now = MacTime.now()
        let dbid = UInt64.random(in: 1...UInt64.max)
        t.uniqueID = uniqueID
        t.header.setU32(20, 1)                      // visible
        t.fileTypeMarker = meta.kind.marker
        if meta.kind == .mp3 {
            t.header.setU8(28, 0)
            t.header.setU8(29, 1)
        }
        t.compilation = meta.compilation
        t.timeModified = now
        t.size = fileSize
        t.durationMs = UInt32(clamping: meta.durationMs)
        t.trackNumber = UInt32(clamping: meta.trackNumber)
        t.trackCount = UInt32(clamping: meta.trackCount)
        t.year = UInt32(clamping: meta.year)
        t.bitrate = UInt32(clamping: meta.bitrateKbps)
        t.sampleRate = UInt32(clamping: meta.sampleRate)
        t.discNumber = UInt32(clamping: meta.discNumber)
        t.discCount = UInt32(clamping: meta.discCount)
        t.timeAdded = now
        t.dbid = dbid
        switch meta.kind {
        case .mp3, .aac, .alac: t.header.setU16(126, 0xFFFF)
        default: t.header.setU16(126, 0)
        }
        t.header.setF32(136, Float(meta.sampleRate))
        switch meta.kind {
        case .mp3: t.header.setU16(144, 0x000C)
        case .aac, .alac: t.header.setU16(144, 0x0033)
        default: break
        }
        t.header.setU8(164, 2)                      // no artwork
        t.header.setU64(168, dbid)                  // dbid2
        t.header.setU64(188, UInt64(clamping: meta.sampleCount))
        t.mediaType = 1                             // audio

        let fallbackTitle = (relativePath as NSString).lastPathComponent
        t.setString(1, meta.title.isEmpty ? fallbackTitle : meta.title)
        t.setString(2, location(forRelativePath: relativePath))
        t.setString(3, meta.album)
        t.setString(4, meta.artist)
        t.setString(5, meta.genre)
        t.setString(6, meta.kind.typeDescription)
        t.setString(12, meta.composer)
        t.setString(22, meta.albumArtist)
        return t
    }
}

// MARK: - Edits

/// A batch tag edit. nil = leave unchanged, "" or 0 = clear.
public struct TrackEdit: Equatable, Hashable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var composer: String?
    public var year: Int?
    public var trackNumber: Int?
    public var trackCount: Int?
    public var discNumber: Int?
    public var discCount: Int?
    public var compilation: Bool?
    public var soundCheck: UInt32?

    public init() {}

    public var isEmpty: Bool { self == TrackEdit() }

    /// Values from `other` win.
    public func merged(with other: TrackEdit) -> TrackEdit {
        var r = self
        if let v = other.title { r.title = v }
        if let v = other.artist { r.artist = v }
        if let v = other.album { r.album = v }
        if let v = other.albumArtist { r.albumArtist = v }
        if let v = other.genre { r.genre = v }
        if let v = other.composer { r.composer = v }
        if let v = other.year { r.year = v }
        if let v = other.trackNumber { r.trackNumber = v }
        if let v = other.trackCount { r.trackCount = v }
        if let v = other.discNumber { r.discNumber = v }
        if let v = other.discCount { r.discCount = v }
        if let v = other.compilation { r.compilation = v }
        if let v = other.soundCheck { r.soundCheck = v }
        return r
    }

    public func apply(to t: inout Track) {
        if let v = title { t.title = v }
        if let v = artist { t.artist = v }
        if let v = album { t.album = v }
        if let v = albumArtist { t.albumArtist = v }
        if let v = genre { t.genre = v }
        if let v = composer { t.composer = v }
        if let v = year { t.year = UInt32(clamping: v) }
        if let v = trackNumber { t.trackNumber = UInt32(clamping: v) }
        if let v = trackCount { t.trackCount = UInt32(clamping: v) }
        if let v = discNumber { t.discNumber = UInt32(clamping: v) }
        if let v = discCount { t.discCount = UInt32(clamping: v) }
        if let v = compilation { t.compilation = v }
        if let v = soundCheck { t.soundCheck = v }
        if !(self == TrackEdit()) { t.timeModified = MacTime.now() }
    }

    public func apply(to m: inout AudioMeta) {
        if let v = title { m.title = v }
        if let v = artist { m.artist = v }
        if let v = album { m.album = v }
        if let v = albumArtist { m.albumArtist = v }
        if let v = genre { m.genre = v }
        if let v = composer { m.composer = v }
        if let v = year { m.year = v }
        if let v = trackNumber { m.trackNumber = v }
        if let v = trackCount { m.trackCount = v }
        if let v = discNumber { m.discNumber = v }
        if let v = discCount { m.discCount = v }
        if let v = compilation { m.compilation = v }
    }
}
