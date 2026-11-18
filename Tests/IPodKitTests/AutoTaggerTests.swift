import XCTest
@testable import IPodKit

final class AutoTaggerTests: XCTestCase {
    let releaseJSON = """
    {
      "id": "48117b82-8c4c-4c33-9d45-52ab6d29ea05",
      "title": "Discovery",
      "status": "Official",
      "date": "2001-03-12",
      "country": "GB",
      "artist-credit": [{"name": "Daft Punk", "joinphrase": ""}],
      "release-group": {"id": "rg-1", "primary-type": "Album", "secondary-types": [], "genres": [{"name": "french house", "count": 7}, {"name": "electronic", "count": 3}]},
      "media": [{
        "position": 1, "format": "CD", "track-count": 3,
        "tracks": [
          {"position": 1, "number": "1", "title": "One More Time", "length": 320357, "recording": {"id": "r1", "title": "One More Time", "length": 320357}},
          {"position": 2, "number": "2", "title": "Aerodynamic", "length": 212546, "recording": {"id": "r2", "title": "Aerodynamic", "length": 212546}},
          {"position": 3, "number": "3", "title": "Digital Love", "length": 301373, "recording": {"id": "r3", "title": "Digital Love", "length": 301373}}
        ]
      }]
    }
    """

    func item(_ id: UInt32, _ title: String, nr: Int = 0, ms: Int = 0) -> TagItem {
        TagItem(id: id, title: title, artist: "Daft Punk", album: "Discovery", albumArtist: "", genre: "",
                trackNumber: nr, discNumber: 0, durationMs: ms, fileURL: URL(fileURLWithPath: "/tmp/x.mp3"))
    }

    func testDecodeAndMatchRelease() throws {
        let release = try JSONDecoder().decode(MBRelease.self, from: Data(releaseJSON.utf8))
        XCTAssertEqual(release.year, 2001)
        XCTAssertEqual(release.totalTracks, 3)
        let items = [
            item(1, "Digital Love (Remastered)", ms: 301_000),
            item(2, "one more time"),
            item(3, "Track 02", nr: 2, ms: 212_000),
            item(4, "Something Else", ms: 100_000)
        ]
        let m = AutoTagger.match(items: items, release: release)
        XCTAssertEqual(m[1]?.1.title, "Digital Love")
        XCTAssertEqual(m[2]?.1.title, "One More Time")
        XCTAssertEqual(m[3]?.1.title, "Aerodynamic")
        XCTAssertNil(m[4])

        let p = AutoTagger.proposal(release: release, medium: m[3]!.0, track: m[3]!.1)
        XCTAssertEqual(p.title, "Aerodynamic")
        XCTAssertEqual(p.artist, "Daft Punk")
        XCTAssertEqual(p.albumArtist, "Daft Punk")
        XCTAssertEqual(p.album, "Discovery")
        XCTAssertEqual(p.year, 2001)
        XCTAssertEqual(p.trackNumber, 2)
        XCTAssertEqual(p.trackCount, 3)
        XCTAssertEqual(p.discNumber, 1)
        XCTAssertEqual(p.discCount, 1)
        XCTAssertEqual(p.genre, "French House")
        XCTAssertFalse(p.compilation)
    }

    func testRecordingSearchDecoding() throws {
        let json = """
        {"recordings": [{"id": "r9", "score": 100, "title": "Teardrop", "length": 330000,
          "artist-credit": [{"name": "Massive Attack"}],
          "releases": [
            {"id": "c1", "title": "Best Of", "status": "Official", "date": "2006",
             "release-group": {"primary-type": "Album", "secondary-types": ["Compilation"]},
             "media": [{"position": 1, "format": "CD", "track-count": 18, "track": [{"number": "5", "position": 5, "title": "Teardrop"}]}]},
            {"id": "m1", "title": "Mezzanine", "status": "Official", "date": "1998-04-20",
             "release-group": {"primary-type": "Album"},
             "media": [{"position": 1, "format": "CD", "track-count": 11, "track": [{"number": "3", "position": 3, "title": "Teardrop"}]}]}
          ]}]}
        """
        let r = try JSONDecoder().decode(MBRecordingSearch.self, from: Data(json.utf8))
        let rec = try XCTUnwrap(r.recordings?.first)
        let best = try XCTUnwrap(AutoTagger.preferredRelease(rec.releases ?? []))
        XCTAssertEqual(best.title, "Mezzanine")
        let medium = try XCTUnwrap(best.media?.first)
        let p = AutoTagger.proposal(release: best, medium: medium, track: try XCTUnwrap(medium.track?.first))
        XCTAssertEqual(p.trackNumber, 3)
        XCTAssertEqual(p.trackCount, 11)
        XCTAssertEqual(p.year, 1998)
    }

    func testHelpers() {
        XCTAssertTrue(AutoTagger.isJunkTitle("Track 03"))
        XCTAssertTrue(AutoTagger.isJunkTitle("03"))
        XCTAssertTrue(AutoTagger.isJunkTitle("Трек 3"))
        XCTAssertFalse(AutoTagger.isJunkTitle("Хочешь?"))
        XCTAssertEqual(AutoTagger.normalize("Hysteria (Live) [2004]"), "hysteria")
        XCTAssertEqual(AutoTagger.normalize("Ёлка – Прованс!"), "елка прованс")
        XCTAssertGreaterThan(AutoTagger.similarity("Do I Wanna Know?", "Do I Wanna Know"), 0.99)
        XCTAssertLessThan(AutoTagger.similarity("Teardrop", "Angel"), 0.5)
        XCTAssertEqual(AutoTagger.baseTitle("Bye Bye Bye - From Deadpool and Wolverine Soundtrack"), "Bye Bye Bye")
        XCTAssertEqual(AutoTagger.baseTitle("Stan (feat. Dido) [Explicit]"), "Stan")
        XCTAssertEqual(AutoTagger.baseTitle("Numb feat. Jay-Z"), "Numb")
        XCTAssertEqual(AutoTagger.baseTitle("Мама - Live"), "Мама")
        XCTAssertGreaterThan(AutoTagger.titleSimilarity("Bye Bye Bye - From Deadpool and Wolverine Soundtrack", "Bye Bye Bye"), 0.9)
        XCTAssertLessThan(AutoTagger.titleSimilarity("Angel - Live", "Teardrop"), 0.5)
        XCTAssertTrue(AutoTagger.artistMatches("Beatles", "The Beatles"))
        XCTAssertTrue(AutoTagger.artistMatches("*NSYNC", "*NSYNC"))
        XCTAssertTrue(AutoTagger.artistMatches("Daft Punk", "Daft Punk feat. Pharrell Williams"))
        XCTAssertTrue(AutoTagger.artistMatches("", "Anyone"))
        XCTAssertFalse(AutoTagger.artistMatches("Air", "Airbourne"))
        XCTAssertFalse(AutoTagger.artistMatches("Muse", "Moby"))
        XCTAssertEqual(AutoTagger.chunks([1, 2, 3, 4, 5], of: 2), [[1, 2], [3, 4], [5]])
        XCTAssertTrue(AutoTagger.sameAlbum("No Strings Attached", "No Strings Attached (Deluxe Edition)"))
        XCTAssertFalse(AutoTagger.sameAlbum("No Strings Attached", "Deadpool & Wolverine"))
        XCTAssertFalse(AutoTagger.sameAlbum("", "Discovery"))
        XCTAssertEqual(MusicBrainzClient.escape("AC/DC: \"Back\""), "AC\\/DC\\: \\\"Back\\\"")
    }
}
