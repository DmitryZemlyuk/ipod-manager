import Foundation

/// A song to identify.
public struct TagItem: Sendable, Equatable {
    public var id: UInt32
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    public var genre: String
    public var trackNumber: Int
    public var discNumber: Int
    public var durationMs: Int
    public var fileURL: URL

    public init(id: UInt32, title: String, artist: String, album: String, albumArtist: String, genre: String,
                trackNumber: Int, discNumber: Int, durationMs: Int, fileURL: URL) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.durationMs = durationMs
        self.fileURL = fileURL
    }
}

/// Tags found online for one song.
public struct TagProposal: Sendable, Equatable {
    public var title = ""
    public var artist = ""
    public var album = ""
    public var albumArtist = ""
    public var genre = ""
    public var year = 0
    public var trackNumber = 0
    public var trackCount = 0
    public var discNumber = 0
    public var discCount = 0
    public var compilation = false
    /// Fallback genre taken from the artist when the album has none.
    public var artistGenre = ""

    public init() {}
}

public struct ReleaseOption: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let artist: String
    public let year: Int?
    public let trackCount: Int
    public let format: String
    public let country: String
    public let coverage: Double
    public let releaseGroupID: String?
    public var artistID: String?
    public var proposals: [UInt32: TagProposal]
}

public struct TagGroup: Sendable, Identifiable {
    public enum Source: Sendable { case tags, fingerprint }
    public enum Status: Sendable { case found, choose, notFound }

    public let id: String
    public let itemIDs: [UInt32]
    public let title: String
    public let artist: String
    public var options: [ReleaseOption]
    public let source: Source
    public let confidence: Double

    public var status: Status {
        if options.isEmpty { return .notFound }
        if options.count > 1 { return .choose }
        return .found
    }
}

struct LooseSong {
    var item: TagItem
    /// The album group the song came from, when it was not found there.
    var albumKey: String?
}

public final class AutoTagger: @unchecked Sendable {
    let client: MusicBrainzClient
    let acoustIDKey: String?
    let fpcalc: URL?

    public init(client: MusicBrainzClient, acoustIDKey: String?, fpcalc: URL?) {
        self.client = client
        let key = acoustIDKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.acoustIDKey = key.isEmpty ? nil : key
        self.fpcalc = fpcalc
    }

    public var canFingerprint: Bool { acoustIDKey != nil && fpcalc != nil }

    /// Identifies songs album by album (few requests), then one by one for the rest.
    private let errorLock = NSLock()
    private var _errors: [String] = []

    /// Network/decoding failures seen so far (a failed request looks like "not found" otherwise).
    public var errors: [String] {
        errorLock.lock(); defer { errorLock.unlock() }
        return _errors
    }

    func attempt<T>(_ op: () async throws -> T) async -> T? {
        do {
            return try await op()
        } catch is CancellationError {
            return nil
        } catch let e as URLError where e.code == .cancelled {
            return nil
        } catch {
            errorLock.lock()
            _errors.append(error.localizedDescription)
            errorLock.unlock()
            return nil
        }
    }

