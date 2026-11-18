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
    /// Cover image file data (JPEG/PNG), if any.
    public var artwork: Data?
    /// Tag changes to write into the copy on the iPod (the source file is never modified).
    public var fileTags: TagWrite?
    /// Sound Check value measured before the song was copied.
    public var soundCheck: UInt32?
    /// Lossless volume change for the copy on the iPod (the source file is never modified).
    public var fileGain: FileGainRequest?

    public init(sourceURL: URL, meta: AudioMeta, artwork: Data? = nil, fileTags: TagWrite? = nil,
                soundCheck: UInt32? = nil, fileGain: FileGainRequest? = nil) {
        self.sourceURL = sourceURL
        self.meta = meta
        self.artwork = artwork
        self.fileTags = fileTags
        self.soundCheck = soundCheck
        self.fileGain = fileGain
    }
}

public enum ArtworkChange: Sendable, Equatable {
    case set(Data)
    case remove
}

/// Lossless volume change of an MP3 file plus the Sound Check values that go with it.
public struct FileGainRequest: Sendable, Equatable {
    public var steps: Int
    /// Sound Check value to use when the file could not be changed.
    public var fullSoundCheck: UInt32
    /// Sound Check value for what the 1.5 dB steps could not cover.
    public var residualSoundCheck: UInt32

    public init(steps: Int, fullSoundCheck: UInt32, residualSoundCheck: UInt32) {
        self.steps = steps
        self.fullSoundCheck = fullSoundCheck
        self.residualSoundCheck = residualSoundCheck
    }
}

public struct CommitChanges: Sendable {
    public var adds: [NewTrack] = []
    public var deletes: Set<UInt32> = []
    public var edits: [UInt32: TrackEdit] = [:]
    public var artwork: [UInt32: ArtworkChange] = [:]
    public var fileGain: [UInt32: FileGainRequest] = [:]
    public var fileGainUndo: Set<UInt32> = []
    /// Tag and cover changes to store inside the audio files of existing songs.
    public var fileTags: [UInt32: TagWrite] = [:]

    public init() {}
}

/// A file that could not be changed during a write (the iPod database is updated regardless).
public struct CommitFailure: Sendable, Equatable {
    public enum Operation: Sendable, Equatable { case tags, volume }
    public enum Reason: Sendable, Equatable {
        /// The contents are not what the file extension says (or not audio at all).
        case wrongFormat
        case tooLarge
        /// A structure the app doesn't dare to rewrite; the text says which.
        case structure(String)
        /// Reading or writing failed (the system's own message).
        case io(String)
    }

    public var operation: Operation
    public var title: String
    public var artist: String
    public var file: String
    public var reason: Reason

    static func reason(for error: Error) -> Reason {
        let text: String
        switch error {
        case FileTagsError.unsupported(let s): text = s
        case MP3GainError.notMP3: return .wrongFormat
        case MP3GainError.unsupported(let s): text = s
        default: return .io(error.localizedDescription)
        }
        if text.contains("too large") { return .tooLarge }
        if text.hasPrefix("not an") || text.contains("no audio data") { return .wrongFormat }
        return .structure(text)
    }
}

public struct CommitReport: Sendable, Equatable {
    public var artworkWritten = 0
    public var artworkFailed = 0
    /// The iPod's artwork database is of a kind we don't write.
    public var artworkUnsupported = false
    public var filesChanged = 0
    public var filesRestored = 0
    public var filesFailed = 0
    public var tagsWritten = 0
    public var tagsFailed = 0
    /// Space reclaimed from the cover files.
    public var artworkBytesFreed: Int64 = 0
    /// Which files could not be changed, and why.
    public var failures: [CommitFailure] = []

    public init() {}
}

public enum CommitPhase: Equatable, Sendable {
    case copying(done: Int, total: Int, name: String)
    case changingFiles(done: Int, total: Int)
    case writingTags(done: Int, total: Int)
    case writingArtwork
    case writingDatabase
    case removingFiles
    case finished
}

