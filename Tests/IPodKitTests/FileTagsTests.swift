import XCTest
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import IPodKit

final class FileTagsTests: XCTestCase {
    // MARK: helpers

    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ipm-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func jpeg(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, size: Int = 300) -> Data {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Fake MPEG-1 Layer III frames (valid headers, arbitrary payload).
    func fakeAudio(frames: Int = 6) -> Bytes {
        var out = Bytes()
        for n in 0..<frames {
            var f = Bytes(repeating: 0, count: 417)
            f[0] = 0xFF; f[1] = 0xFB; f[2] = 0x90; f[3] = 0x00
            for i in 4..<417 { f[i] = UInt8(truncatingIfNeeded: i &* 13 &+ n) }
            out.append(contentsOf: f)
        }
        return out
    }

    func wav(seconds: Double = 3) throws -> URL {
        let rate = 44100, n = Int(Double(rate) * seconds)
        var pcm = Data(capacity: n * 4)
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            let s = Int16(0.3 * sin(2 * .pi * 440 * t) * 32767)
            for _ in 0..<2 { pcm.append(UInt8(truncatingIfNeeded: s)); pcm.append(UInt8(truncatingIfNeeded: s >> 8)) }
        }
        var h = Bytes()
        h.append(contentsOf: Array("RIFF".utf8)); h.appendU32(UInt32(36 + pcm.count)); h.append(contentsOf: Array("WAVEfmt ".utf8))
        h.appendU32(16); h.append(contentsOf: [1, 0, 2, 0]); h.appendU32(UInt32(rate)); h.appendU32(UInt32(rate * 4))
        h.append(contentsOf: [4, 0, 16, 0]); h.append(contentsOf: Array("data".utf8)); h.appendU32(UInt32(pcm.count))
        let url = dir.appendingPathComponent("in.wav")
        try (Data(h) + pcm).write(to: url)
        return url
    }