    public func run(items: [TagItem],
                    progress: @Sendable (Int, Int) -> Void,
                    onGroup: @Sendable (TagGroup) -> Void = { _ in },
                    onStage: @Sendable (Stage) -> Void = { _ in }) async -> [TagGroup] {
        var albums: [String: [TagItem]] = [:]
        var albumOrder: [String] = []
        var singles: [TagItem] = []
        for item in items {
            if item.album.trimmingCharacters(in: .whitespaces).isEmpty || AutoTagger.looksUntagged(item) {
                singles.append(item)
                continue
            }
            let key = AutoTagger.albumKey(item)
            if albums[key] == nil { albumOrder.append(key) }
            albums[key, default: []].append(item)
        }
        // With only a few songs of an album, looking the album up costs a request per album and
        // tells little more than a song search does. Those songs are searched several per request
        // instead (their own album is still preferred among the results).
        var loose: [LooseSong] = []
        albumOrder.removeAll { key in
            guard let few = albums[key], few.count < AutoTagger.albumLookupMinimum else { return false }
            loose.append(contentsOf: few.map { LooseSong(item: $0, albumKey: key) })
            albums[key] = nil
            return true
        }

        var groups: [TagGroup] = []
        func emit(_ g: TagGroup) {
            groups.append(g)
            onGroup(g)
        }
        // Progress is counted in songs, so it matches the number of songs the user picked.
        let total = items.count
        var done = 0
        progress(done, total)

        // Albums: one search request covers several albums, then one lookup per album.
        for chunk in AutoTagger.chunks(albumOrder, of: 5) {
            if Task.isCancelled { break }
            var batch: MBBatch<MBRelease>?
            if chunk.count > 1 {
                let queries = chunk.compactMap { albums[$0]?.first }.map { (album: $0.album, artist: AutoTagger.mainArtist($0)) }
                batch = await attempt { try await self.client.searchReleasesBatch(queries) }
            }
            for key in chunk {
                if Task.isCancelled { break }
                let groupItems = albums[key] ?? []
                var candidates: [MBRelease]?
                if let batch, let first = groupItems.first {
                    let artist = AutoTagger.mainArtist(first)
                    let titled = batch.results.filter { AutoTagger.sameAlbum(first.album, $0.title ?? "") }
                    let mine = titled.filter { AutoTagger.artistMatches(artist, creditString($0.artistCredit)) }
                    if !mine.isEmpty {
                        candidates = mine
                    } else if !titled.isEmpty {
                        // The artist may be credited under another spelling. Safe to accept by title alone
                        // only when no other album of this request has the same name.
                        let clash = chunk.contains { other in
                            other != key && AutoTagger.sameAlbum(first.album, albums[other]?.first?.album ?? "")
                        }
                        if !clash { candidates = titled }
                    }
                }
                let (group, leftovers) = await identifyAlbum(groupItems, candidates: candidates,
                                                             skipPlainSearch: batch?.complete ?? false)
                if let group { emit(group) }
                loose.append(contentsOf: leftovers.map { LooseSong(item: $0, albumKey: key) })
                // Songs still to be searched one by one are counted when they are done.
                done += groupItems.count - leftovers.count
                progress(done, total)
            }
        }
        loose.append(contentsOf: singles.map { LooseSong(item: $0, albumKey: nil) })

        // Loose songs: those that need listening to go one by one, the rest several per request.
        var unknownByAlbum: [String: [TagItem]] = [:]
        var unknownOrder: [String] = []
        func finish(_ entry: LooseSong, _ g: TagGroup?) {
            if let g {
                emit(g)
            } else if let key = entry.albumKey {
                if unknownByAlbum[key] == nil { unknownOrder.append(key) }
                unknownByAlbum[key, default: []].append(entry.item)
            } else {
                emit(TagGroup(id: "u\(entry.item.id)", itemIDs: [entry.item.id],
                              title: entry.item.title.isEmpty ? entry.item.fileURL.lastPathComponent : entry.item.title,
                              artist: entry.item.artist, options: [], source: .tags, confidence: 0))
            }
            done += 1
            progress(done, total)
        }
        var searchable: [LooseSong] = []
        for entry in loose {
            if Task.isCancelled { break }
            let byTitle = !entry.item.title.isEmpty && !AutoTagger.isJunkTitle(entry.item.title)
            if byTitle, !(canFingerprint && AutoTagger.looksUntagged(entry.item)) {
                searchable.append(entry)
            } else {
                finish(entry, await identifySingle(entry.item))
            }
        }
        for chunk in AutoTagger.chunks(searchable, of: 8) {
            if Task.isCancelled { break }
            var batch: MBBatch<MBRecording>?
            if chunk.count > 1 {
                let queries = chunk.map { e in
                    (title: e.item.title, artist: AutoTagger.isPlaceholderArtist(e.item.artist) ? "" : e.item.artist,
                     durationMs: e.item.durationMs)
                }
                batch = await attempt { try await self.client.searchRecordingsBatch(queries) }
            }
            for entry in chunk {
                if Task.isCancelled { break }
                var mine: [MBRecording]?
                if let batch {
                    let titled = batch.results.filter { AutoTagger.titleSimilarity(entry.item.title, $0.title ?? "") >= 0.7 }
                    let found = titled.filter { rec in
                        AutoTagger.isPlaceholderArtist(entry.item.artist)
                            || AutoTagger.artistMatches(entry.item.artist, creditString(rec.artistCredit))
                    }
                    if !found.isEmpty {
                        mine = found
                    } else if !titled.isEmpty {
                        let clash = chunk.contains { other in
                            other.item.id != entry.item.id
                                && AutoTagger.titleSimilarity(entry.item.title, other.item.title) >= 0.7
                        }
                        if !clash { mine = titled }
                    }
                }
                finish(entry, await identifySingle(entry.item, candidates: mine, skipPlainSearch: batch?.complete ?? false))
            }
        }
        for key in unknownOrder {
            guard let unknown = unknownByAlbum[key], let first = unknown.first else { continue }
            emit(TagGroup(id: "u" + key, itemIDs: unknown.map { $0.id }, title: first.album,
                          artist: AutoTagger.mainArtist(first), options: [], source: .tags, confidence: 0))
        }

        // Genres and album years for songs found by a song search: many albums/artists per request.
        if !Task.isCancelled {
            onStage(.genres)
            for g in await enrich(groups) {
                if let i = groups.firstIndex(where: { $0.id == g.id }) { groups[i] = g }
                onGroup(g)
            }
        }
        return groups
    }

