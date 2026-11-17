import XCTest
@testable import IPodKit

final class ITunesDBTests: XCTestCase {
    func meta(_ title: String, _ artist: String, _ album: String, nr: Int) -> AudioMeta {
        var m = AudioMeta()
        m.title = title
        m.artist = artist
        m.album = album
        m.trackNumber = nr
        m.trackCount = 10
        m.year = 2001
        m.durationMs = 200_000
        m.sampleRate = 44100
        m.bitrateKbps = 256
        m.fileSize = 6_000_000
        m.kind = .mp3
        return m
    }

    func makeDB(count: Int) -> ITunesDB {
        var db = ITunesDB.makeEmpty(name: "Test iPod")
        var tracks = db.tracks
        for i in 0..<count {
            tracks.append(Track.make(meta: meta("Song \(i)", i % 2 == 0 ? "Zemfira" : "Air", "Album \(i % 3)", nr: i + 1),
                                     uniqueID: UInt32(100 + i),
                                     relativePath: "iPod_Control/Music/F0\(i % 10)/ABC\(i).mp3",
                                     fileSize: 6_000_000))
        }
        db.tracks = tracks
        db.rebuildMasterPlaylists()
        return db
    }

    func testEmptyDatabaseRoundTrip() throws {
        let db = ITunesDB.makeEmpty(name: "iPod")
        let bytes = db.serialize()
        XCTAssertEqual(bytes.tag(0), "mhbd")
        XCTAssertEqual(Int(bytes.u32(8)), bytes.count)
        let parsed = try ITunesDB.parse(bytes)
        XCTAssertEqual(parsed.datasets.count, 3)
        XCTAssertEqual(parsed.tracks.count, 0)
        XCTAssertEqual(parsed.serialize(), bytes)
    }

    func testTracksRoundTripIsByteIdentical() throws {
        let db = makeDB(count: 25)
        let bytes = db.serialize()
        let parsed = try ITunesDB.parse(bytes)
        XCTAssertEqual(parsed.tracks.count, 25)
        XCTAssertEqual(parsed.serialize(), bytes)

        let t = parsed.tracks[3]
        XCTAssertEqual(t.title, "Song 3")
        XCTAssertEqual(t.artist, "Air")
        XCTAssertEqual(t.album, "Album 0")
        XCTAssertEqual(t.trackNumber, 4)
        XCTAssertEqual(t.year, 2001)
        XCTAssertEqual(t.sampleRate, 44100)
        XCTAssertEqual(t.durationMs, 200_000)
        XCTAssertEqual(t.mediaType, 1)
        XCTAssertEqual(t.relativePath, "iPod_Control/Music/F03/ABC3.mp3")
        XCTAssertEqual(t.location, ":iPod_Control:Music:F03:ABC3.mp3")
        XCTAssertEqual(t.header.count, Track.defaultHeaderLength)
        // "MP3 " marker stored little-endian
        XCTAssertEqual(Array(t.header[24..<28]), [0x20, 0x33, 0x50, 0x4D])
    }

    func testMasterPlaylistsContainAllTracksWithIndex() throws {
        let db = try ITunesDB.parse(makeDB(count: 12).serialize())
        let lists = db.datasets.compactMap { $0.playlistList }
        XCTAssertEqual(lists.count, 2)
        for list in lists {
            let master = try XCTUnwrap(list.playlists.first { $0.isMaster })
            XCTAssertEqual(master.items.map { $0.trackID }, db.tracks.map { $0.uniqueID })
            XCTAssertEqual(master.mhods.filter { $0.type == 52 }.count, LibraryIndex.Kind.allCases.count)
            XCTAssertEqual(master.mhods.filter { $0.type == 53 }.count, LibraryIndex.Kind.allCases.count)
            for m in master.mhods where m.type == 52 {
                XCTAssertEqual(Int(m.raw.u32(28)), 12)
                XCTAssertEqual(m.raw.count, 72 + 4 * 12)
                let indices = (0..<12).map { Int(m.raw.u32(72 + 4 * $0)) }
                XCTAssertEqual(Set(indices), Set(0..<12))
            }
            for m in master.mhods where m.type == 53 {
                let runs = Int(m.raw.u32(28))
                let total = (0..<runs).reduce(0) { $0 + Int(m.raw.u32(40 + 12 * $1 + 8)) }
                XCTAssertEqual(total, 12)
            }
            // positions
            for (i, item) in master.items.enumerated() {
                XCTAssertEqual(item.mhods.first?.type, 100)
                XCTAssertEqual(item.mhods.first?.raw.u32(24), UInt32(i))
            }
        }
    }

    func testTitleIndexIsSorted() throws {
        let db = makeDB(count: 12)
        let master = db.datasets.compactMap { $0.playlistList }.first!.playlists.first { $0.isMaster }!
        let titleIndex = master.mhods.first { $0.type == 52 && $0.raw.u32(24) == 3 }!
        let titles = (0..<12).map { db.tracks[Int(titleIndex.raw.u32(72 + 4 * $0))].title }
        XCTAssertEqual(titles, titles.sorted { $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedAscending })
    }

    func testRemoveTracksAlsoRemovesPlaylistItems() throws {
        var db = makeDB(count: 6)
        db.removeTracks(ids: [101, 103])
        db.rebuildMasterPlaylists()
        let parsed = try ITunesDB.parse(db.serialize())
        XCTAssertEqual(parsed.tracks.map { $0.uniqueID }, [100, 102, 104, 105])
        for list in parsed.datasets.compactMap({ $0.playlistList }) {
            for pl in list.playlists {
                XCTAssertFalse(pl.items.contains { $0.trackID == 101 || $0.trackID == 103 })
            }
        }
    }

