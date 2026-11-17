import Foundation

public enum IPodSessionError: Error, LocalizedError {
    case unsupportedDatabase
    case noSpace(needed: Int64, available: Int64)
    case copyFailed(String, Error)

    public var errorDescription: String? {
        switch self {
        case .unsupportedDatabase:
            return "This iPod uses a compressed database (iTunesCDB) that is not supported."
        case .noSpace(let n, let a):
            let f = ByteCountFormatter()
            return "Not enough space on the iPod: need \(f.string(fromByteCount: n)), available \(f.string(fromByteCount: a))."
        case .copyFailed(let name, let e):
            return "Could not copy \(name): \(e.localizedDescription)"
        }
    }
}

public struct NewTrack: Sendable {
    public var sourceURL: URL
    public var meta: AudioMeta

    public init(sourceURL: URL, meta: AudioMeta) {
        self.sourceURL = sourceURL
        self.meta = meta
    }
}

public enum CommitPhase: Equatable, Sendable {
    case copying(done: Int, total: Int, name: String)
    case writingDatabase
    case removingFiles
    case finished
}

/// Loads an iPod's database and applies batches of changes to it.
public final class IPodSession: @unchecked Sendable {
    public let device: IPodDevice
    public private(set) var db: ITunesDB
    /// Play Counts were merged into `db` in memory; the file is removed after the next write.
    private var mergedPlayCounts = false
    public private(set) var databaseExisted: Bool

    public init(device: IPodDevice) throws {
        if device.hasUnsupportedDatabase { throw IPodSessionError.unsupportedDatabase }
        self.device = device
        let fm = FileManager.default
        if fm.fileExists(atPath: device.databaseURL.path) {
            let data = try Data(contentsOf: device.databaseURL)
            var db = try ITunesDB.parse(Bytes(data))
            if let pc = try? Data(contentsOf: device.playCountsURL), let entries = PlayCounts.parse(Bytes(pc)) {
                var tracks = db.tracks
                if entries.count == tracks.count {
                    PlayCounts.merge(entries, into: &tracks)
                    db.tracks = tracks
                    mergedPlayCounts = true
                }
            }
            self.db = db
            databaseExisted = true
        } else {
            self.db = ITunesDB.makeEmpty(name: device.volumeName)
            databaseExisted = false
        }
    }

    public var tracks: [Track] { db.tracks }

    // MARK: Commit