    /// Songs of an album are looked up as an album only from this many songs on.
    static let albumLookupMinimum = 4

    public enum Stage: Sendable { case searching, genres }

    /// Fills in missing genres (album first, then artist) and the album's original year.
    /// Returns the groups that changed.
    func enrich(_ groups: [TagGroup]) async -> [TagGroup] {
        var albumIDs: [String] = [], artistIDs: [String] = []
        var seenAlbums = Set<String>(), seenArtists = Set<String>()
        func needsGenre(_ o: ReleaseOption) -> Bool { o.proposals.values.contains { $0.genre.isEmpty } }
        for g in groups {
            for o in g.options where needsGenre(o) || g.id.hasPrefix("s") {
                if let id = o.releaseGroupID, seenAlbums.insert(id).inserted { albumIDs.append(id) }
            }
        }
        var albumInfo: [String: (genre: String?, year: Int?)] = [:]
        for chunk in AutoTagger.chunks(albumIDs, of: 40) {
            if Task.isCancelled { return [] }
            for rg in await attempt({ try await self.client.releaseGroups(ids: chunk) }) ?? [] {
                guard let id = rg.id else { continue }
                albumInfo[id] = (Genres.pick(rg.tags) ?? AutoTagger.topGenre(rg.genres), rg.firstReleaseYear)
            }
        }
        for g in groups {
            for o in g.options where needsGenre(o) && (o.releaseGroupID.flatMap { albumInfo[$0]?.genre } ?? nil) == nil {
                if let id = o.artistID, seenArtists.insert(id).inserted { artistIDs.append(id) }
            }
        }
        var artistGenre: [String: String] = [:]
        for chunk in AutoTagger.chunks(artistIDs, of: 40) {
            if Task.isCancelled { return [] }
            for a in await attempt({ try await self.client.artists(ids: chunk) }) ?? [] {
                if let id = a.id, let genre = Genres.pick(a.tags) ?? AutoTagger.topGenre(a.genres) { artistGenre[id] = genre }
            }
        }
        var changed: [TagGroup] = []
        for var g in groups {
            var touched = false
            for oi in g.options.indices {
                let o = g.options[oi]
                let info = o.releaseGroupID.flatMap { albumInfo[$0] }
                let genre = info?.genre ?? o.artistID.flatMap { artistGenre[$0] }
                var fixed = o.proposals
                for (k, p) in fixed {
                    if p.genre.isEmpty, let genre {
                        fixed[k]?.genre = genre
                        touched = true
                    }
                    // A song search names one particular edition; the album's first release gives the real year.
                    if g.id.hasPrefix("s"), let y = info?.year, y != p.year {
                        fixed[k]?.year = y
                        touched = true
                    }
                }
                g.options[oi].proposals = fixed
            }
            if touched { changed.append(g) }
        }
        return changed
    }

    // MARK: Album

