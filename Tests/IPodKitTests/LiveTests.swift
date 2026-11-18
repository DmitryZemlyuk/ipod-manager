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
            item(1, "Bye Bye Bye - From Deadpool and Wolverine Soundtrack", "*NSYNC", "No Strings Attached", ms: 200_000),
            item(6, "Bye Bye Bye - From Deadpool and Wolverine Soundtrack", "*NSYNC", "", ms: 200_000),
            item(2, "It's Gonna Be Me", "*NSYNC", "No Strings Attached", ms: 192_000),
            item(3, "Teardrop", "Massive Attack", "Mezzanine", ms: 330_000),
            item(4, "Хочешь?", "Земфира", "Прости меня моя любовь", ms: 0),
            item(5, "One More Time", "Daft Punk", "", ms: 320_000)
        ]
        // everything in one run: searches are batched
        do {
            let c2 = MusicBrainzClient(appVersion: "test")
            let t2 = AutoTagger(client: c2, acoustIDKey: nil, fpcalc: nil)
            let more = [
                item(10, "Aerodynamic", "Daft Punk", "Discovery", ms: 212_000), item(11, "Digital Love", "Daft Punk", "Discovery", ms: 301_000),
                item(12, "Angel", "Massive Attack", "Mezzanine", ms: 379_000),
                item(13, "Do I Wanna Know?", "Arctic Monkeys", "AM", ms: 272_000),
                item(14, "Feel Good Inc.", "Gorillaz", "", ms: 221_000), item(15, "Intro", "The xx", "", ms: 127_000),
                item(16, "Hysteria", "Muse", "", ms: 227_000), item(17, "Definitely Not A Real Song Qzx", "Nobody Qzx", "", ms: 100_000)
            ]
            let start = Date()
            final class Box: @unchecked Sendable {
                let lock = NSLock()
                var values: [(Int, Int)] = []
            }
            let box = Box()
            let all = cases + more
            let groups = await t2.run(items: all, progress: { d, t in box.lock.lock(); box.values.append((d, t)); box.lock.unlock() })
            // Progress is in songs: the total never changes, the count only grows and ends at every song.
            XCTAssertTrue(box.values.allSatisfy { $0.1 == all.count }, "total changed: \(box.values)")
            XCTAssertEqual(box.values.last?.0, all.count)
            XCTAssertEqual(box.values.map { $0.0 }, box.values.map { $0.0 }.sorted())
            XCTAssertEqual(groups.reduce(0) { $0 + $1.itemIDs.count }, all.count)
            let requests = await c2.requestCount
            print("BATCH requests", requests, "seconds", Int(Date().timeIntervalSince(start)), "groups", groups.count, "errors", t2.errors)
            for g in groups {
                print("BATCHGROUP", g.title, "|", g.artist, "→", g.status, g.itemIDs, g.options.first.map { "\($0.title) \($0.year ?? 0) tracks \($0.trackCount)" } ?? "-",
                      g.options.first?.proposals.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.title)/\($0.value.album)" } ?? [])
            }
        }
        for c in cases {
            let groups = await tagger.run(items: [c], progress: { _, _ in })
            if !tagger.errors.isEmpty { print("ERRORS", tagger.errors) }
            for g in groups {
                print("GROUP", c.title, "→", g.status, g.options.count, g.options.first?.title ?? "-", g.options.first?.year ?? 0,
                      g.options.first?.proposals[c.id].map { "\($0)" } ?? "")
            }
        }
    }

    /// Needs `lame` (brew install lame): encodes real MP3s and checks that the measured loudness
    /// moves by exactly the requested number of 1.5 dB steps and that undo is bit-exact.
    func testRealMP3Gain() throws {
        guard ProcessInfo.processInfo.environment["LIVE_TESTS"] == "1" else { throw XCTSkip("live tests off") }
        let lame = ["/opt/homebrew/bin/lame", "/usr/local/bin/lame"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let lame else { throw XCTSkip("lame not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ipm-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 6 s stereo WAV: two sines at -12 dBFS, 44.1 kHz, 16 bit
        let rate = 44100, n = rate * 6
        var pcm = Data(capacity: n * 4)
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            let v = 0.25 * (0.6 * sin(2 * .pi * 440 * t) + 0.4 * sin(2 * .pi * 1500 * t))
            let s = Int16(max(-1, min(1, v)) * 32767)
            for _ in 0..<2 { pcm.append(UInt8(truncatingIfNeeded: s)); pcm.append(UInt8(truncatingIfNeeded: s >> 8)) }
        }
        var wav = Bytes()
        wav.append(contentsOf: Array("RIFF".utf8)); wav.appendU32(UInt32(36 + pcm.count)); wav.append(contentsOf: Array("WAVEfmt ".utf8))
        wav.appendU32(16); wav.append(contentsOf: [1, 0, 2, 0]); wav.appendU32(UInt32(rate)); wav.appendU32(UInt32(rate * 4))
        wav.append(contentsOf: [4, 0, 16, 0]); wav.append(contentsOf: Array("data".utf8)); wav.appendU32(UInt32(pcm.count))
        let wavURL = dir.appendingPathComponent("in.wav")
        try (Data(wav) + pcm).write(to: wavURL)

        let variants: [(String, [String])] = [
            ("cbr-stereo", ["-b", "128"]),
            ("vbr-joint", ["-V", "2"]),
            ("crc", ["-b", "160", "-p"]),
            ("mono", ["-b", "96", "-m", "m"]),
            ("mpeg2", ["-b", "64", "--resample", "22.05"]),
            ("mpeg25-mono", ["-b", "32", "--resample", "11.025", "-m", "m"]),
            ("id3", ["-b", "128", "--add-id3v2", "--tt", "Title", "--ta", "Artist", "--id3v1-only"])
        ]
        for (name, args) in variants {
            let mp3 = dir.appendingPathComponent(name + ".mp3")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: lame)
            p.arguments = ["--quiet"] + args + [wavURL.path, mp3.path]
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, name)
            let original = Bytes(try Data(contentsOf: mp3))
            // Core Audio refuses some variants (CRC-protected frames); those get the structural checks only.
            let before = try? Loudness.analyze(url: mp3).integrated
            if before == nil { print("MP3GAIN", name, "not decodable by Core Audio, structural checks only") }
            for steps in [-4, 3] {
                let out = dir.appendingPathComponent("\(name)-\(steps).mp3")
                let (changed, result) = try MP3Gain.apply(to: original, steps: steps)
                try Data(changed).write(to: out)
                XCTAssertGreaterThan(result.frames, 100, name)
                if let before {
                    let after = try Loudness.analyze(url: out).integrated
                    print("MP3GAIN", name, "steps", steps, "frames", result.frames, "LUFS", before, "→", after, "delta", after - before)
                    XCTAssertEqual(after - before, Double(steps) * 1.5, accuracy: 0.15, "\(name) \(steps)")
                } else {
                    let t = MP3Gain.tail(changed)
                    for f in try MP3Gain.frames(changed, audioEnd: t.audioEnd) where f.hasCRC {
                        let crc = MP3Gain.crc16(changed, [(f.offset + 2)..<(f.offset + 4), f.sideInfo..<(f.sideInfo + f.sideLength)])
                        XCTAssertEqual(UInt16(changed[f.offset + 4]) << 8 | UInt16(changed[f.offset + 5]), crc, name)
                    }
                    // lame's own CRCs must verify with the same routine, otherwise the check above proves nothing
                    let t0 = MP3Gain.tail(original)
                    let crcFrames = try MP3Gain.frames(original, audioEnd: t0.audioEnd).filter { $0.hasCRC }
                    print("MP3GAIN", name, "steps", steps, "frames", result.frames, "crc frames", crcFrames.count)
                    for f in crcFrames.prefix(50) {
                        let crc = MP3Gain.crc16(original, [(f.offset + 2)..<(f.offset + 4), f.sideInfo..<(f.sideInfo + f.sideLength)])
                        XCTAssertEqual(UInt16(original[f.offset + 4]) << 8 | UInt16(original[f.offset + 5]), crc, "lame crc \(name)")
                    }
                }
                XCTAssertEqual(try XCTUnwrap(MP3Gain.undo(changed)), original, "\(name) undo")
            }
        }
    }

    /// Probe: do search results carry tags for release groups and artists?
    func testProbeTags() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_TESTS"] == "1" else { throw XCTSkip("live tests off") }
        let client = MusicBrainzClient(appVersion: "test")
        let rec = try await client.get("recording", ["query": "recording:\"Teardrop\" AND artist:\"Massive Attack\"", "limit": "2"])
        let text = String(decoding: rec, as: UTF8.self)
        print("PROBE recording:", text.prefix(1500))
        func first(_ pattern: String) -> String? {
            guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
            let m = String(text[r])
            return m.range(of: "[0-9a-f]{8}-[0-9a-f-]{27}", options: .regularExpression).map { String(m[$0]) }
        }
        let rg = first("\"release-group\":\\{\"id\":\"[0-9a-f-]{36}\"")
        let artist = first("\"artist\":\\{\"id\":\"[0-9a-f-]{36}\"")
        print("PROBE ids", rg ?? "-", artist ?? "-")
        if let rg {
            let d = try await client.get("release-group", ["query": "rgid:(\(rg) OR 00000000-0000-0000-0000-000000000000)", "limit": "5"])
            print("PROBE rg:", String(decoding: d, as: UTF8.self).prefix(1800))
        }
        if let artist {
            let d = try await client.get("artist", ["query": "arid:(\(artist))", "limit": "5"])
            print("PROBE artist:", String(decoding: d, as: UTF8.self).prefix(1800))
        }
    }
}