/// Loads an iPod's database and applies batches of changes to it.
public final class IPodSession: @unchecked Sendable {
    public let device: IPodDevice
    public private(set) var db: ITunesDB
    public private(set) var artworkDB: ArtworkDB?
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
                }
            }
            self.db = db
            databaseExisted = true
        } else {
            self.db = ITunesDB.makeEmpty(name: device.volumeName)
            databaseExisted = false
        }
        artworkDB = device.loadArtworkDB()
    }

    public var tracks: [Track] { db.tracks }

    // MARK: Commit

    @discardableResult
    public func commit(_ changes: CommitChanges, progress: (CommitPhase) -> Void) throws -> CommitReport {
        let fm = FileManager.default
        var newDB = db
        var report = CommitReport()
        let adds = changes.adds
        let deletes = changes.deletes

        // 1. Space check.
        let needed = adds.reduce(Int64(0)) { $0 + max($1.meta.fileSize, 0) }
        if let cap = device.capacity, needed > 0 {
            let freed = newDB.tracks.filter { deletes.contains($0.uniqueID) }.reduce(Int64(0)) { $0 + Int64($1.size) }
            let available = cap.available + freed - 8 * 1024 * 1024
            if needed > available { throw IPodSessionError.noSpace(needed: needed, available: max(available, 0)) }
        }

        // 2. Tag edits.
        if !changes.edits.isEmpty {
            var tracks = newDB.tracks
            for i in tracks.indices {
                if let e = changes.edits[tracks[i].uniqueID] { e.apply(to: &tracks[i]) }
            }
            newDB.tracks = tracks
        }

        // 3. Removals (files are deleted only after the DB is safely written).
        let removedTracks = newDB.tracks.filter { deletes.contains($0.uniqueID) }
        let removedPaths = removedTracks.map { $0.relativePath }
        newDB.removeTracks(ids: deletes)

        var created: [URL] = []
        var artwork = changes.artwork
        var tagWrites = changes.fileTags
        var gainRequests = changes.fileGain
        do {
            // 4. Copy new files.
            var tracks = newDB.tracks
            if !adds.isEmpty {
                let folders = try musicFolders()
                var counts = folders.map { (try? fm.contentsOfDirectory(atPath: $0.path).count) ?? 0 }
                var nextID = max(newDB.nextTrackID, db.nextTrackID)
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
                    var track = Track.make(meta: add.meta, uniqueID: nextID, relativePath: rel,
                                           fileSize: UInt32(clamping: size))
                    if let sc = add.soundCheck { track.soundCheck = sc }
                    if let gain = add.fileGain { gainRequests[nextID] = gain }
                    tracks.append(track)
                    if let art = add.artwork { artwork[nextID] = .set(art) }
                    if let tags = add.fileTags, !tags.isEmpty { tagWrites[nextID] = tags }
                    nextID += 1
                }
                progress(.copying(done: adds.count, total: adds.count, name: ""))
            }

            // 5. Lossless volume changes inside MP3 files.
            let gainTotal = gainRequests.count + changes.fileGainUndo.count
            if gainTotal > 0 {
                var done = 0
                progress(.changingFiles(done: 0, total: gainTotal))
                for i in tracks.indices {
                    let id = tracks[i].uniqueID
                    let url = device.fileURL(for: tracks[i])
                    if let req = gainRequests[id] {
                        do {
                            if req.steps != 0 {
                                let size = try MP3Gain.applyToFile(url, steps: req.steps)
                                tracks[i].size = UInt32(clamping: size)
                                report.filesChanged += 1
                            }
                            tracks[i].soundCheck = req.residualSoundCheck
                        } catch {
                            tracks[i].soundCheck = req.fullSoundCheck
                            report.filesFailed += 1
                            report.failures.append(CommitFailure(operation: .volume, title: tracks[i].title, artist: tracks[i].artist,
                                                                 file: url.lastPathComponent, reason: CommitFailure.reason(for: error)))
                        }
                        tracks[i].timeModified = MacTime.now()
                        done += 1
                        progress(.changingFiles(done: done, total: gainTotal))
                    } else if changes.fileGainUndo.contains(id) {
                        do {
                            if let size = try MP3Gain.undoFile(url) {
                                tracks[i].size = UInt32(clamping: size)
                                tracks[i].soundCheck = 0
                                tracks[i].timeModified = MacTime.now()
                                report.filesRestored += 1
                            }
                        } catch {
                            report.filesFailed += 1
                            report.failures.append(CommitFailure(operation: .volume, title: tracks[i].title, artist: tracks[i].artist,
                                                                 file: url.lastPathComponent, reason: CommitFailure.reason(for: error)))
                        }
                        done += 1
                        progress(.changingFiles(done: done, total: gainTotal))
                    }
                }
            }

            // 5b. Tags and covers inside the audio files.
            if !tagWrites.isEmpty {
                var done = 0
                progress(.writingTags(done: 0, total: tagWrites.count))
                for i in tracks.indices {
                    guard let w = tagWrites[tracks[i].uniqueID] else { continue }
                    do {
                        switch try FileTags.write(w, to: device.fileURL(for: tracks[i])) {
                        case .written(let size):
                            tracks[i].size = UInt32(clamping: size)
                            tracks[i].timeModified = MacTime.now()
                            report.tagsWritten += 1
                        case .unchanged, .notApplicable:
                            break
                        }
                    } catch {
                        report.tagsFailed += 1
                        report.failures.append(CommitFailure(operation: .tags, title: tracks[i].title, artist: tracks[i].artist,
                                                             file: device.fileURL(for: tracks[i]).lastPathComponent,
                                                             reason: CommitFailure.reason(for: error)))
                    }
                    done += 1
                    progress(.writingTags(done: done, total: tagWrites.count))
                }
            }

            // 6. Cover art.
            let hadImages = removedTracks.contains { artworkDB?.hasImage(imageID: $0.mhiiLink, songID: $0.dbid) == true }
            if !artwork.isEmpty || hadImages {
                progress(.writingArtwork)
                applyArtwork(tracks: &tracks, changes: artwork, removed: removedTracks, report: &report)
            }
            newDB.tracks = tracks

            // 7. Playlists + database.
            progress(.writingDatabase)
            newDB.rebuildMasterPlaylists()
            try write(newDB)
        } catch {
            for url in created { try? fm.removeItem(at: url) }
            throw error
        }

        // 8. Cleanup after a successful write.
        // Play Counts entries are indexed by track position, so they are stale after any write.
        // They were merged at load time when they matched the old database.
        try? fm.removeItem(at: device.playCountsURL)
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
        return report
    }

    // MARK: Artwork

    /// Whether cover art can be written to this iPod.
    public var artworkSupported: Bool {
        if let db = artworkDB { return db.isWritable }
        if FileManager.default.fileExists(atPath: device.artworkDBURL.path) { return false } // exists but unreadable
        // No database yet: fine for an iPod Video; refuse models we know to be something else.
        let model = device.sysInfo["ModelNumStr"] ?? ""
        return model.isEmpty || device.looksLikeVideoModel
    }

    func applyArtwork(tracks: inout [Track], changes: [UInt32: ArtworkChange], removed: [Track], report: inout CommitReport) {
        let sets = changes.values.filter { if case .set = $0 { return true } else { return false } }.count
        guard artworkSupported else {
            report.artworkUnsupported = true
            report.artworkFailed += sets
            return
        }
        let fm = FileManager.default
        var adb = artworkDB ?? ArtworkDB.makeEmpty()
        var working = tracks
        var written = 0, failed = 0
        do {
            try fm.createDirectory(at: device.artworkURL, withIntermediateDirectories: true)
            // iTunes lets several songs of an album share one image item, so an item
            // only goes away when its last user does.
            var users: [UInt32: Int] = [:]
            for t in working where t.mhiiLink != 0 { users[t.mhiiLink, default: 0] += 1 }
            func release(_ t: Track, counted: Bool) {
                let link = t.mhiiLink
                if link != 0 {
                    if counted { users[link, default: 1] -= 1 }
                    if users[link, default: 0] <= 0 { adb.removeImage(imageID: link, songID: 0) }
                } else {
                    adb.removeImage(imageID: 0, songID: t.dbid)
                }
            }
            for t in removed { release(t, counted: false) }
            var rendered: [Data: [ArtworkDB.ThumbRef]] = [:]
            var unreadable = Set<Data>()
            for i in working.indices {
                guard let change = changes[working[i].uniqueID] else { continue }
                switch change {
                case .remove:
                    release(working[i], counted: true)
                    working[i].clearArtwork()
                case .set(let data):
                    if unreadable.contains(data) { failed += 1; continue }
                    var refs = rendered[data]
                    if refs == nil {
                        var pixels: [(ArtworkFormat, Data)] = []
                        for f in ArtworkFormat.video {
                            if let p = ArtworkPixels.rgb565(from: data, width: f.width, height: f.height) { pixels.append((f, p)) }
                        }
                        if pixels.count == ArtworkFormat.video.count {
                            var made: [ArtworkDB.ThumbRef] = []
                            for (f, p) in pixels { made.append(try appendThumb(p, format: f)) }
                            refs = made
                            rendered[data] = made
                        } else {
                            unreadable.insert(data)
                        }
                    }
                    guard let refs else { failed += 1; continue }
                    if working[i].dbid == 0 { working[i].dbid = UInt64.random(in: 1...UInt64.max) }
                    release(working[i], counted: true)
                    let id = adb.addImage(songID: working[i].dbid, sourceSize: UInt32(clamping: data.count), thumbs: refs)
                    working[i].setArtwork(imageID: id, sourceSize: UInt32(clamping: data.count))
                    written += 1
                }
            }
            adb.ensureFiles(ArtworkFormat.video)
            // Reclaim the space of covers nobody uses any more, once it is worth it.
            var swaps: [(tmp: URL, final: URL)] = []
            var freed: Int64 = 0
            if let plan = try? planCompaction(adb, force: false) {
                adb = plan.db
                swaps = plan.swaps
                freed = plan.freed
            }
            try writeArtworkDB(adb, swaps: swaps)
            report.artworkBytesFreed += freed
        } catch {
            // Cover art is optional: keep the songs, report the problem.
            report.artworkFailed += sets
            return
        }
        tracks = working
        artworkDB = adb
        report.artworkWritten += written
        report.artworkFailed += failed
    }

    static let ithmbLimit = 256 * 1024 * 1024

    func appendThumb(_ pixels: Data, format: ArtworkFormat) throws -> ArtworkDB.ThumbRef {
        let fm = FileManager.default
        let prefix = "F\(format.id)_"
        let names = (try? fm.contentsOfDirectory(atPath: device.artworkURL.path)) ?? []
        var index = names.compactMap { n -> Int? in
            guard n.hasPrefix(prefix), n.hasSuffix(".ithmb") else { return nil }
            return Int(n.dropFirst(prefix.count).dropLast(6))
        }.max() ?? 1
        func url(_ i: Int) -> URL { device.artworkURL.appendingPathComponent("\(prefix)\(i).ithmb") }
        func size(_ i: Int) -> Int {
            let attrs = try? fm.attributesOfItem(atPath: url(i).path)
            return (attrs?[.size] as? NSNumber)?.intValue ?? 0
        }
        if size(index) + pixels.count > IPodSession.ithmbLimit { index += 1 }
        let file = url(index)
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        let h = try FileHandle(forWritingTo: file)
        defer { try? h.close() }
        let offset = try h.seekToEnd()
        try h.write(contentsOf: pixels)
        return ArtworkDB.ThumbRef(formatID: format.id, offset: Int(offset), size: pixels.count,
                                  fileName: ":\(prefix)\(index).ithmb")
    }

    func writeArtworkDB(_ adb: ArtworkDB, swaps: [(tmp: URL, final: URL)] = []) throws {
        let fm = FileManager.default
        let target = device.artworkDBURL
        let tmp = device.artworkURL.appendingPathComponent("ArtworkDB.ipm-tmp")
        let bak = device.artworkURL.appendingPathComponent("ArtworkDB.bak")
        do {
            let bytes = adb.serialize()
            let check = try ArtworkDB.parse(bytes)
            guard check.imageCount == adb.imageCount else { throw ArtworkDBError.bad("verification failed") }
            try? fm.removeItem(at: tmp)
            try Data(bytes).write(to: tmp)
        } catch {
            for s in swaps { try? fm.removeItem(at: s.tmp) }
            throw error
        }
        try? fm.removeItem(at: bak)
        if swaps.isEmpty {
            if fm.fileExists(atPath: target.path) { try? fm.copyItem(at: target, to: bak) }
        } else {
            // The old database would point at the old pixel layout, so no backup is kept here.
            // New pixel files and the new database go live back to back.
            for s in swaps {
                if rename(s.tmp.path, s.final.path) != 0 {
                    for rest in swaps { try? fm.removeItem(at: rest.tmp) }
                    try? fm.removeItem(at: tmp)
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }
        if rename(tmp.path, target.path) != 0 {
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    // MARK: Compacting cover files

    struct CompactionPlan {
        var db: ArtworkDB
        var swaps: [(tmp: URL, final: URL)]
        var freed: Int64
    }

    struct PixelFile {
        var name: String            // as stored in the database, e.g. ":F1028_1.ithmb"
        var url: URL
        var size: Int
        var blocks: [(offset: Int, size: Int)]
        var live: Int { blocks.reduce(0) { $0 + $1.size } }
        var waste: Int { size - live }
    }

    /// Pixel files with their used blocks. Files with anything unexpected in them are left out.
    func pixelFiles(_ adb: ArtworkDB) -> [PixelFile] {
        let fm = FileManager.default
        var byName: [String: [Int: Int]] = [:]
        var bad = Set<String>()
        for r in adb.allThumbRefs() {
            if let s = byName[r.fileName]?[r.offset], s != r.size { bad.insert(r.fileName) }
            byName[r.fileName, default: [:]][r.offset] = r.size
        }
        var out: [PixelFile] = []
        for (name, map) in byName where !bad.contains(name) {
            var plain = name
            while plain.hasPrefix(":") { plain.removeFirst() }
            guard !plain.isEmpty, !plain.contains(":"), !plain.contains("/"), plain.hasSuffix(".ithmb") else { continue }
            let url = device.artworkURL.appendingPathComponent(plain)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.intValue else { continue }
            let blocks = map.map { (offset: $0.key, size: $0.value) }.sorted { $0.offset < $1.offset }
            var ok = true
            var end = 0
            for b in blocks {
                if b.size <= 0 || b.offset < end || b.offset + b.size > size { ok = false; break }
                end = b.offset + b.size
            }
            if ok { out.append(PixelFile(name: name, url: url, size: size, blocks: blocks)) }
        }
        return out
    }

    /// Bytes in the cover files that no cover uses.
    public func artworkWaste() -> Int64 {
        guard let adb = artworkDB, artworkSupported else { return 0 }
        return pixelFiles(adb).reduce(Int64(0)) { $0 + Int64(max($1.waste, 0)) }
    }

    /// Writes compacted copies of the pixel files next to the originals and returns the database
    /// with remapped offsets. Nothing is live until `writeArtworkDB` swaps the files in.
    func planCompaction(_ adb: ArtworkDB, force: Bool) throws -> CompactionPlan {
        let fm = FileManager.default
        var swaps: [(tmp: URL, final: URL)] = []
        var map: [String: [Int: Int]] = [:]
        var freed: Int64 = 0
        do {
            for file in pixelFiles(adb) {
                let waste = file.waste
                guard waste > 0 else { continue }
                if !force, waste < 2 * 1024 * 1024 || waste * 10 < file.size { continue }
                let tmp = file.url.appendingPathExtension("ipm-new")
                try? fm.removeItem(at: tmp)
                fm.createFile(atPath: tmp.path, contents: nil)
                swaps.append((tmp, file.url))
                let input = try FileHandle(forReadingFrom: file.url)
                defer { try? input.close() }
                let output = try FileHandle(forWritingTo: tmp)
                defer { try? output.close() }
                var position = 0
                var offsets: [Int: Int] = [:]
                for b in file.blocks {
                    try input.seek(toOffset: UInt64(b.offset))
                    guard let data = try input.read(upToCount: b.size), data.count == b.size else {
                        throw ArtworkDBError.bad("short read in \(file.url.lastPathComponent)")
                    }
                    try output.write(contentsOf: data)
                    offsets[b.offset] = position
                    position += b.size
                }
                try output.synchronize()
                map[file.name] = offsets
                freed += Int64(waste)
            }
        } catch {
            for s in swaps { try? fm.removeItem(at: s.tmp) }
            throw error
        }
        var db = adb
        db.remapOffsets(map)
        return CompactionPlan(db: db, swaps: swaps, freed: freed)
    }

    /// Frees the space of unused covers right now. Returns the number of bytes reclaimed.
    public func compactArtwork() throws -> Int64 {
        guard let adb = artworkDB, artworkSupported else { return 0 }
        let plan = try planCompaction(adb, force: true)
        guard !plan.swaps.isEmpty else { return 0 }
        try writeArtworkDB(plan.db, swaps: plan.swaps)
        artworkDB = plan.db
        return plan.freed
    }

    // MARK: iTunesDB

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
