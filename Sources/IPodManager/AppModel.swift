import SwiftUI
import AppKit
import IPodKit

struct LocalTrack: Identifiable, Hashable {
    let url: URL
    var meta: AudioMeta
    var onIPod = false

    var id: String { url.path }
    var title: String { meta.title }
    var artist: String { meta.artist }
    var album: String { meta.album }
    var durationMs: Int { meta.durationMs }
    var formatLabel: String { meta.kind.label }
    var supported: Bool { meta.kind.isSupported }
    var onIPodSort: Int { onIPod ? 1 : 0 }
}

struct PendingAdd: Identifiable {
    let id = UUID()
    var url: URL
    var meta: AudioMeta
    /// nil = use the cover embedded in the file.
    var artwork: ArtworkChange?
    /// Tag edits made before the song was written (they also go into the copy on the iPod).
    var fileEdit = TrackEdit()
    /// Stand-in track id, so the tag search and the volume tools can address the song before it is written.
    let tempID: UInt32 = PendingAdd.newTempID()
    /// Sound Check value measured before the song is written.
    var soundCheck: UInt32?
    /// Volume change for the copy on the iPod (the file on the Mac stays as it is).
    var fileGain: FileGainRequest?
    /// Whether the file carries its own cover.
    var hasEmbeddedArt = true

    private static var tempCounter: UInt32 = 0xF000_0000
    private static func newTempID() -> UInt32 {
        tempCounter = tempCounter == UInt32.max ? 0xF000_0000 : tempCounter + 1
        return tempCounter
    }

    /// Sound Check value the song is going to get (0 = none planned).
    var plannedSoundCheck: UInt32 { soundCheck ?? fileGain?.fullSoundCheck ?? 0 }

    /// The song as a track, for the tools that work on tracks.
    var asTrack: Track {
        let ext = url.pathExtension.isEmpty ? meta.kind.fileExtension : url.pathExtension.lowercased()
        var t = Track.make(meta: meta, uniqueID: tempID, relativePath: "new." + ext,
                           fileSize: UInt32(clamping: max(meta.fileSize, 0)))
        t.soundCheck = plannedSoundCheck
        return t
    }
}

enum RowStatus: Int, Hashable {
    case normal = 0, edited = 1, added = 2, deleted = 3
}

struct IPodRow: Identifiable, Hashable {
    let id: String
    var trackID: UInt32?
    var pendingID: UUID?
    var title: String
    var artist: String
    var album: String
    var durationMs: Int
    var gainSort: Double
    var gainLabel: String
    var status: RowStatus
    var statusSort: Int { status.rawValue }
    var fileURL: URL?
    var imageID: UInt32 = 0
    var dbid: UInt64 = 0
}

enum CommitState: Equatable {
    case idle
    case running(CommitPhase)
    case done
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var devices: [IPodDevice] = []
    @Published private(set) var device: IPodDevice?
    @Published private(set) var session: IPodSession?
    @Published private(set) var loading = false
    @Published var loadError: String?
    @Published private(set) var capacity: IPodDevice.Capacity?

    @Published private(set) var tracks: [Track] = [] { didSet { rebuildRows() } }
    @Published var pendingAdds: [PendingAdd] = [] { didSet { rebuildRows() } }
    @Published var pendingDeletes: Set<UInt32> = [] { didSet { rebuildRows() } }
    @Published var pendingEdits: [UInt32: TrackEdit] = [:] { didSet { rebuildRows() } }
    @Published var pendingArtwork: [UInt32: ArtworkChange] = [:] { didSet { rebuildRows() } }
    @Published var pendingFileGain: [UInt32: FileGainRequest] = [:] { didSet { rebuildRows() } }
    @Published var pendingFileUndo: Set<UInt32> = [] { didSet { rebuildRows() } }
    /// Songs whose database tags should be copied into the files.
    @Published var pendingTagSync: Set<UInt32> = [] { didSet { rebuildRows() } }
    /// Queued covers that were read from the song's own file (no need to write them back into it).
    private var artworkFromFile: Set<UInt32> = []
    @Published private(set) var compacting = false
    @Published private(set) var ipodRows: [IPodRow] = []
    /// Snapshot of the iPod's cover database, for thumbnails.
    @Published private(set) var artworkDB: ArtworkDB?
    /// Changes whenever covers on the iPod may have changed (busts the thumbnail cache).
    @Published private(set) var artVersion = 0
    @Published private(set) var artworkSupported = false
    @Published private(set) var lastReport = CommitReport()
    @Published private(set) var coverScan: (done: Int, total: Int)?