    func testEditsAndUnicodeStrings() throws {
        var db = makeDB(count: 2)
        var e = TrackEdit()
        e.title = "Хочешь?"
        e.artist = "Земфира"
        e.genre = ""
        e.soundCheck = 1585
        var tracks = db.tracks
        e.apply(to: &tracks[0])
        db.tracks = tracks
        let parsed = try ITunesDB.parse(db.serialize())
        XCTAssertEqual(parsed.tracks[0].title, "Хочешь?")
        XCTAssertEqual(parsed.tracks[0].artist, "Земфира")
        XCTAssertEqual(parsed.tracks[0].genre, "")
        XCTAssertNil(parsed.tracks[0].string(5))
        XCTAssertEqual(parsed.tracks[0].soundCheck, 1585)
        XCTAssertEqual(parsed.tracks[1].title, "Song 1")
    }

    func testUnknownDatasetIsPreserved() throws {
        var db = makeDB(count: 3)
        var h = Bytes(repeating: 0, count: 0x60)
        h.setTag(0, "mhsd")
        h.setU32(12, 4)
        var body = Bytes()
        body.appendTag("mhla")
        body.appendU32(0x5C)
        body.appendU32(0)
        body.appendZeros(0x5C - 12)
        db.datasets.append(DataSet(header: h, trackList: nil, playlistList: nil, rawBody: body))
        let bytes = db.serialize()
        let parsed = try ITunesDB.parse(bytes)
        XCTAssertEqual(parsed.datasets.count, 4)
        XCTAssertEqual(parsed.datasets[3].rawBody, body)
        XCTAssertEqual(parsed.serialize(), bytes)
    }

    func testPlayCountsMerge() throws {
        var tracks = makeDB(count: 2).tracks
        var d = Bytes()
        d.appendTag("mhdp")
        d.appendU32(0x60)
        d.appendU32(0x1C)
        d.appendU32(2)
        d.appendZeros(0x60 - 16)
        for (pc, rating) in [(UInt32(3), UInt32(80)), (UInt32(0), UInt32(0))] {
            d.appendU32(pc); d.appendU32(3_000_000_000); d.appendU32(0); d.appendU32(rating)
            d.appendU32(0); d.appendU32(1); d.appendU32(0)
        }
        let entries = try XCTUnwrap(PlayCounts.parse(d))
        PlayCounts.merge(entries, into: &tracks)
        XCTAssertEqual(tracks[0].playCount, 3)
        XCTAssertEqual(tracks[0].rating, 80)
        XCTAssertEqual(tracks[1].playCount, 0)
        XCTAssertEqual(tracks[1].skipCount, 1)
    }

    func testOldStylePlaylistItemsWithDetachedMHOD() throws {
        // mhip whose total length excludes its mhod (older iTunes versions).
        var db = makeDB(count: 2)
        let bytes = db.serialize()
        var parsed = try ITunesDB.parse(bytes)
        // Simulate: header claims tl == hl
        for di in parsed.datasets.indices where parsed.datasets[di].playlistList != nil {
            for pi in parsed.datasets[di].playlistList!.playlists.indices {
                for ii in parsed.datasets[di].playlistList!.playlists[pi].items.indices {
                    parsed.datasets[di].playlistList!.playlists[pi].items[ii].header.setU32(8, 0x4C)
                }
            }
        }
        // Write manually with stale tl values.
        var out = Bytes()
        for ds in parsed.datasets { out.append(contentsOf: ds.serializeKeepingItemLengths()) }
        var h = parsed.header
        h.setU32(8, UInt32(h.count + out.count))
        let raw = h + out
        let again = try ITunesDB.parse(raw)
        XCTAssertEqual(again.tracks.count, 2)
        XCTAssertEqual(again.datasets.compactMap { $0.playlistList }.first?.playlists.first?.items.count, 2)
        db = again
        XCTAssertEqual(db.tracks.count, 2)
    }

    func testFileNaming() {
        var t = Track.make(meta: meta("A/B: C", "Air", "Moon Safari", nr: 3), uniqueID: 1,
                           relativePath: "iPod_Control/Music/F00/X.mp3", fileSize: 1)
        XCTAssertEqual(ExportLayout.artistAlbumTrack.relativePath(for: t, fileExtension: "mp3"),
                       "Air/Moon Safari/03 A-B- C.mp3")
        t.albumArtist = "Various"
        XCTAssertEqual(ExportLayout.flat.relativePath(for: t, fileExtension: "mp3"), "Air – A-B- C.mp3")
    }
}

extension DataSet {
    /// Test helper: serialize without fixing mhip total lengths.
    func serializeKeepingItemLengths() -> Bytes {
        guard let pl = playlistList else { return serialize() }
        var body = pl.header
        body.setU32(8, UInt32(pl.playlists.count))
        for p in pl.playlists {
            var pb = Bytes()
            for m in p.mhods { pb.append(contentsOf: m.raw) }
            for i in p.items {
                pb.append(contentsOf: i.header)
                for m in i.mhods { pb.append(contentsOf: m.raw) }
            }
            var ph = p.header
            ph.setU32(8, UInt32(ph.count + pb.count))
            ph.setU32(12, UInt32(p.mhods.count))
            ph.setU32(16, UInt32(p.items.count))
            body.append(contentsOf: ph + pb)
        }
        var h = header
        h.setU32(8, UInt32(h.count + body.count))
        return h + body
    }
}
