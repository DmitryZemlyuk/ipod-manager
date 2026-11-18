import Foundation

/// Tag changes to write into an audio file. nil = leave the field alone.
public struct TagWrite: Sendable, Equatable {
    public struct Pair: Sendable, Equatable {
        public var number: Int
        public var total: Int

        public init(number: Int, total: Int) {
            self.number = max(number, 0)
            self.total = max(total, 0)
        }

        var isEmpty: Bool { number == 0 && total == 0 }
        var text: String { total > 0 ? "\(number)/\(total)" : "\(number)" }
    }

    /// "" removes the field.
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var composer: String?
    /// 0 removes the field.
    public var year: Int?
    public var track: Pair?
    public var disc: Pair?
    public var compilation: Bool?
    public var artwork: ArtworkChange?

    public init() {}

    public var isEmpty: Bool { self == TagWrite() }

    /// The fields a tag edit touches. Track and disc numbers are written as pairs,
    /// so the complete values after the edit are passed in.
    public init(edit: TrackEdit, track: Pair, disc: Pair) {
        title = edit.title
        artist = edit.artist
        album = edit.album
        albumArtist = edit.albumArtist
        genre = edit.genre
        composer = edit.composer
        year = edit.year
        if edit.trackNumber != nil || edit.trackCount != nil { self.track = track }
        if edit.discNumber != nil || edit.discCount != nil { self.disc = disc }
        compilation = edit.compilation
    }

    public init(edit: TrackEdit, result t: Track) {
        self.init(edit: edit,
                  track: Pair(number: Int(t.trackNumber), total: Int(t.trackCount)),
                  disc: Pair(number: Int(t.discNumber), total: Int(t.discCount)))
    }

    /// Everything the iPod database knows about a track (empty values are not written).
    public init(allOf t: Track) {
        func s(_ v: String) -> String? { v.isEmpty ? nil : v }
        title = s(t.title)
        artist = s(t.artist)
        album = s(t.album)
        albumArtist = s(t.albumArtist)
        genre = s(t.genre)
        composer = s(t.composer)
        year = t.year > 0 ? Int(t.year) : nil
        if t.trackNumber > 0 { track = Pair(number: Int(t.trackNumber), total: Int(t.trackCount)) }
        if t.discNumber > 0 { disc = Pair(number: Int(t.discNumber), total: Int(t.discCount)) }
        if t.compilation { compilation = true }
    }

    /// Values from `other` win.
    public func merged(with o: TagWrite) -> TagWrite {
        var r = self
        if let v = o.title { r.title = v }
        if let v = o.artist { r.artist = v }
        if let v = o.album { r.album = v }
        if let v = o.albumArtist { r.albumArtist = v }
        if let v = o.genre { r.genre = v }
        if let v = o.composer { r.composer = v }
        if let v = o.year { r.year = v }
        if let v = o.track { r.track = v }
        if let v = o.disc { r.disc = v }
        if let v = o.compilation { r.compilation = v }
        if let v = o.artwork { r.artwork = v }
        return r
    }
}

public enum FileTagsError: Error, LocalizedError {
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "Can't write tags: \(s)"
        }
    }
}

public enum FileTags {
    public enum Outcome: Sendable, Equatable {
        /// File changed; new size in bytes.
        case written(size: Int)
        /// The file already had these tags.
        case unchanged
        /// Not a format we write tags into (WAV, AIFF, …).
        case notApplicable
    }

    static let maxFileSize = 300 * 1024 * 1024

    public static func canWrite(_ url: URL) -> Bool {
        ["mp3", "m4a", "m4b", "mp4"].contains(url.pathExtension.lowercased())
    }

    /// Writes tag changes into an MP3 or M4A file. Audio data is never touched.
    public static func write(_ w: TagWrite, to url: URL) throws -> Outcome {
        guard !w.isEmpty else { return .unchanged }
        let ext = url.pathExtension.lowercased()
        guard canWrite(url) else { return .notApplicable }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size > maxFileSize { throw FileTagsError.unsupported("file is too large") }
        let data = Bytes(try Data(contentsOf: url))
        let plan: Plan?
        if ext == "mp3" {
            plan = try ID3v2.plan(w, file: data)
        } else {
            plan = try MP4Tags.plan(w, file: data)
        }
        guard let plan else { return .unchanged }
        switch plan {
        case .patch(let offset, let bytes):
            let h = try FileHandle(forUpdating: url)
            defer { try? h.close() }
            try h.seek(toOffset: UInt64(offset))
            try h.write(contentsOf: Data(bytes))
            try? h.synchronize()
            return .written(size: size)
        case .rewrite(let bytes):
            try replace(url, with: bytes)
            return .written(size: bytes.count)
        }
    }

    enum Plan {
        /// Overwrite a region; the file keeps its size.
        case patch(offset: Int, bytes: Bytes)
        /// New file contents.
        case rewrite(Bytes)
    }

    /// Applies a plan in memory (for tests and previews).
    static func apply(_ plan: Plan, to file: Bytes) -> Bytes {
        switch plan {
        case .patch(let offset, let bytes):
            var out = file
            out.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            return out
        case .rewrite(let bytes):
            return bytes
        }
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

    static func imageMIME(_ d: Data) -> String {
        let b = [UInt8](d.prefix(4))
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        return "image/jpeg"
    }
}