    @Published private(set) var macFolder: URL
    @Published private(set) var macTracks: [LocalTrack] = []
    @Published private(set) var macScanning = false
    @Published private(set) var macScanned = 0

    @Published var showCommitSheet = false
    @Published var commitState: CommitState = .idle
    @Published var notice: String?

    private var observers: [NSObjectProtocol] = []
    private var scanTask: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.string(forKey: "macFolder")
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        macFolder = saved.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? music ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

        let nc = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in self.refreshDevices() }
            }
            observers.append(token)
        }
        refreshDevices()
        scanMacFolder()
    }

    // MARK: - Devices

    func refreshDevices() {
        let found = IPodDevice.detectAll()
        devices = found
        if let d = device, found.contains(d) {
            capacity = d.capacity
            return
        }
        if device != nil {
            device = nil
            session = nil
            artworkDB = nil
            tracks = []
            clearPending()
            capacity = nil
        }
        if let first = found.first { select(first) }
    }

    func select(_ d: IPodDevice) {
        if d == device, session != nil || loading { return }
        device = d
        session = nil
        artworkDB = nil
        artworkSupported = false
        loadError = nil
        tracks = []
        clearPending()
        capacity = d.capacity
        loading = true
        Task.detached(priority: .userInitiated) {
            do {
                let s = try IPodSession(device: d)
                let supported = s.artworkSupported
                await MainActor.run {
                    guard self.device == d else { return }
                    self.session = s
                    self.tracks = s.tracks
                    self.artworkDB = s.artworkDB
                    self.artworkSupported = supported
                    self.artVersion += 1
                    self.loading = false
                    self.refreshOnIPodFlags()
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard self.device == d else { return }
                    self.loadError = message
                    self.loading = false
                }
            }
        }
    }

    func eject() {
        guard let d = device else { return }
        if hasPending {
            notice = L("eject.pending")
            return
        }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: d.mountURL)
        } catch {
            notice = error.localizedDescription
        }
    }

    var deviceModel: String? {
        guard let d = device else { return nil }
        if let m = d.sysInfo["ModelNumStr"], !m.isEmpty { return m }
        return nil
    }

    // MARK: - Pending changes

    var hasPending: Bool {
        !pendingAdds.isEmpty || !pendingDeletes.isEmpty || !pendingEdits.isEmpty
            || !pendingArtwork.isEmpty || !pendingFileGain.isEmpty || !pendingFileUndo.isEmpty
            || !pendingTagSync.isEmpty
    }

    /// Songs with any queued change other than add/delete.
    var pendingChangedCount: Int {
        Set(pendingEdits.keys).union(pendingArtwork.keys).union(pendingFileGain.keys).union(pendingFileUndo)
            .union(pendingTagSync).subtracting(pendingDeletes).count
    }
    var canCommit: Bool { hasPending && session != nil && !commitState.isRunning && !compacting }
    var pendingAddBytes: Int64 { pendingAdds.reduce(0) { $0 + $1.meta.fileSize } }
    var pendingDeleteBytes: Int64 {
        tracks.filter { pendingDeletes.contains($0.uniqueID) }.reduce(0) { $0 + Int64($1.size) }
    }
    var musicBytes: Int64 { tracks.reduce(0) { $0 + Int64($1.size) } }

    func clearPending() {
        pendingAdds = []
        pendingDeletes = []
        pendingEdits = [:]
        pendingArtwork = [:]
        pendingFileGain = [:]
        pendingFileUndo = []
        pendingTagSync = []
        artworkFromFile = []
    }

    func discardPending() {
        clearPending()
        refreshOnIPodFlags()
    }

    nonisolated static func dupKey(_ title: String, _ artist: String) -> String {
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        let a = artist.trimmingCharacters(in: .whitespaces).lowercased()
        return a + "\u{1F}" + t
    }

    private func currentKeys() -> Set<String> {
        var keys = Set<String>()
        for t in tracks where !pendingDeletes.contains(t.uniqueID) {
            let e = effective(t)
            keys.insert(AppModel.dupKey(e.title, e.artist))
        }
        for a in pendingAdds { keys.insert(AppModel.dupKey(a.meta.title, a.meta.artist)) }
        return keys
    }

    func refreshOnIPodFlags() {
        let keys = currentKeys()
        var changed = false
        var list = macTracks
        for i in list.indices {
            let v = keys.contains(AppModel.dupKey(list[i].meta.title, list[i].meta.artist))
            if list[i].onIPod != v { list[i].onIPod = v; changed = true }
        }
        if changed { macTracks = list }
    }

    func effective(_ t: Track) -> Track {
        guard let e = pendingEdits[t.uniqueID] else { return t }
        var c = t
        e.apply(to: &c)
        return c
    }

    private func rebuildRows() {
        var rows: [IPodRow] = []
        rows.reserveCapacity(tracks.count + pendingAdds.count)
        for t in tracks {
            let e = effective(t)
            let gain = SoundCheck.gain(forValue: e.soundCheck)
            let id = t.uniqueID
            let changed = pendingEdits[id] != nil || pendingArtwork[id] != nil
                || pendingFileGain[id] != nil || pendingFileUndo.contains(id) || pendingTagSync.contains(id)
            let status: RowStatus = pendingDeletes.contains(id) ? .deleted : (changed ? .edited : .normal)
            rows.append(IPodRow(id: "t\(t.uniqueID)", trackID: t.uniqueID, pendingID: nil,
                                title: e.title, artist: e.artist, album: e.album,
                                durationMs: Int(e.durationMs), gainSort: gain ?? -999,
                                gainLabel: formatGain(gain), status: status,
                                fileURL: device?.fileURL(for: t), imageID: t.mhiiLink, dbid: t.dbid))
        }
        for a in pendingAdds {
            let planned = a.plannedSoundCheck == 0 ? nil : SoundCheck.gain(forValue: a.plannedSoundCheck)
            rows.append(IPodRow(id: "n\(a.id.uuidString)", trackID: nil, pendingID: a.id,
                                title: a.meta.title, artist: a.meta.artist, album: a.meta.album,
                                durationMs: a.meta.durationMs, gainSort: planned ?? -999,
                                gainLabel: planned == nil ? "–" : formatGain(planned),
                                status: .added, fileURL: a.url))
        }
        ipodRows = rows
    }

    func trackIDs(for rowIDs: Set<String>) -> [UInt32] {
        rowIDs.compactMap { $0.hasPrefix("t") ? UInt32($0.dropFirst()) : nil }
    }

    /// Track ids of the rows, including the stand-in ids of songs that are not written yet.
    func itemIDs(for rowIDs: Set<String>) -> [UInt32] {
        let pend = pendingIDs(for: rowIDs)
        return trackIDs(for: rowIDs) + (pend.isEmpty ? [] : pendingAdds.filter { pend.contains($0.id) }.map { $0.tempID })
    }

    /// Songs the tag search and the volume tools can work on: what is on the iPod plus what is queued for it.
    var workTracks: [Track] {
        tracks.filter { !pendingDeletes.contains($0.uniqueID) }.map { effective($0) } + pendingAdds.map { $0.asTrack }
    }

    /// Where the audio of such a song can be read right now.
    func workURLs() -> [UInt32: URL] {
        var out: [UInt32: URL] = [:]
        if let device {
            for t in tracks { out[t.uniqueID] = device.fileURL(for: t) }
        }
        for a in pendingAdds { out[a.tempID] = a.url }
        return out
    }

    private func tempIndex() -> [UInt32: Int] {
        var out: [UInt32: Int] = [:]
        for (i, a) in pendingAdds.enumerated() { out[a.tempID] = i }
        return out
    }

    func pendingIDs(for rowIDs: Set<String>) -> Set<UUID> {
        Set(rowIDs.compactMap { $0.hasPrefix("n") ? UUID(uuidString: String($0.dropFirst())) : nil })
    }

    func markDeleted(_ rowIDs: Set<String>) {
        let ids = trackIDs(for: rowIDs)
        if !ids.isEmpty { pendingDeletes.formUnion(ids) }
        let pend = pendingIDs(for: rowIDs)
        if !pend.isEmpty { pendingAdds.removeAll { pend.contains($0.id) } }
        refreshOnIPodFlags()
    }

    func restore(_ rowIDs: Set<String>) {
        let ids = trackIDs(for: rowIDs)
        for id in ids {
            pendingDeletes.remove(id)
            pendingEdits[id] = nil
            pendingArtwork[id] = nil
            pendingFileGain[id] = nil
            pendingFileUndo.remove(id)
            pendingTagSync.remove(id)
            artworkFromFile.remove(id)
        }
        refreshOnIPodFlags()
    }

    func applyEdit(_ edit: TrackEdit, to rowIDs: Set<String>) {
        guard !edit.isEmpty else { return }
        var edits = pendingEdits
        for id in trackIDs(for: rowIDs) {
            edits[id] = (edits[id] ?? TrackEdit()).merged(with: edit)
        }
        pendingEdits = edits
        let pend = pendingIDs(for: rowIDs)
        if !pend.isEmpty {
            var adds = pendingAdds
            for i in adds.indices where pend.contains(adds[i].id) {
                edit.apply(to: &adds[i].meta)
                adds[i].fileEdit = adds[i].fileEdit.merged(with: edit)
            }
            pendingAdds = adds
        }
        refreshOnIPodFlags()
    }

    /// Different edits for different tracks in one go (one UI refresh).
    func applyEdits(_ map: [UInt32: TrackEdit]) {
        guard !map.isEmpty else { return }
        let temp = tempIndex()
        var edits = pendingEdits
        var adds = pendingAdds
        var addsChanged = false
        for (id, e) in map where !e.isEmpty {
            if let i = temp[id] {
                e.apply(to: &adds[i].meta)
                adds[i].fileEdit = adds[i].fileEdit.merged(with: e)
                addsChanged = true
            } else {
                edits[id] = (edits[id] ?? TrackEdit()).merged(with: e)
            }
        }
        pendingEdits = edits
        if addsChanged { pendingAdds = adds }
        refreshOnIPodFlags()
    }

    // MARK: - Artwork

    func hasArtwork(_ t: Track) -> Bool {
        if let a = pendingAdds.first(where: { $0.tempID == t.uniqueID }) {
            switch a.artwork {
            case .set: return true
            case .remove: return false
            case nil: return a.hasEmbeddedArt
            }
        }
        switch pendingArtwork[t.uniqueID] {
        case .set: return true
        case .remove: return false
        case nil: return artworkDB?.hasImage(imageID: t.mhiiLink, songID: t.dbid) ?? false
        }
    }

    func setArtwork(_ change: ArtworkChange, rowIDs: Set<String>) {
        var change = change
        if case .set(let d) = change {
            guard let n = ArtworkPixels.normalized(d) else { return }
            change = .set(n)
        }
        var map = pendingArtwork
        for id in trackIDs(for: rowIDs) {
            map[id] = change
            artworkFromFile.remove(id)
        }
        pendingArtwork = map
        let pend = pendingIDs(for: rowIDs)
        if !pend.isEmpty {
            var adds = pendingAdds
            for i in adds.indices where pend.contains(adds[i].id) { adds[i].artwork = change }
            pendingAdds = adds
        }
    }

    func applyArtwork(_ covers: [UInt32: Data], fromFiles: Bool = false) {
        guard !covers.isEmpty else { return }
        let temp = tempIndex()
        var map = pendingArtwork
        var adds = pendingAdds
        var addsChanged = false
        for (id, d) in covers {
            if let i = temp[id] {
                adds[i].artwork = .set(d)
                addsChanged = true
                continue
            }
            map[id] = .set(d)
            if fromFiles { artworkFromFile.insert(id) } else { artworkFromFile.remove(id) }
        }
        pendingArtwork = map
        if addsChanged { pendingAdds = adds }
    }

    // MARK: - Tags inside the files

    /// Whether tag and cover changes are also stored inside the audio files.
    var writesFileTags: Bool {
        UserDefaults.standard.object(forKey: Prefs.writeFileTags) as? Bool ?? true
    }

    /// Queues copying the database tags of these songs (all songs when nil) into their files.
    func queueTagSync(_ rowIDs: Set<String>?) {
        let ids: [UInt32]
        if let rowIDs {
            ids = trackIDs(for: rowIDs)
        } else {
            ids = tracks.map { $0.uniqueID }.filter { !pendingDeletes.contains($0) }
        }
        guard !ids.isEmpty else { return }
        pendingTagSync.formUnion(ids)
        notice = LF("sync.queued", ids.count)
    }

    private func fileTagWrites() -> [UInt32: TagWrite] {
        let editsToFiles = writesFileTags
        var out: [UInt32: TagWrite] = [:]
        for t in tracks {
            let id = t.uniqueID
            guard !pendingDeletes.contains(id) else { continue }
            var w = TagWrite()
            if pendingTagSync.contains(id) { w = TagWrite(allOf: effective(t)) }
            if editsToFiles {
                if let e = pendingEdits[id] { w = w.merged(with: TagWrite(edit: e, result: effective(t))) }
                if let a = pendingArtwork[id], !artworkFromFile.contains(id) { w.artwork = a }
            }
            if !w.isEmpty { out[id] = w }
        }
        return out
    }

    /// Frees the space unused covers still take on the iPod.
    func compactArtwork() {
        guard let s = session, !compacting, !commitState.isRunning else { return }
        guard !hasPending else {
            notice = L("compact.pending")
            return
        }
        compacting = true
        Task.detached(priority: .userInitiated) {
            var freed: Int64 = 0
            var failure: String?
            do { freed = try s.compactArtwork() } catch { failure = error.localizedDescription }
            let adb = s.artworkDB
            let cap = s.device.capacity
            let done = freed, problem = failure
            await MainActor.run {
                self.compacting = false
                if let problem {
                    self.notice = problem
                } else {
                    self.artworkDB = adb
                    self.artVersion += 1
                    self.capacity = cap
                    self.notice = done > 0 ? LF("compact.done", formatBytes(done)) : L("compact.nothing")
                }
            }
        }
    }

    /// Queues the covers embedded in the files for every song that has none on the iPod.
    func addCoversFromFiles() {
        guard let device, coverScan == nil else { return }
        guard artworkSupported else {
            notice = L("art.unsupported")
            return
        }
        let targets = tracks.filter { !pendingDeletes.contains($0.uniqueID) && !hasArtwork($0) }
            .map { (id: $0.uniqueID, url: device.fileURL(for: $0)) }
        guard !targets.isEmpty else {
            notice = L("covers.none")
            return
        }
        coverScan = (0, targets.count)
        Task {
            var found: [UInt32: Data] = [:]
            var shared: [Data: Data] = [:]      // identical covers share one buffer
            for (n, t) in targets.enumerated() {
                if let raw = await AudioMetaReader.artworkData(url: t.url),
                   let d = await Task.detached(operation: { ArtworkPixels.normalized(raw) }).value {
                    let one = shared[d] ?? d
                    shared[d] = one
                    found[t.id] = one
                }
                if n % 20 == 0 { self.coverScan = (n, targets.count) }
                if self.device != device { break }
            }
            self.coverScan = nil
            guard self.device == device else { return }
            self.applyArtwork(found, fromFiles: true)
            self.notice = LF("covers.found", found.count, targets.count)
        }
    }

    // MARK: - Volume

    func applyFileGain(_ requests: [UInt32: FileGainRequest]) {
        guard !requests.isEmpty else { return }
        let temp = tempIndex()
        var map = pendingFileGain
        var undo = pendingFileUndo
        var adds = pendingAdds
        var addsChanged = false
        for (id, r) in requests {
            if let i = temp[id] {
                adds[i].fileGain = r
                adds[i].soundCheck = nil
                addsChanged = true
                continue
            }
            map[id] = r
            undo.remove(id)
        }
        pendingFileGain = map
        pendingFileUndo = undo
        if addsChanged { pendingAdds = adds }
    }

    /// Returns how many songs on the iPod were queued.
    @discardableResult
    func queueFileUndo(_ ids: [UInt32]) -> Int {
        // Songs that are not written yet have nothing to restore: only their planned change is dropped.
        let temp = tempIndex()
        if ids.contains(where: { temp[$0] != nil }) {
            var adds = pendingAdds
            for id in ids { if let i = temp[id] { adds[i].fileGain = nil } }
            pendingAdds = adds
        }
        let real = ids.filter { temp[$0] == nil }
        guard !real.isEmpty else { return 0 }
        var map = pendingFileGain
        for id in real { map[id] = nil }
        pendingFileGain = map
        pendingFileUndo.formUnion(real)
        return real.count
    }

    func applySoundCheck(_ values: [UInt32: UInt32]) {
        if !pendingFileGain.isEmpty {
            var map = pendingFileGain
            for id in values.keys { map[id] = nil }
            pendingFileGain = map
        }
        let temp = tempIndex()
        var edits = pendingEdits
        var adds = pendingAdds
        var addsChanged = false
        for (id, v) in values {
            if let i = temp[id] {
                adds[i].soundCheck = v
                adds[i].fileGain = nil
                addsChanged = true
                continue
            }
            var e = TrackEdit()
            e.soundCheck = v
            edits[id] = (edits[id] ?? TrackEdit()).merged(with: e)
        }
        pendingEdits = edits
        if addsChanged { pendingAdds = adds }
    }

    /// Tag values used to prefill the editor: effective tracks + pending adds.
    func editableItems(_ rowIDs: Set<String>) -> [AudioMeta] {
        var out: [AudioMeta] = []
        let ids = Set(trackIDs(for: rowIDs))
        for t in tracks where ids.contains(t.uniqueID) {
            let e = effective(t)
            var m = AudioMeta()
            m.title = e.title
            m.artist = e.artist
            m.album = e.album
            m.albumArtist = e.albumArtist
            m.genre = e.genre
            m.composer = e.composer
            m.year = Int(e.year)
            m.trackNumber = Int(e.trackNumber)
            m.trackCount = Int(e.trackCount)
            m.discNumber = Int(e.discNumber)
            m.discCount = Int(e.discCount)
            m.compilation = e.compilation
            out.append(m)
        }
        let pend = pendingIDs(for: rowIDs)
        for a in pendingAdds where pend.contains(a.id) { out.append(a.meta) }
        return out
    }

    // MARK: - Adding files

    /// iPod rows for songs picked in the Mac list. Songs that are not on the iPod yet are queued first,
    /// so the tag search and the volume tools can be started straight from the Mac list.
    func rowsForMac(_ ids: Set<String>) async -> Set<String> {
        guard session != nil else { return [] }
        let picked = macTracks.filter { ids.contains($0.id) && $0.supported }
        guard !picked.isEmpty else { return [] }
        func lookup() -> (byPath: [String: String], byKey: [String: [String]]) {
            var byPath: [String: String] = [:]
            var byKey: [String: [String]] = [:]
            for a in pendingAdds {
                byPath[a.url.standardizedFileURL.path] = "n\(a.id.uuidString)"
                byKey[AppModel.dupKey(a.meta.title, a.meta.artist), default: []].append("n\(a.id.uuidString)")
            }
            for raw in tracks where !pendingDeletes.contains(raw.uniqueID) {
                let t = effective(raw)
                byKey[AppModel.dupKey(t.title, t.artist), default: []].append("t\(t.uniqueID)")
            }
            return (byPath, byKey)
        }
        func rows(_ t: LocalTrack, _ maps: (byPath: [String: String], byKey: [String: [String]])) -> [String] {
            if let r = maps.byPath[t.url.standardizedFileURL.path] { return [r] }
            return maps.byKey[AppModel.dupKey(t.meta.title, t.meta.artist)] ?? []
        }
        var maps = lookup()
        let missing = picked.filter { rows($0, maps).isEmpty }.map { $0.url }
        if !missing.isEmpty {
            await add(urls: missing)
            maps = lookup()
        }
        var out = Set<String>()
        for t in picked { out.formUnion(rows(t, maps)) }
        return out
    }

    func addFromMac(_ ids: Set<String>) {
        let urls = macTracks.filter { ids.contains($0.id) }.map { $0.url }
        Task { await add(urls: urls) }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard session != nil else { return false }
        Task {
            var urls: [URL] = []
            for p in providers {
                if let u = await AppModel.loadURL(p) { urls.append(u) }
            }
            await add(urls: urls)
        }
        return true
    }

    nonisolated static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                cont.resume(returning: url)
            }
        }
    }

    func add(urls: [URL]) async {
        guard session != nil, !urls.isEmpty else { return }
        let files = await Task.detached { AppModel.expand(urls) }.value
        var keys = currentKeys()
        var known: [String: AudioMeta] = [:]
        for t in macTracks { known[t.url.standardizedFileURL.path] = t.meta }
        var unsupported = 0
        var duplicates = 0
        var newOnes: [PendingAdd] = []
        for f in files {
            let meta: AudioMeta
            if let m = known[f.standardizedFileURL.path] {
                meta = m
            } else {
                meta = await AudioMetaReader.read(url: f)
            }
            guard meta.kind.isSupported else { unsupported += 1; continue }
            let k = AppModel.dupKey(meta.title, meta.artist)
            if keys.contains(k) { duplicates += 1; continue }
            keys.insert(k)
            var add = PendingAdd(url: f, meta: meta)
            add.hasEmbeddedArt = await AudioMetaReader.artworkData(url: f) != nil
            newOnes.append(add)
        }
        if !newOnes.isEmpty { pendingAdds.append(contentsOf: newOnes) }
        refreshOnIPodFlags()
        var parts: [String] = []
        if unsupported > 0 { parts.append(LF("add.skipped.unsupported", unsupported)) }
        if duplicates > 0 { parts.append(LF("add.skipped.duplicates", duplicates)) }
        if !parts.isEmpty { notice = parts.joined(separator: "\n") }
    }

    nonisolated static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                out.append(contentsOf: listAudioFiles(in: u))
            } else if AudioMetaReader.isListed(u) {
                out.append(u)
            }
        }
        return out
    }

    nonisolated static func listAudioFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where AudioMetaReader.isListed(url) {
            out.append(url)
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - Mac folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = macFolder
        panel.prompt = L("mac.choose")
        if panel.runModal() == .OK, let url = panel.url {
            macFolder = url
            UserDefaults.standard.set(url.path, forKey: "macFolder")
            scanMacFolder()
        }
    }

    func scanMacFolder() {
        scanTask?.cancel()
        macTracks = []
        macScanned = 0
        macScanning = true
        let folder = macFolder
        scanTask = Task {
            let urls = await Task.detached { AppModel.listAudioFiles(in: folder) }.value
            var results: [LocalTrack] = []
            results.reserveCapacity(urls.count)
            await withTaskGroup(of: LocalTrack.self) { group in
                var it = urls.makeIterator()
                for _ in 0..<8 {
                    guard let u = it.next() else { break }
                    group.addTask { LocalTrack(url: u, meta: await AudioMetaReader.read(url: u)) }
                }
                while let r = await group.next() {
                    if Task.isCancelled { group.cancelAll(); return }
                    results.append(r)
                    if let u = it.next() {
                        group.addTask { LocalTrack(url: u, meta: await AudioMetaReader.read(url: u)) }
                    }
                    if results.count % 100 == 0 {
                        let snapshot = results
                        await MainActor.run {
                            self.macScanned = snapshot.count
                            self.macTracks = snapshot
                        }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            self.macTracks = results
            self.macScanned = results.count
            self.macScanning = false
            self.refreshOnIPodFlags()
        }
    }

    // MARK: - Commit

    func requestCommit() {
        guard canCommit else { return }
        commitState = .idle
        showCommitSheet = true
        commit()
    }

    private func commit() {
        guard let s = session else { return }
        let pending = pendingAdds
        var changes = CommitChanges()
        changes.deletes = pendingDeletes
        changes.edits = pendingEdits
        changes.artwork = pendingArtwork.filter { !pendingDeletes.contains($0.key) }
        changes.fileGain = pendingFileGain.filter { !pendingDeletes.contains($0.key) }
        changes.fileGainUndo = pendingFileUndo.subtracting(pendingDeletes)
        changes.fileTags = fileTagWrites()
        let tagsIntoFiles = writesFileTags
        commitState = .running(pending.isEmpty ? .writingDatabase : .copying(done: 0, total: pending.count, name: ""))
        let base = changes
        let readCovers = artworkSupported
        Task.detached(priority: .userInitiated) {
            // Covers of new songs come from the files themselves unless the user chose otherwise.
            var changes = base
            var adds: [NewTrack] = []
            for a in pending {
                var art: Data?
                switch a.artwork {
                case .set(let d): art = d
                case .remove: art = nil
                case nil:
                    art = readCovers ? await AudioMetaReader.artworkData(url: a.url).flatMap { ArtworkPixels.normalized($0) } : nil
                }
                var tags: TagWrite?
                if tagsIntoFiles {
                    var w = TagWrite(edit: a.fileEdit,
                                     track: .init(number: a.meta.trackNumber, total: a.meta.trackCount),
                                     disc: .init(number: a.meta.discNumber, total: a.meta.discCount))
                    if let change = a.artwork { w.artwork = change }
                    if !w.isEmpty { tags = w }
                }
                adds.append(NewTrack(sourceURL: a.url, meta: a.meta, artwork: art, fileTags: tags,
                                     soundCheck: a.soundCheck, fileGain: a.fileGain))
            }
            changes.adds = adds
            let final = changes
            do {
                let report = try s.commit(final) { phase in
                    guard phase != .finished else { return }
                    Task { @MainActor in
                        guard self.commitState.isRunning else { return }
                        self.commitState = .running(phase)
                    }
                }
                let adb = s.artworkDB
                let supported = s.artworkSupported
                await MainActor.run {
                    self.tracks = s.tracks
                    self.artworkDB = adb
                    self.artworkSupported = supported
                    self.artVersion += 1
                    self.lastReport = report
                    self.clearPending()
                    self.capacity = s.device.capacity
                    self.commitState = .done
                    self.refreshOnIPodFlags()
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.commitState = .failed(message)
                }
            }
        }
    }
}