    /// `candidates` come from a batched search (their scores are not comparable, so they are not used).
    /// `skipPlainSearch`: the batched search was complete, so repeating it for this album alone is pointless.
    func identifyAlbum(_ items: [TagItem], candidates given: [MBRelease]? = nil,
                       skipPlainSearch: Bool = false) async -> (TagGroup?, [TagItem]) {
        guard let first = items.first else { return (nil, []) }
        let artist = AutoTagger.mainArtist(first)
        var found: [MBRelease] = []
        var useScore = true
        if let given, !given.isEmpty {
            found = given
            useScore = false
        } else {
            if !skipPlainSearch {
                found = await attempt { try await self.client.searchReleases(album: first.album, artist: artist) } ?? []
            }
            let albumBase = AutoTagger.baseTitle(first.album)
            if found.filter({ ($0.score ?? 0) >= 60 }).isEmpty, albumBase != first.album, !albumBase.isEmpty {
                found = await attempt { try await self.client.searchReleases(album: albumBase, artist: artist) } ?? []
            }
        }
        // With only a few songs of an album on the iPod the track count says nothing:
        // prefer the official, earliest edition then.
        let useCount = items.count >= 4
        let candidates = found
            .filter { !useScore || ($0.score ?? 0) >= 60 }
            .sorted { a, b in
                if useScore, (a.score ?? 0) / 10 != (b.score ?? 0) / 10 { return (a.score ?? 0) > (b.score ?? 0) }
                let oa = a.status == "Official", ob = b.status == "Official"
                if oa != ob { return oa }
                let pa = a.releaseGroup?.primaryType == "Album", pb = b.releaseGroup?.primaryType == "Album"
                if pa != pb { return pa }
                if useCount {
                    let da = abs(a.totalTracks - items.count), db = abs(b.totalTracks - items.count)
                    if da != db { return da < db }
                }
                let ya = a.date.flatMap { $0.isEmpty ? nil : $0 } ?? "9999", yb = b.date.flatMap { $0.isEmpty ? nil : $0 } ?? "9999"
                return ya < yb
            }
            .prefix(3)

        var options: [ReleaseOption] = []
        var matchedBest: Set<UInt32> = []
        for c in candidates {
            if Task.isCancelled { break }
            guard let found = await attempt({ try await self.client.release(id: c.id) }), let full = found else { continue }
            let matches = AutoTagger.match(items: items, release: full)
            let coverage = Double(matches.count) / Double(items.count)
            guard coverage >= 0.5 else { continue }
            var proposals: [UInt32: TagProposal] = [:]
            for (id, m) in matches {
                proposals[id] = AutoTagger.proposal(release: full, medium: m.0, track: m.1)
            }
            options.append(AutoTagger.option(full, coverage: coverage, proposals: proposals))
            if coverage == 1, !useCount || full.totalTracks == items.count { break }
        }
        guard !options.isEmpty else { return (nil, items) }

        if useCount {
            options.sort { a, b in
                if abs(a.coverage - b.coverage) > 0.001 { return a.coverage > b.coverage }
                let da = abs(a.trackCount - items.count), db = abs(b.trackCount - items.count)
                if da != db { return da < db }
                return (a.year ?? 9999) < (b.year ?? 9999)
            }
            // Keep alternatives only when they are as good as the best one.
            let best = options[0]
            options = [best] + options.dropFirst().filter { abs($0.coverage - best.coverage) < 0.001 && $0.trackCount != best.trackCount }
        } else {
            // A few songs can't tell editions apart: take the top-ranked one (official, earliest).
            let top = options.map { $0.coverage }.max() ?? 0
            options = [options.first { $0.coverage >= top - 0.001 } ?? options[0]]
        }
        let best = options[0]

        // Albums without a genre of their own fall back to the artist's genre (it comes with the same answer).
        for oi in options.indices {
            var fixed = options[oi].proposals
            for (k, p) in fixed where p.genre.isEmpty && !p.artistGenre.isEmpty {
                fixed[k]?.genre = p.artistGenre
            }
            options[oi].proposals = fixed
        }

        matchedBest = Set(options[0].proposals.keys)
        let leftovers = items.filter { !matchedBest.contains($0.id) }
        let matchedIDs = items.map { $0.id }.filter { matchedBest.contains($0) }
        let group = TagGroup(id: "a" + AutoTagger.albumKey(first), itemIDs: matchedIDs, title: first.album,
                             artist: artist, options: options, source: .tags, confidence: best.coverage)
        return (group, leftovers)
    }

    // MARK: Single song