    func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(tool) \(args)")
    }

    func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        let data = try XCTUnwrap(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: data[0], count: n))
    }

    var fullWrite: TagWrite {
        var w = TagWrite()
        w.title = "Хочешь?"
        w.artist = "Земфира"
        w.album = "Прости меня моя любовь"
        w.albumArtist = "Земфира"
        w.genre = "Pop Rock"
        w.composer = "Земфира Рамазанова"
        w.year = 2000
        w.track = .init(number: 3, total: 13)
        w.disc = .init(number: 1, total: 2)
        w.compilation = true
        w.artwork = .set(jpeg(1, 0, 0))
        return w
    }

    func assertTags(_ url: URL, cover: Data?, file: StaticString = #filePath, line: UInt = #line) async {
        let m = await AudioMetaReader.read(url: url)
        XCTAssertEqual(m.title, "Хочешь?", file: file, line: line)
        XCTAssertEqual(m.artist, "Земфира", file: file, line: line)
        XCTAssertEqual(m.album, "Прости меня моя любовь", file: file, line: line)
        XCTAssertEqual(m.albumArtist, "Земфира", file: file, line: line)
        XCTAssertEqual(m.genre, "Pop Rock", file: file, line: line)
        XCTAssertEqual(m.composer, "Земфира Рамазанова", file: file, line: line)
        XCTAssertEqual(m.year, 2000, file: file, line: line)
        XCTAssertEqual(m.trackNumber, 3, file: file, line: line)
        XCTAssertEqual(m.trackCount, 13, file: file, line: line)
        XCTAssertEqual(m.discNumber, 1, file: file, line: line)
        XCTAssertEqual(m.discCount, 2, file: file, line: line)
        XCTAssertTrue(m.compilation, file: file, line: line)
        let art = await AudioMetaReader.artworkData(url: url)
        XCTAssertEqual(art, cover, file: file, line: line)
    }

    // MARK: ID3v2

    func testID3NewTagThenInPlaceEdit() throws {
        let audio = fakeAudio()
        let plan1 = try XCTUnwrap(ID3v2.plan(fullWrite, file: audio))
        guard case .rewrite(let v1) = plan1 else { return XCTFail("expected a rewrite") }
        let (tag, length) = try ID3v2.parse(v1)
        XCTAssertEqual(tag?.version, 3)
        XCTAssertEqual(Array(v1[length...]), audio)
        let byID = Dictionary(grouping: tag?.frames ?? [], by: { $0.id })
        XCTAssertEqual(byID["TIT2"].map { ID3v2.text($0[0]) }, "Хочешь?")
        XCTAssertEqual(byID["TCON"].map { ID3v2.text($0[0]) }, "Pop Rock")
        XCTAssertEqual(byID["TCON"]?[0].data.first, 0)      // Latin-1 when possible
        XCTAssertEqual(byID["TIT2"]?[0].data.first, 1)      // UTF-16 otherwise
        XCTAssertEqual(byID["TRCK"].map { ID3v2.text($0[0]) }, "3/13")
        XCTAssertEqual(byID["TPOS"].map { ID3v2.text($0[0]) }, "1/2")
        XCTAssertEqual(byID["TYER"].map { ID3v2.text($0[0]) }, "2000")
        XCTAssertEqual(byID["TCMP"].map { ID3v2.text($0[0]) }, "1")
        XCTAssertEqual(byID["APIC"]?.count, 1)

        // same values again: nothing to do
        XCTAssertNil(try ID3v2.plan(fullWrite, file: v1))

        // a small edit fits into the padding and keeps the file size
        var w = TagWrite()
        w.title = "Another title"
        w.compilation = false
        w.year = 0
        let plan2 = try XCTUnwrap(ID3v2.plan(w, file: v1))
        guard case .patch(let offset, let bytes) = plan2 else { return XCTFail("expected an in-place patch") }
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(bytes.count, length)
        let v2 = FileTags.apply(plan2, to: v1)
        XCTAssertEqual(v2.count, v1.count)
        XCTAssertEqual(Array(v2[length...]), audio)
        let frames2 = try XCTUnwrap(ID3v2.parse(v2).0).frames
        XCTAssertEqual(frames2.first { $0.id == "TIT2" }.map { ID3v2.text($0) }, "Another title")
        XCTAssertNil(frames2.first { $0.id == "TCMP" })
        XCTAssertNil(frames2.first { $0.id == "TYER" })
        XCTAssertNotNil(frames2.first { $0.id == "APIC" })

        var r = TagWrite()
        r.artwork = .remove
        let v3 = FileTags.apply(try XCTUnwrap(ID3v2.plan(r, file: v2)), to: v2)
        XCTAssertNil(try XCTUnwrap(ID3v2.parse(v3).0).frames.first { $0.id == "APIC" })
        XCTAssertThrowsError(try ID3v2.plan(w, file: Bytes(repeating: 7, count: 4000)))
    }

    func testID3v24TagIsKeptAsV24() throws {
        // v2.4 tag: TIT2 (UTF-8), an unknown frame, an unsynchronised frame, a footer-less header
        var frames = Bytes()
        func add(_ id: String, _ data: Bytes, flags: Int = 0) {
            frames.append(contentsOf: Array(id.utf8))
            ID3v2.appendSyncsafe(&frames, data.count)
            frames.appendBE16(flags)
            frames.append(contentsOf: data)
        }
        add("TIT2", [3] + Array("Old".utf8))
        add("XABC", [1, 2, 3, 4])
        add("TDRC", [3] + Array("1999-05-10".utf8))
        add("PRIV", [0x41, 0xFF, 0x00, 0xE0, 0x42], flags: 0x0002)     // FF 00 E0 → FF E0 after de-unsync
        var tagBytes: Bytes = [0x49, 0x44, 0x33, 4, 0, 0]
        ID3v2.appendSyncsafe(&tagBytes, frames.count + 50)
        tagBytes.append(contentsOf: frames)
        tagBytes.appendZeros(50)
        let file = tagBytes + fakeAudio()

        var w = TagWrite()
        w.title = "Новое"
        w.year = 1999
        w.track = .init(number: 7, total: 0)
        let out = FileTags.apply(try XCTUnwrap(ID3v2.plan(w, file: file)), to: file)
        let (tag, length) = try ID3v2.parse(out)
        XCTAssertEqual(tag?.version, 4)
        XCTAssertEqual(Array(out[length...]), fakeAudio())
        let f = try XCTUnwrap(tag).frames
        XCTAssertEqual(f.first { $0.id == "TIT2" }.map { ID3v2.text($0) }, "Новое")
        XCTAssertEqual(f.first { $0.id == "TIT2" }?.data.first, 3)
        XCTAssertEqual(f.first { $0.id == "XABC" }?.data, [1, 2, 3, 4])
        XCTAssertEqual(f.first { $0.id == "TDRC" }.map { ID3v2.text($0) }, "1999-05-10")   // full date kept
        XCTAssertEqual(f.first { $0.id == "PRIV" }?.data, [0x41, 0xFF, 0xE0, 0x42])
        XCTAssertEqual(f.first { $0.id == "PRIV" }?.flags, 0)
        XCTAssertEqual(f.first { $0.id == "TRCK" }.map { ID3v2.text($0) }, "7")
    }

    func testID3v22IsUpgraded() throws {
        var frames = Bytes()
        func add(_ id: String, _ data: Bytes) {
            frames.append(contentsOf: Array(id.utf8))
            frames.append(contentsOf: [UInt8(data.count >> 16), UInt8((data.count >> 8) & 0xFF), UInt8(data.count & 0xFF)])
            frames.append(contentsOf: data)
        }
        add("TT2", [0] + Array("Song".utf8))
        add("TP1", [0] + Array("Band".utf8))
        add("PIC", [0] + Array("JPG".utf8) + [3, 0] + [0xFF, 0xD8, 0xFF, 0xE0, 1, 2])
        var tagBytes: Bytes = [0x49, 0x44, 0x33, 2, 0, 0]
        ID3v2.appendSyncsafe(&tagBytes, frames.count)
        let file = tagBytes + frames + fakeAudio()

        var w = TagWrite()
        w.album = "Album"
        let out = FileTags.apply(try XCTUnwrap(ID3v2.plan(w, file: file)), to: file)
        let tag = try XCTUnwrap(ID3v2.parse(out).0)
        XCTAssertEqual(tag.version, 3)
        XCTAssertEqual(tag.frames.first { $0.id == "TIT2" }.map { ID3v2.text($0) }, "Song")
        XCTAssertEqual(tag.frames.first { $0.id == "TPE1" }.map { ID3v2.text($0) }, "Band")
        XCTAssertEqual(tag.frames.first { $0.id == "TALB" }.map { ID3v2.text($0) }, "Album")
        let apic = try XCTUnwrap(tag.frames.first { $0.id == "APIC" })
        XCTAssertEqual(Array(apic.data.prefix(13)), [0] + Array("image/jpeg".utf8) + [0, 3])
        XCTAssertEqual(Array(apic.data.suffix(6)), [0xFF, 0xD8, 0xFF, 0xE0, 1, 2])
    }

    /// Real MP3 (needs lame): tags must read back through AVFoundation and the audio must be untouched.
    func testRealMP3Tags() async throws {
        let lame = ["/opt/homebrew/bin/lame", "/usr/local/bin/lame"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let lame else { throw XCTSkip("lame not installed") }
        let source = try wav()
        for (name, args) in [("plain", ["-b", "128"]), ("id3v2", ["-V", "4", "--add-id3v2", "--tt", "Old", "--ta", "Old artist", "--tl", "Old album"]),
                             ("id3v24", ["-b", "128", "--id3v2-only", "--id3v2-utf16", "--tt", "Старое", "--ty", "1990", "--tn", "1/9"])] {
            let mp3 = dir.appendingPathComponent(name + ".mp3")
            try run(lame, ["--quiet"] + args + [source.path, mp3.path])
            let original = Bytes(try Data(contentsOf: mp3))
            let before = try samples(mp3)
            let cover = jpeg(0, 0.5, 1)
            var w = fullWrite
            w.artwork = .set(cover)

            guard case .written(let size) = try FileTags.write(w, to: mp3) else { return XCTFail("\(name): not written") }
            let written = Bytes(try Data(contentsOf: mp3))
            XCTAssertEqual(size, written.count, name)
            await assertTags(mp3, cover: cover)
            XCTAssertEqual(try samples(mp3), before, "\(name): audio changed")
            // audio bytes are byte-identical behind the tags
            let a0 = try ID3v2.parse(original).1, a1 = try ID3v2.parse(written).1
            XCTAssertEqual(Array(written[a1...]), Array(original[a0...]), name)

            XCTAssertEqual(try FileTags.write(w, to: mp3), .unchanged, name)
            var small = TagWrite()
            small.genre = "Rock"
            XCTAssertEqual(try FileTags.write(small, to: mp3), .written(size: size), "\(name): second edit should fit in place")
            let m = await AudioMetaReader.read(url: mp3)
            XCTAssertEqual(m.genre, "Rock", name)
            XCTAssertEqual(m.title, "Хочешь?", name)
            XCTAssertEqual(try samples(mp3), before, "\(name): audio changed by the in-place edit")
            // volume change and tags get along
            let gained = try MP3Gain.applyToFile(mp3, steps: -2)
            XCTAssertGreaterThan(gained, 0)
            let m2 = await AudioMetaReader.read(url: mp3)
            XCTAssertEqual(m2.album, "Прости меня моя любовь", name)
            _ = try MP3Gain.undoFile(mp3)
            XCTAssertEqual(try samples(mp3), before, "\(name): undo after tagging")
        }
    }

    // MARK: MP4

    func makeM4A(_ codec: String, name: String) throws -> URL {
        let out = dir.appendingPathComponent(name + ".m4a")
        try run("/usr/bin/afconvert", ["-f", "m4af", "-d", codec, try wav().path, out.path])
        return out
    }

    /// Same file with moov in front of the audio (the layout of iTunes Store files).
    func fastStart(_ url: URL) async throws -> URL {
        let out = dir.appendingPathComponent("fast-" + url.lastPathComponent)
        let export = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetPassthrough))
        export.outputURL = out
        export.outputFileType = .m4a
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        XCTAssertEqual(export.status, .completed, export.error?.localizedDescription ?? "")
        return out
    }

    func checkM4A(_ url: URL, label: String) async throws {
        let before = try samples(url)
        let original = Bytes(try Data(contentsOf: url))
        let top0 = MP4Tags.topLevelAtoms(original)
        let mdat0 = try XCTUnwrap(top0.first { $0.type == "mdat" })
        let cover = jpeg(0.2, 0.8, 0.2)
        var w = fullWrite
        w.artwork = .set(cover)

        guard case .written(let size) = try FileTags.write(w, to: url) else { return XCTFail("\(label): not written") }
        let written = Bytes(try Data(contentsOf: url))
        XCTAssertEqual(size, written.count, label)
        let top1 = MP4Tags.topLevelAtoms(written)
        let mdat1 = try XCTUnwrap(top1.first { $0.type == "mdat" })
        XCTAssertEqual(Array(written[mdat1.offset..<mdat1.end]), Array(original[mdat0.offset..<mdat0.end]), "\(label): audio data changed")
        print("MP4", label, "layout before:", top0.map { $0.type }, "after:", top1.map { $0.type }, "mdat moved by", mdat1.offset - mdat0.offset)
        await assertTags(url, cover: cover)
        XCTAssertEqual(try samples(url), before, "\(label): decoded audio changed")

        XCTAssertEqual(try FileTags.write(w, to: url), .unchanged, label)

        // a small edit must fit into the padding: same size, audio in the same place
        var small = TagWrite()
        small.genre = "Rock"
        small.title = "T"
        XCTAssertEqual(try FileTags.write(small, to: url), .written(size: size), "\(label): second edit should fit in place")
        let again = Bytes(try Data(contentsOf: url))
        let mdat2 = try XCTUnwrap(MP4Tags.topLevelAtoms(again).first { $0.type == "mdat" })
        XCTAssertEqual(mdat2.offset, mdat1.offset, label)
        let m = await AudioMetaReader.read(url: url)
        XCTAssertEqual(m.genre, "Rock", label)
        XCTAssertEqual(m.title, "T", label)
        XCTAssertEqual(m.album, "Прости меня моя любовь", label)
        XCTAssertEqual(try samples(url), before, "\(label): decoded audio changed by the in-place edit")

        // removing everything again keeps the file playable
        var clear = TagWrite()
        clear.title = ""; clear.artist = ""; clear.album = ""; clear.albumArtist = ""; clear.genre = ""; clear.composer = ""
        clear.year = 0; clear.track = .init(number: 0, total: 0); clear.disc = .init(number: 0, total: 0)
        clear.compilation = false; clear.artwork = .remove
        guard case .written = try FileTags.write(clear, to: url) else { return XCTFail("\(label): clear not written") }
        let cleared = await AudioMetaReader.read(url: url)
        XCTAssertEqual(cleared.artist, "", label)
        XCTAssertEqual(cleared.year, 0, label)
        let noArt = await AudioMetaReader.artworkData(url: url)
        XCTAssertNil(noArt, label)
        XCTAssertEqual(try samples(url), before, "\(label): decoded audio changed after clearing")
    }

    func testM4ATagsAAC() async throws {
        try await checkM4A(try makeM4A("aac", name: "aac"), label: "aac")
    }

    func testM4ATagsALAC() async throws {
        try await checkM4A(try makeM4A("alac", name: "alac"), label: "alac")
    }

    func testM4ATagsWithMoovInFront() async throws {
        let fast = try await fastStart(try makeM4A("aac", name: "aacfs"))
        let top = MP4Tags.topLevelAtoms(Bytes(try Data(contentsOf: fast)))
        let moov = try XCTUnwrap(top.firstIndex { $0.type == "moov" }), mdat = try XCTUnwrap(top.firstIndex { $0.type == "mdat" })
        XCTAssertLessThan(moov, mdat, "export did not put moov first: \(top.map { $0.type })")
        try await checkM4A(fast, label: "aac moov-first")
        let fastLossless = try await fastStart(try makeM4A("alac", name: "alacfs"))
        try await checkM4A(fastLossless, label: "alac moov-first")
    }

    func testMP4RejectsWhatItDoesNotUnderstand() {
        XCTAssertThrowsError(try MP4Tags.plan(fullWrite, file: Bytes(repeating: 0, count: 100)))
        var notMP4 = Bytes()
        notMP4.appendBE32(16); notMP4.append(contentsOf: Array("ftypM4A ".utf8)); notMP4.appendBE32(0)
        XCTAssertThrowsError(try MP4Tags.plan(fullWrite, file: notMP4))     // no moov, no mdat
    }

    // MARK: Through the session

    func testCommitWritesTagsIntoFilesAndCompactsCovers() async throws {
        let root = dir.appendingPathComponent("ipod")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("iPod_Control/iTunes"), withIntermediateDirectories: true)
        let device = IPodDevice(mountURL: root, volumeName: "Test")
        let m4a = try makeM4A("aac", name: "song")
        var meta = AudioMeta()
        meta.title = "A"; meta.kind = .aac

        let session = try IPodSession(device: device)
        var c = CommitChanges()
        var tags = TagWrite()
        tags.title = "Edited before copying"
        c.adds = [NewTrack(sourceURL: m4a, meta: meta, artwork: jpeg(1, 0, 0), fileTags: tags),
                  NewTrack(sourceURL: m4a, meta: meta, artwork: jpeg(0, 1, 0)),
                  NewTrack(sourceURL: m4a, meta: meta, artwork: jpeg(0, 0, 1))]
        let sourceBefore = try Data(contentsOf: m4a)
        let r1 = try session.commit(c) { _ in }
        XCTAssertEqual(r1.tagsWritten, 1)
        XCTAssertEqual(try Data(contentsOf: m4a), sourceBefore, "the source file on the Mac must not change")
        let copied = await AudioMetaReader.read(url: device.fileURL(for: session.tracks[0]))
        XCTAssertEqual(copied.title, "Edited before copying")
        let size0 = try FileManager.default.attributesOfItem(atPath: device.fileURL(for: session.tracks[0]).path)[.size] as? Int
        XCTAssertEqual(Int(session.tracks[0].size), size0)

        // edit an existing song: database and file agree afterwards
        var e = TrackEdit()
        e.artist = "Исполнитель"
        e.trackNumber = 5
        var c2 = CommitChanges()
        let id = session.tracks[1].uniqueID
        c2.edits = [id: e]
        var edited = session.tracks[1]
        e.apply(to: &edited)
        var w = TagWrite(edit: e, result: edited)
        w.artwork = .set(jpeg(1, 1, 0))
        c2.fileTags = [id: w]
        c2.artwork = [id: .set(jpeg(1, 1, 0)), session.tracks[2].uniqueID: .remove]
        c2.deletes = [session.tracks[0].uniqueID]
        let r2 = try session.commit(c2) { _ in }
        XCTAssertEqual(r2.tagsWritten, 1)
        XCTAssertEqual(r2.tagsFailed, 0)
        let t = try XCTUnwrap(session.tracks.first { $0.uniqueID == id })
        let onDisk = await AudioMetaReader.read(url: device.fileURL(for: t))
        XCTAssertEqual(onDisk.artist, "Исполнитель")
        XCTAssertEqual(onDisk.trackNumber, 5)
        let art = await AudioMetaReader.artworkData(url: device.fileURL(for: t))
        XCTAssertEqual(art, jpeg(1, 1, 0))

        // three covers were stored, one is still used: the rest is waste until compaction
        let big = device.artworkURL.appendingPathComponent("F1029_1.ithmb")
        func fileSize(_ u: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? -1 }
        XCTAssertEqual(fileSize(big), 4 * 80000)
        XCTAssertEqual(session.artworkWaste(), Int64(3 * (80000 + 20000)))
        let adbBefore = try XCTUnwrap(session.artworkDB)
        let pixelBefore = try XCTUnwrap(device.thumbnail(adbBefore, imageID: t.mhiiLink, songID: t.dbid)?.dataProvider?.data as Data?)
        let freed = try session.compactArtwork()
        XCTAssertEqual(freed, Int64(3 * (80000 + 20000)))
        XCTAssertEqual(fileSize(big), 80000)
        XCTAssertEqual(fileSize(device.artworkURL.appendingPathComponent("F1028_1.ithmb")), 20000)
        XCTAssertEqual(session.artworkWaste(), 0)
        XCTAssertEqual(try session.compactArtwork(), 0)

        let reloaded = try IPodSession(device: device)
        let adb = try XCTUnwrap(reloaded.artworkDB)
        let t2 = try XCTUnwrap(reloaded.tracks.first { $0.uniqueID == id })
        XCTAssertEqual(adb.thumbs(imageID: t2.mhiiLink, songID: 0).map { $0.offset }, [0, 0])
        let pixelAfter = try XCTUnwrap(device.thumbnail(adb, imageID: t2.mhiiLink, songID: t2.dbid)?.dataProvider?.data as Data?)
        XCTAssertEqual(pixelAfter, pixelBefore, "the cover must look the same after compaction")
        XCTAssertFalse(FileManager.default.fileExists(atPath: big.path + ".ipm-new"))

        // a new cover after compaction lands right behind the kept one
        var c3 = CommitChanges()
        c3.artwork = [reloaded.tracks[1].uniqueID: .set(jpeg(0, 1, 1))]
        _ = try reloaded.commit(c3) { _ in }
        XCTAssertEqual(fileSize(big), 2 * 80000)
    }

    func testAutomaticCompactionNeedsEnoughWaste() throws {
        let root = dir.appendingPathComponent("ipod2")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("iPod_Control/iTunes"), withIntermediateDirectories: true)
        let device = IPodDevice(mountURL: root, volumeName: "Test")
        let src = dir.appendingPathComponent("s.mp3")
        try Data(fakeAudio()).write(to: src)
        var meta = AudioMeta()
        meta.title = "A"; meta.kind = .mp3
        let session = try IPodSession(device: device)
        var c = CommitChanges()
        c.adds = [NewTrack(sourceURL: src, meta: meta, artwork: jpeg(1, 0, 0))]
        _ = try session.commit(c) { _ in }
        // replace the cover a few times: waste stays far below the threshold, nothing is compacted
        for i in 0..<3 {
            var cc = CommitChanges()
            cc.artwork = [session.tracks[0].uniqueID: .set(jpeg(0, CGFloat(i) / 3, 1))]
            let r = try session.commit(cc) { _ in }
            XCTAssertEqual(r.artworkBytesFreed, 0)
        }
        XCTAssertEqual(session.artworkWaste(), Int64(3 * 100000))
        let plan = try session.planCompaction(try XCTUnwrap(session.artworkDB), force: false)
        XCTAssertTrue(plan.swaps.isEmpty)
    }
}
