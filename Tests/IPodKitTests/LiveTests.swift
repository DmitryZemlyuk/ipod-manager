import XCTest
@testable import IPodKit

/// Network tests against the real services. Run with LIVE_TESTS=1.
final class LiveTests: XCTestCase {
    func item(_ id: UInt32, _ title: String, _ artist: String, _ album: String, ms: Int, nr: Int = 0) -> TagItem {
        TagItem(id: id, title: title, artist: artist, album: album, albumArtist: "", genre: "",
                trackNumber: nr, discNumber: 0, durationMs: ms, fileURL: URL(fileURLWithPath: "/tmp/x.mp3"))
    }

    func testLive() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_TESTS"] == "1" else { throw XCTSkip("live tests off") }
        let client = MusicBrainzClient(appVersion: "test")
        let q = "release:\"\(MusicBrainzClient.escape("No Strings Attached"))\" AND artist:\"\(MusicBrainzClient.escape("*NSYNC"))\""
        print("QUERY", q)
        do {
            let data = try await client.get("release", ["query": q, "limit": "10"])
            print("RAW release search:", String(decoding: data.prefix(1800), as: UTF8.self))
            let r = try JSONDecoder().decode(MBReleaseSearch.self, from: data)
            print("DECODED releases:", r.releases?.count ?? -1)
            for x in r.releases ?? [] { print("  ", x.id, x.score ?? -1, x.title ?? "", x.totalTracks, x.status ?? "", x.date ?? "", x.country ?? "") }
            if let first = r.releases?.first {
                let d2 = try await client.get("release/\(first.id)", ["inc": "recordings+artist-credits+release-groups+genres"])
                print("RAW release lookup:", String(decoding: d2.prefix(2500), as: UTF8.self))
                let full = try JSONDecoder().decode(MBRelease.self, from: d2)
                print("DECODED lookup tracks:", full.media?.first?.tracks?.map { $0.title ?? "?" } ?? [])
            }
        } catch {
            print("ERROR release:", error)
        }
        do {
            let q2 = "recording:\"Bye Bye Bye\" AND artist:\"\\*NSYNC\" AND dur:[195000 TO 205000]"
            let data = try await client.get("recording", ["query": q2, "limit": "3"])
            print("RAW recording search:", String(decoding: data.prefix(3000), as: UTF8.self))
            let r = try JSONDecoder().decode(MBRecordingSearch.self, from: data)
            print("DECODED recordings:", r.recordings?.count ?? -1)
        } catch {
            print("ERROR recording:", error)
        }
        let tagger = AutoTagger(client: client, acoustIDKey: nil, fpcalc: nil)
        let cases = [
            item(1, "Bye Bye Bye", "*NSYNC", "No Strings Attached", ms: 200_000, nr: 1),
            item(2, "It's Gonna Be Me", "*NSYNC", "No Strings Attached", ms: 192_000),
            item(3, "Teardrop", "Massive Attack", "Mezzanine", ms: 330_000),
            item(4, "Хочешь?", "Земфира", "Прости меня моя любовь", ms: 0),
            item(5, "One More Time", "Daft Punk", "", ms: 320_000)
        ]
        for c in cases {
            let groups = await tagger.run(items: [c], progress: { _, _ in })
            for g in groups {
                print("GROUP", c.title, "→", g.status, g.options.count, g.options.first?.title ?? "-", g.options.first?.year ?? 0,
                      g.options.first?.proposals[c.id].map { "\($0)" } ?? "")
            }
        }
    }
}
