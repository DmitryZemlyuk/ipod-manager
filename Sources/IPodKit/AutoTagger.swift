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
                    onGroup: @Sendable (TagGroup) -> Void = { _ in }) async -> [TagGroup] {
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

        var groups: [TagGroup] = []
        func emit(_ g: TagGroup) {
            groups.append(g)
            onGroup(g)
        }
        var total = albumOrder.count + singles.count
        var done = 0
        progress(done, total)

        for key in albumOrder {
            if Task.isCancelled { break }
            let groupItems = albums[key] ?? []
            let (group, leftovers) = await identifyAlbum(groupItems)
            if let group { emit(group) }
            if !leftovers.isEmpty {
                // Retry the rest one by one; anything still unknown stays together.
                total += leftovers.count
                var unknown: [TagItem] = []
                for item in leftovers {
                    if Task.isCancelled { break }
                    if let g = await identifySingle(item) { emit(g) } else { unknown.append(item) }
                    done += 1
                    progress(done, total)
                }
                if !unknown.isEmpty {
                    emit(TagGroup(id: "u" + key, itemIDs: unknown.map { $0.id }, title: unknown[0].album,
                                  artist: AutoTagger.mainArtist(unknown[0]), options: [], source: .tags,
                                  confidence: 0))
                }
            }
            done += 1
            progress(done, total)
        }

        for item in singles {
            if Task.isCancelled { break }
            if let g = await identifySingle(item) {
                emit(g)
            } else {
                emit(TagGroup(id: "u\(item.id)", itemIDs: [item.id],
                              title: item.title.isEmpty ? item.fileURL.lastPathComponent : item.title,
                              artist: item.artist, options: [], source: .tags, confidence: 0))
            }
            done += 1
            progress(done, total)
        }
        return groups
    }

    // MARK: Album

    func identifyAlbum(_ items: [TagItem]) async -> (TagGroup?, [TagItem]) {
        guard let first = items.first else { return (nil, []) }
        let artist = AutoTagger.mainArtist(first)
        var found = await attempt { try await self.client.searchReleases(album: first.album, artist: artist) } ?? []
        let albumBase = AutoTagger.baseTitle(first.album)
        if found.filter({ ($0.score ?? 0) >= 60 }).isEmpty, albumBase != first.album, !albumBase.isEmpty {
            found = await attempt { try await self.client.searchReleases(album: albumBase, artist: artist) } ?? []
        }
        // With only a few songs of an album on the iPod the track count says nothing:
        // prefer the official, earliest edition then.
        let useCount = items.count >= 4
        let candidates = found
            .filter { ($0.score ?? 0) >= 60 }
            .sorted { a, b in
                if (a.score ?? 0) / 10 != (b.score ?? 0) / 10 { return (a.score ?? 0) > (b.score ?? 0) }
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
            if coverage == 1, full.totalTracks == items.count { break }
        }
        guard !options.isEmpty else { return (nil, items) }

        options.sort { a, b in
            if abs(a.coverage - b.coverage) > 0.001 { return a.coverage > b.coverage }
            if useCount {
                let da = abs(a.trackCount - items.count), db = abs(b.trackCount - items.count)
                if da != db { return da < db }
            }
            return (a.year ?? 9999) < (b.year ?? 9999)
        }
        // Keep alternatives only when they are as good as the best one.
        let best = options[0]
        options = [best] + options.dropFirst().filter { abs($0.coverage - best.coverage) < 0.001 && $0.trackCount != best.trackCount }

        // Genre from the release group when the songs have none.
        if items.contains(where: { $0.genre.isEmpty }), options[0].proposals.values.allSatisfy({ $0.genre.isEmpty }),
           let rg = options[0].releaseGroupID {
            let genres = await attempt { try await self.client.releaseGroupGenres(id: rg) } ?? []
            if let g = AutoTagger.topGenre(genres) {
                for k in options[0].proposals.keys { options[0].proposals[k]?.genre = g }
            }
        }
        for oi in options.indices {
            for k in options[oi].proposals.keys where options[oi].proposals[k]?.genre.isEmpty == true {
                options[oi].proposals[k]?.genre = options[oi].proposals[k]?.artistGenre ?? ""
            }
        }

        matchedBest = Set(options[0].proposals.keys)
        let leftovers = items.filter { !matchedBest.contains($0.id) }
        let matchedIDs = items.map { $0.id }.filter { matchedBest.contains($0) }
        let group = TagGroup(id: "a" + AutoTagger.albumKey(first), itemIDs: matchedIDs, title: first.album,
                             artist: artist, options: options, source: .tags, confidence: best.coverage)
        return (group, leftovers)
    }

    // MARK: Single song

    func identifySingle(_ item: TagItem) async -> TagGroup? {
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
            recordings = await attempt { try await self.client.searchRecordings(title: item.title, artist: artist,
                                                                                durationMs: item.durationMs) } ?? []
            recordings = recordings.filter { ($0.score ?? 0) >= 80 }
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
            guard let release = AutoTagger.preferredRelease(rec.releases ?? []),
                  let medium = release.media?.first,
                  let track = medium.track?.first else { continue }
            let rank = AutoTagger.releaseRank(release)
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
            let opt = AutoTagger.option(b.release, coverage: 1, proposals: [item.id: p])
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
        p.trackNumber = track.position ?? Int(track.number ?? "") ?? 0
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
                             coverage: coverage, releaseGroupID: r.releaseGroup?.id, proposals: proposals)
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
