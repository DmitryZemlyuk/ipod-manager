import Foundation

/// A mounted iPod (5th gen / iPod Video and other iTunesDB-based models without DB hashing).
public struct IPodDevice: Identifiable, Hashable, Sendable {
    public let mountURL: URL
    public let volumeName: String

    public var id: String { mountURL.path }

    public init(mountURL: URL, volumeName: String) {
        self.mountURL = mountURL
        self.volumeName = volumeName
    }

    public var controlURL: URL { mountURL.appendingPathComponent("iPod_Control", isDirectory: true) }
    public var iTunesURL: URL { controlURL.appendingPathComponent("iTunes", isDirectory: true) }
    public var musicURL: URL { controlURL.appendingPathComponent("Music", isDirectory: true) }
    public var databaseURL: URL { iTunesURL.appendingPathComponent("iTunesDB") }
    public var playCountsURL: URL { iTunesURL.appendingPathComponent("Play Counts") }

    public func fileURL(forRelativePath path: String) -> URL {
        mountURL.appendingPathComponent(path)
    }

    public func fileURL(for track: Track) -> URL {
        fileURL(forRelativePath: track.relativePath)
    }

    /// Lines of iPod_Control/Device/SysInfo, e.g. "ModelNumStr: xA450".
    public var sysInfo: [String: String] {
        let url = controlURL.appendingPathComponent("Device/SysInfo")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var r = [String: String]()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { r[parts[0]] = parts[1] }
        }
        return r
    }

    public struct Capacity: Equatable, Sendable {
        public var total: Int64
        public var available: Int64
    }

    public var capacity: Capacity? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let v = try? mountURL.resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let avail = v.volumeAvailableCapacity else { return nil }
        return Capacity(total: Int64(total), available: Int64(avail))
    }

    /// True when the iPod uses a compressed/hashed database we can't write safely.
    public var hasUnsupportedDatabase: Bool {
        FileManager.default.fileExists(atPath: iTunesURL.appendingPathComponent("iTunesCDB").path)
    }

    public static func detectAll() -> [IPodDevice] {
        let fm = FileManager.default
        let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                        options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            var isDir: ObjCBool = false
            let control = url.appendingPathComponent("iPod_Control").path
            guard fm.fileExists(atPath: control, isDirectory: &isDir), isDir.boolValue else { return nil }
            let values = try? url.resourceValues(forKeys: [.volumeNameKey])
            let name: String = values?.volumeName ?? url.lastPathComponent
            return IPodDevice(mountURL: url, volumeName: name)
        }
    }
}

// MARK: - Play Counts

/// "Play Counts" (mhdp): plays/ratings made on the iPod since the last sync,
/// indexed by track position in the database. Must be merged before the DB changes.
enum PlayCounts {
    struct Entry {
        var playCount: UInt32
        var lastPlayed: UInt32
        var bookmark: UInt32
        var rating: UInt32?
        var skipCount: UInt32?
        var lastSkipped: UInt32?
    }

    static func parse(_ d: Bytes) -> [Entry]? {
        guard d.tag(0) == "mhdp" else { return nil }
        let hl = Int(d.u32(4))
        let entryLen = Int(d.u32(8))
        let n = Int(d.u32(12))
        guard entryLen >= 12, hl + entryLen * n <= d.count else { return nil }
        var out = [Entry]()
        out.reserveCapacity(n)
        for i in 0..<n {
            let o = hl + i * entryLen
            out.append(Entry(
                playCount: d.u32(o),
                lastPlayed: d.u32(o + 4),
                bookmark: d.u32(o + 8),
                rating: entryLen >= 16 ? d.u32(o + 12) : nil,
                skipCount: entryLen >= 0x1C ? d.u32(o + 20) : nil,
                lastSkipped: entryLen >= 0x1C ? d.u32(o + 24) : nil
            ))
        }
        return out
    }

    static func merge(_ entries: [Entry], into tracks: inout [Track]) {
        guard entries.count == tracks.count else { return }
        for i in tracks.indices {
            let e = entries[i]
            if e.playCount > 0 {
                tracks[i].playCount &+= e.playCount
                tracks[i].playCount2 &+= e.playCount
            }
            if e.lastPlayed > tracks[i].lastPlayed { tracks[i].lastPlayed = e.lastPlayed }
            if e.bookmark != 0 { tracks[i].bookmarkTime = e.bookmark }
            if let r = e.rating, r <= 100 { tracks[i].rating = UInt8(r) }
            if let s = e.skipCount, s > 0 { tracks[i].skipCount &+= s }
            if let ls = e.lastSkipped, ls > tracks[i].lastSkipped { tracks[i].lastSkipped = ls }
        }
    }
}