    public func commit(adds: [NewTrack],
                       deletes: Set<UInt32>,
                       edits: [UInt32: TrackEdit],
                       progress: (CommitPhase) -> Void) throws {
        let fm = FileManager.default
        var newDB = db

        // 1. Space check.
        let needed = adds.reduce(Int64(0)) { $0 + max($1.meta.fileSize, 0) }
        if let cap = device.capacity, needed > 0 {
            let freed = newDB.tracks.filter { deletes.contains($0.uniqueID) }.reduce(Int64(0)) { $0 + Int64($1.size) }
            let available = cap.available + freed - 8 * 1024 * 1024
            if needed > available { throw IPodSessionError.noSpace(needed: needed, available: max(available, 0)) }
        }

        // 2. Tag edits.
        if !edits.isEmpty {
            var tracks = newDB.tracks
            for i in tracks.indices {
                if let e = edits[tracks[i].uniqueID] { e.apply(to: &tracks[i]) }
            }
            newDB.tracks = tracks
        }

        // 3. Removals (files are deleted only after the DB is safely written).
        let removedPaths = newDB.tracks.filter { deletes.contains($0.uniqueID) }.map { $0.relativePath }
        newDB.removeTracks(ids: deletes)

        // 4. Copy new files.
        var created: [URL] = []
        do {
            let folders = try musicFolders()
            var counts = folders.map { (try? fm.contentsOfDirectory(atPath: $0.path).count) ?? 0 }
            var nextID = max(newDB.nextTrackID, db.nextTrackID)
            var tracks = newDB.tracks
            for (n, add) in adds.enumerated() {
                progress(.copying(done: n, total: adds.count, name: add.meta.title.isEmpty ? add.sourceURL.lastPathComponent : add.meta.title))
                let fi = counts.indices.min { counts[$0] < counts[$1] } ?? 0
                let folder = folders[fi]
                let ext = add.sourceURL.pathExtension.isEmpty ? add.meta.kind.fileExtension : add.sourceURL.pathExtension.lowercased()
                var dest: URL
                repeat {
                    dest = folder.appendingPathComponent(IPodSession.randomName() + "." + ext)
                } while fm.fileExists(atPath: dest.path)
                do {
                    try fm.copyItem(at: add.sourceURL, to: dest)
                } catch {
                    throw IPodSessionError.copyFailed(add.sourceURL.lastPathComponent, error)
                }
                created.append(dest)
                counts[fi] += 1
                let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? add.meta.fileSize
                let rel = "iPod_Control/Music/\(folder.lastPathComponent)/\(dest.lastPathComponent)"
                tracks.append(Track.make(meta: add.meta, uniqueID: nextID, relativePath: rel,
                                         fileSize: UInt32(clamping: size)))
                nextID += 1
            }
            if !adds.isEmpty { progress(.copying(done: adds.count, total: adds.count, name: "")) }
            newDB.tracks = tracks

            // 5. Playlists + database.
            progress(.writingDatabase)
            newDB.rebuildMasterPlaylists()
            try write(newDB)
        } catch {
            for url in created { try? fm.removeItem(at: url) }
            throw error
        }

        // 6. Cleanup after a successful write.
        if mergedPlayCounts {
            try? fm.removeItem(at: device.playCountsURL)
            mergedPlayCounts = false
        }
        if let items = try? fm.contentsOfDirectory(atPath: device.iTunesURL.path) {
            for name in items where name.hasPrefix("OTGPlaylistInfo") {
                try? fm.removeItem(at: device.iTunesURL.appendingPathComponent(name))
            }
        }
        if !removedPaths.isEmpty {
            progress(.removingFiles)
            for p in removedPaths where !p.isEmpty {
                try? fm.removeItem(at: device.fileURL(forRelativePath: p))
            }
        }
        db = newDB
        databaseExisted = true
        progress(.finished)
    }

    /// Writes iTunesDB atomically, keeping the previous version as iTunesDB.bak.
    func write(_ newDB: ITunesDB) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: device.iTunesURL, withIntermediateDirectories: true)
        let bytes = newDB.serialize()
        // Sanity check: what we write must parse back.
        let check = try ITunesDB.parse(bytes)
        guard check.tracks.count == newDB.tracks.count else { throw ITunesDBError.noTrackList }

        let tmp = device.iTunesURL.appendingPathComponent("iTunesDB.ipm-tmp")
        let bak = device.iTunesURL.appendingPathComponent("iTunesDB.bak")
        try? fm.removeItem(at: tmp)
        let data = Data(bytes)
        try data.write(to: tmp)
        if let h = FileHandle(forWritingAtPath: tmp.path) {
            try? h.synchronize()
            try? h.close()
        }
        if fm.fileExists(atPath: device.databaseURL.path) {
            try? fm.removeItem(at: bak)
            try fm.copyItem(at: device.databaseURL, to: bak)
            try fm.removeItem(at: device.databaseURL)
        }
        try fm.moveItem(at: tmp, to: device.databaseURL)
    }

    func musicFolders() throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: device.musicURL, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(at: device.musicURL, includingPropertiesForKeys: nil))?
            .filter { url in
                let n = url.lastPathComponent
                return n.count == 3 && n.uppercased().hasPrefix("F") && Int(n.dropFirst()) != nil
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        if !existing.isEmpty { return existing }
        var made: [URL] = []
        for i in 0..<20 {
            let url = device.musicURL.appendingPathComponent(String(format: "F%02d", i), isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            made.append(url)
        }
        return made
    }

    static func randomName() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<6).map { _ in chars.randomElement()! })
    }
}