    func identifySingle(_ item: TagItem, candidates given: [MBRecording]? = nil,
                        skipPlainSearch: Bool = false) async -> TagGroup? {
        var recordings: [MBRecording] = []
        var source = TagGroup.Source.tags
        if AutoTagger.looksUntagged(item), canFingerprint, let fpcalc, let key = acoustIDKey {
            if let fp = try? AcoustID.fingerprint(url: item.fileURL, fpcalc: fpcalc),
               let ids = await attempt({ try await AcoustID.lookup(fp, apiKey: key) }), !ids.isEmpty {
                recordings = await attempt { try await self.client.recordings(ids: ids.prefix(5).map { $0.id }) } ?? []
                source = .fingerprint
                // Keep AcoustID's order.
                let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element.id, $0.offset) })
                recordings.sort { (order[$0.id] ?? 99) < (order[$1.id] ?? 99) }
            }
        }
        if recordings.isEmpty, !item.title.isEmpty, !AutoTagger.isJunkTitle(item.title) {
            let artist = AutoTagger.isPlaceholderArtist(item.artist) ? "" : item.artist
            if let given, !given.isEmpty {
                recordings = given
            } else if !skipPlainSearch {
                recordings = await attempt { try await self.client.searchRecordings(title: item.title, artist: artist,
                                                                                    durationMs: item.durationMs) } ?? []
                recordings = recordings.filter { ($0.score ?? 0) >= 80 }
            }
            let base = AutoTagger.baseTitle(item.title)
            if recordings.isEmpty, base != item.title, !base.isEmpty, !AutoTagger.isJunkTitle(base) {
                // "Song - From Some Soundtrack" → "Song"
                recordings = await attempt { try await self.client.searchRecordings(title: base, artist: artist,
                                                                                    durationMs: item.durationMs) } ?? []
                recordings = recordings.filter { ($0.score ?? 0) >= 80 }
            }
            source = .tags
        }
        var best: (rank: Int, date: String, rec: MBRecording, release: MBRelease, medium: MBMedium, track: MBTrack)?
        for rec in recordings {
            if item.durationMs > 0, let len = rec.length, abs(len - item.durationMs) > 7000 { continue }
            if source == .tags, !item.title.isEmpty,
               AutoTagger.titleSimilarity(item.title, rec.title ?? "") < 0.7 { continue }
            // A release that is the album the song already belongs to wins over everything else.
            let releases = rec.releases ?? []
            let own = releases.filter { AutoTagger.sameAlbum(item.album, $0.title ?? "") }
            guard let release = AutoTagger.preferredRelease(own.isEmpty ? releases : own),
                  let medium = release.media?.first,
                  let track = medium.track?.first else { continue }
            var rank = AutoTagger.releaseRank(release)
            if AutoTagger.sameAlbum(item.album, release.title ?? "") { rank += 16 }
            let date = (release.date ?? "").isEmpty ? "9999" : release.date!
            if best == nil || rank > best!.rank || (rank == best!.rank && date < best!.date) {
                best = (rank, date, rec, release, medium, track)
            }
            // Fingerprint results are ordered by confidence: take the first usable one.
            if source == .fingerprint { break }
        }
        if let b = best {
            var p = AutoTagger.proposal(release: b.release, medium: b.medium, track: b.track)
            if p.title.isEmpty { p.title = b.rec.title ?? "" }
            let recArtist = creditString(b.rec.artistCredit)
            if !recArtist.isEmpty { p.artist = recArtist }
            var opt = AutoTagger.option(b.release, coverage: 1, proposals: [item.id: p])
            if let id = b.rec.artistCredit?.first?.artist?.id { opt.artistID = id }
            return TagGroup(id: "s\(item.id)", itemIDs: [item.id],
                            title: item.title.isEmpty ? item.fileURL.lastPathComponent : item.title,
                            artist: item.artist, options: [opt], source: source,
                            confidence: Double(b.rec.score ?? 90) / 100)
        }
        return nil
    }

    // MARK: Helpers (pure, tested)

    static func mainArtist(_ i: TagItem) -> String {
        i.albumArtist.isEmpty ? i.artist : i.albumArtist
    }

    static func albumKey(_ i: TagItem) -> String {
        mainArtist(i).lowercased() + "\u{1F}" + i.album.lowercased()
    }

    public static func isJunkTitle(_ t: String) -> Bool {
        let n = normalize(t)
        if n.isEmpty { return true }
        let words = n.split(separator: " ")
        let junk: Set<String> = ["track", "трек", "дорожка", "audiotrack", "untitled", "unknown"]
        if words.allSatisfy({ Int($0) != nil }) { return true }
        if words.count <= 2, let w = words.first, junk.contains(String(w)) { return true }
        return false
    }

    public static func isPlaceholderArtist(_ a: String) -> Bool {
        let l = a.trimmingCharacters(in: .whitespaces).lowercased()
        return l.isEmpty || l.hasPrefix("unknown") || l == "неизвестный исполнитель" || l == "невідомий виконавець"
    }

    static func looksUntagged(_ i: TagItem) -> Bool {
        isPlaceholderArtist(i.artist) || isJunkTitle(i.title)
    }

    static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        // drop "(remastered 2011)", "[live]" etc.
        while let open = t.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            let closeChar: Character = t[open] == "(" ? ")" : "]"
            guard let close = t[open...].firstIndex(of: closeChar) else { break }
            t.removeSubrange(open...close)
        }
        if let dash = t.range(of: " - ") {
            let tail = t[dash.upperBound...]
            if tail.contains("remaster") || tail.contains("version") || tail.contains("edit") || tail.contains("mix") {
                t = String(t[..<dash.lowerBound])
            }
        }
        let mapped = t.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    /// Title without decorations: "Bye Bye Bye - From Deadpool (Remix) [feat. X]" → "Bye Bye Bye".
    static func baseTitle(_ s: String) -> String {
        var t = s
        while let open = t.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            let closeChar: Character = t[open] == "(" ? ")" : "]"
            guard let close = t[open...].firstIndex(of: closeChar) else { break }
            t.removeSubrange(open...close)
        }
        for sep in [" - ", " – ", " — "] {
            if let r = t.range(of: sep), !t[..<r.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty {
                t = String(t[..<r.lowerBound])
            }
        }
        for marker in [" feat. ", " feat ", " ft. ", " featuring "] {
            if let r = t.range(of: marker, options: .caseInsensitive) {
                t = String(t[..<r.lowerBound])
                break
            }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func chunks<T>(_ list: [T], of size: Int) -> [[T]] {
        stride(from: 0, to: list.count, by: size).map { Array(list[$0..<min($0 + size, list.count)]) }
    }

    /// Loose comparison of artist names ("The Beatles" / "Beatles", "A feat. B" / "A").
    static func artistMatches(_ wanted: String, _ credited: String) -> Bool {
        let a = normalize(wanted), b = normalize(credited)
        if a.isEmpty { return true }
        if b.isEmpty { return false }
        if a == b || similarity(wanted, credited) >= 0.8 { return true }
        func strip(_ s: String) -> String { s.hasPrefix("the ") ? String(s.dropFirst(4)) : s }
        let x = strip(a), y = strip(b)
        if x == y { return true }
        // one name inside the other, on word boundaries
        return (" " + x + " ").contains(" " + y + " ") || (" " + y + " ").contains(" " + x + " ")
    }

    /// True when both names are non-empty and name the same album (ignoring "Deluxe Edition" etc.).
    public static func sameAlbum(_ a: String, _ b: String) -> Bool {
        guard !a.trimmingCharacters(in: .whitespaces).isEmpty, !b.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return titleSimilarity(a, b) >= 0.85
    }

    /// Similarity that also accepts a match of the undecorated titles (slightly penalized).
    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let full = similarity(a, b)
        if full >= 0.95 { return full }
        let ba = baseTitle(a), bb = baseTitle(b)
        guard !ba.isEmpty, !bb.isEmpty, ba != a || bb != b else { return full }
        return max(full, similarity(ba, bb) * 0.95)
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(normalize(a)), y = Array(normalize(b))
        if x.isEmpty || y.isEmpty { return x == y ? 1 : 0 }
        if x == y { return 1 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Pairs songs with tracks of a release (greedy on best score).
    static func match(items: [TagItem], release: MBRelease) -> [UInt32: (MBMedium, MBTrack)] {
        var tracks: [(MBMedium, MBTrack)] = []
        for m in release.media ?? [] {
            for t in m.tracks ?? m.track ?? [] { tracks.append((m, t)) }
        }
        var scored: [(score: Double, item: Int, track: Int)] = []
        for (ii, item) in items.enumerated() {
            for (ti, pair) in tracks.enumerated() {
                let (m, t) = pair
                let title = t.title ?? t.recording?.title ?? ""
                var s: Double
                if isJunkTitle(item.title) {
                    s = 0
                } else {
                    s = titleSimilarity(item.title, title)
                }
                let samePosition = item.trackNumber > 0 && t.position == item.trackNumber
                    && (item.discNumber <= 1 || m.position == nil || m.position == item.discNumber)
                if samePosition { s += 0.25 }
                if item.durationMs > 0, let len = t.length ?? t.recording?.length, len > 0 {
                    let diff = abs(len - item.durationMs)
                    if diff <= 3000 { s += 0.15 } else if diff > 10000 { s -= 0.4 }
                    if isJunkTitle(item.title), samePosition, diff <= 3000 { s = 0.9 }
                }
                if s >= 0.75 { scored.append((s, ii, ti)) }
            }
        }
        scored.sort { $0.score > $1.score }
        var usedItems = Set<Int>(), usedTracks = Set<Int>()
        var out: [UInt32: (MBMedium, MBTrack)] = [:]
        for s in scored where !usedItems.contains(s.item) && !usedTracks.contains(s.track) {
            usedItems.insert(s.item)
            usedTracks.insert(s.track)
            out[items[s.item].id] = tracks[s.track]
        }
        return out
    }

    static func topGenre(_ genres: [MBGenre]?) -> String? {
        guard let g = genres?.max(by: { ($0.count ?? 0) < ($1.count ?? 0) }) else { return nil }
        return g.name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func proposal(release: MBRelease, medium: MBMedium, track: MBTrack) -> TagProposal {
        var p = TagProposal()
        p.title = track.title ?? track.recording?.title ?? ""
        let albumArtist = creditString(release.artistCredit)
        let trackArtist = creditString(track.artistCredit)
        p.artist = trackArtist.isEmpty ? albumArtist : trackArtist
        p.albumArtist = albumArtist
        p.album = release.title ?? ""
        // Year of the album itself, not of this particular reissue.
        p.year = release.releaseGroup?.firstReleaseYear ?? release.year ?? 0
        // Vinyl editions number their tracks "A1", "B2"…; the position inside the medium is always there.
        p.trackNumber = track.position ?? Int(track.number ?? "") ?? medium.trackOffset.map { $0 + 1 } ?? 0
        p.trackCount = medium.trackCount ?? medium.tracks?.count ?? 0
        p.discNumber = medium.position ?? 1
        p.discCount = max(release.media?.count ?? 1, 1)
        p.compilation = albumArtist.lowercased() == "various artists"
        p.genre = topGenre(release.genres) ?? topGenre(release.releaseGroup?.genres) ?? ""
        p.artistGenre = topGenre(release.artistCredit?.first?.artist?.genres) ?? ""
        return p
    }

    static func option(_ r: MBRelease, coverage: Double, proposals: [UInt32: TagProposal]) -> ReleaseOption {
        let formats = Array(Set((r.media ?? []).compactMap { $0.format })).sorted().joined(separator: "+")
        return ReleaseOption(id: r.id, title: r.title ?? "", artist: creditString(r.artistCredit), year: r.year,
                             trackCount: r.totalTracks, format: formats, country: r.country ?? "",
                             coverage: coverage, releaseGroupID: r.releaseGroup?.id,
                             artistID: r.artistCredit?.first?.artist?.id, proposals: proposals)
    }

    static func releaseRank(_ r: MBRelease) -> Int {
        var s = 0
        if r.status == "Official" { s += 4 }
        if r.releaseGroup?.primaryType == "Album" { s += 2 }
        if (r.releaseGroup?.secondaryTypes ?? []).isEmpty { s += 2 }
        if creditString(r.artistCredit).lowercased() != "various artists" { s += 1 }
        return s
    }

    /// Official studio album first, earliest date.
    static func preferredRelease(_ releases: [MBRelease]) -> MBRelease? {
        func rank(_ r: MBRelease) -> Int { releaseRank(r) }
        return releases.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra > rb }
            let da = (a.date ?? "").isEmpty ? "9999" : a.date!, db = (b.date ?? "").isEmpty ? "9999" : b.date!
            return da < db
        }.first
    }
}
