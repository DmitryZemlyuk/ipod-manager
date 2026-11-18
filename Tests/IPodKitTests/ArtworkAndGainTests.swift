import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import IPodKit

final class ArtworkAndGainTests: XCTestCase {
    // MARK: helpers

    func png(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, width: Int = 300, height: Int = 300) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func tempDevice() throws -> IPodDevice {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ipm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("iPod_Control/iTunes"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return IPodDevice(mountURL: root, volumeName: "Test")
    }

    func meta(_ title: String, kind: AudioKind = .mp3) -> AudioMeta {
        var m = AudioMeta()
        m.title = title
        m.artist = "Artist"
        m.album = "Album"
        m.durationMs = 1000
        m.kind = kind
        return m
    }

    /// One MPEG-1 Layer III stereo frame, 128 kbps, 44.1 kHz (417 bytes), with given gains.
    func frame(gains: [UInt8], crc: Bool = false) -> Bytes {
        var f = Bytes(repeating: 0, count: 417)
        f[0] = 0xFF
        f[1] = crc ? 0xFA : 0xFB
        f[2] = 0x90
        f[3] = 0x00
        let side = 4 + (crc ? 2 : 0)
        let fr = MP3Gain.Frame(offset: 0, length: 417, sideInfo: side, sideLength: 32, channels: 2, mpeg1: true, hasCRC: crc)
        for (i, bit) in MP3Gain.gainBitOffsets(fr).enumerated() { MP3Gain.write8(&f, side, bit, gains[i]) }
        // some payload so frames aren't all zeros
        for i in (side + 32)..<417 { f[i] = UInt8(truncatingIfNeeded: i &* 7) }
        if crc {
            let c = MP3Gain.crc16(f, [2..<4, side..<(side + 32)])
            f[4] = UInt8(c >> 8)
            f[5] = UInt8(c & 0xFF)
        }
        return f
    }

    // MARK: ArtworkDB

    func testPixelsRoundTrip() throws {
        let data = try XCTUnwrap(ArtworkPixels.rgb565(from: png(1, 0, 0), width: 100, height: 100))
        XCTAssertEqual(data.count, 20000)
        // pure red in RGB565 LE = 0xF800 → bytes 00 F8
        XCTAssertEqual([UInt8](data.prefix(2)), [0x00, 0xF8])
        let img = try XCTUnwrap(ArtworkPixels.image(rgb565: data, width: 100, height: 100))
        XCTAssertEqual(img.width, 100)
        XCTAssertNil(ArtworkPixels.rgb565(from: Data([1, 2, 3]), width: 100, height: 100))
    }

    func testArtworkDBRoundTrip() throws {
        var db = ArtworkDB.makeEmpty()
        let refs = [
            ArtworkDB.ThumbRef(formatID: 1028, offset: 40000, size: 20000, fileName: ":F1028_1.ithmb"),
            ArtworkDB.ThumbRef(formatID: 1029, offset: 160000, size: 80000, fileName: ":F1029_1.ithmb")
        ]
        let id1 = db.addImage(songID: 0x1122334455667788, sourceSize: 5000, thumbs: refs)
        let id2 = db.addImage(songID: 42, sourceSize: 6000, thumbs: refs)
        XCTAssertEqual(id1, 100)
        XCTAssertEqual(id2, 101)
        db.ensureFiles(ArtworkFormat.video)
        let bytes = db.serialize()
        XCTAssertEqual(bytes.tag(0), "mhfd")
        XCTAssertEqual(Int(bytes.u32(4)), 0x84)
        XCTAssertEqual(Int(bytes.u32(8)), bytes.count)
        XCTAssertEqual(bytes.u32(20), 3)
        XCTAssertEqual(bytes.u32(28), 102)

        let parsed = try ArtworkDB.parse(bytes)
        XCTAssertEqual(parsed.serialize(), bytes)
        XCTAssertEqual(parsed.imageCount, 2)
        XCTAssertEqual(parsed.formatIDs, [1028, 1029])
        XCTAssertTrue(parsed.isWritable)
        XCTAssertEqual(parsed.thumbs(imageID: 0, songID: 42), refs)
        XCTAssertEqual(parsed.thumbs(imageID: 100, songID: 0), refs)

        // record layout
        let mhii = ArtworkDB.makeImage(id: 100, songID: 7, sourceSize: 1, thumbs: refs)
        XCTAssertEqual(mhii.tag(0), "mhii")
        XCTAssertEqual(Int(mhii.u32(4)), 0x98)
        XCTAssertEqual(Int(mhii.u32(8)), mhii.count)
        XCTAssertEqual(mhii.u32(12), 2)
        XCTAssertEqual(mhii.tag(0x98), "mhod")
        XCTAssertEqual(mhii.u16(0x98 + 12), 2)
        XCTAssertEqual(mhii.tag(0x98 + 24), "mhni")
        XCTAssertEqual(mhii.u32(0x98 + 24 + 16), 1028)
        XCTAssertEqual(mhii.u16(0x98 + 24 + 32), 100)
        XCTAssertEqual(Int(mhii.u32(0x98 + 8)) % 4, 0)

        var m = parsed
        m.removeImage(imageID: 0, songID: 42)
        XCTAssertEqual(m.imageCount, 1)
        XCTAssertFalse(m.hasImage(imageID: 0, songID: 42))
        XCTAssertTrue(m.hasImage(imageID: 100, songID: 0))
        XCTAssertEqual(m.addImage(songID: 9, sourceSize: 1, thumbs: refs), 102)
    }

    func testCommitWritesArtworkAndLinksTracks() throws {
        let device = try tempDevice()
        let src = device.mountURL.appendingPathComponent("song.mp3")
        try Data(frame(gains: [150, 150, 150, 150]) + frame(gains: [150, 150, 150, 150])).write(to: src)

        let session = try IPodSession(device: device)
        var c = CommitChanges()
        c.adds = [NewTrack(sourceURL: src, meta: meta("A"), artwork: png(0, 1, 0)),
                  NewTrack(sourceURL: src, meta: meta("B"), artwork: png(0, 1, 0)),
                  NewTrack(sourceURL: src, meta: meta("C"))]
        let report = try session.commit(c) { _ in }
        XCTAssertEqual(report.artworkWritten, 2)
        XCTAssertEqual(report.artworkFailed, 0)

        let again = try IPodSession(device: device)
        XCTAssertEqual(again.tracks.count, 3)
        let adb = try XCTUnwrap(again.artworkDB)
        XCTAssertEqual(adb.imageCount, 2)
        let a = again.tracks[0], b = again.tracks[1], cc = again.tracks[2]
        XCTAssertEqual(a.hasArtworkFlag, 1)
        XCTAssertEqual(a.artworkCount, 1)
        XCTAssertNotEqual(a.mhiiLink, 0)
        XCTAssertNotEqual(a.mhiiLink, b.mhiiLink)
        XCTAssertEqual(cc.mhiiLink, 0)
        XCTAssertEqual(cc.hasArtworkFlag, 2)
        // identical covers share pixels
        XCTAssertEqual(adb.thumbs(imageID: a.mhiiLink, songID: 0), adb.thumbs(imageID: b.mhiiLink, songID: 0))
        let size = try FileManager.default.attributesOfItem(atPath: device.artworkURL.appendingPathComponent("F1029_1.ithmb").path)[.size] as? Int
        XCTAssertEqual(size, 80000)
        let thumb = try XCTUnwrap(device.thumbnail(adb, imageID: a.mhiiLink, songID: a.dbid))
        XCTAssertEqual(thumb.width, 100)

        // replace one cover, remove another, delete a track
        var c2 = CommitChanges()
        c2.artwork = [a.uniqueID: .set(png(0, 0, 1)), cc.uniqueID: .set(Data([0, 1, 2]))]
        c2.deletes = [b.uniqueID]
        let r2 = try again.commit(c2) { _ in }
        XCTAssertEqual(r2.artworkWritten, 1)
        XCTAssertEqual(r2.artworkFailed, 1)
        let third = try IPodSession(device: device)
        XCTAssertEqual(third.tracks.count, 2)
        XCTAssertEqual(third.artworkDB?.imageCount, 1)
        XCTAssertNotEqual(third.tracks[0].mhiiLink, a.mhiiLink)
        XCTAssertTrue(FileManager.default.fileExists(atPath: device.artworkURL.appendingPathComponent("ArtworkDB.bak").path))

        var c3 = CommitChanges()
        c3.artwork = [third.tracks[0].uniqueID: .remove]
        _ = try third.commit(c3) { _ in }
        let fourth = try IPodSession(device: device)
        XCTAssertEqual(fourth.artworkDB?.imageCount, 0)
        XCTAssertEqual(fourth.tracks[0].hasArtworkFlag, 2)
    }

    func testSharedImageSurvivesUntilLastUserIsGone() throws {
        let device = try tempDevice()
        let src = device.mountURL.appendingPathComponent("song.mp3")
        try Data(frame(gains: [150, 150, 150, 150]) + frame(gains: [150, 150, 150, 150])).write(to: src)
        let session = try IPodSession(device: device)
        var c = CommitChanges()
        c.adds = [NewTrack(sourceURL: src, meta: meta("A"), artwork: png(1, 1, 0)), NewTrack(sourceURL: src, meta: meta("B"))]
        _ = try session.commit(c) { _ in }

        // Make B point at A's image, the way iTunes shares one item per album.
        var tracks = session.tracks
        let link = tracks[0].mhiiLink
        tracks[1].setArtwork(imageID: link, sourceSize: 1)
        var report = CommitReport()

        // A is deleted, B still uses the image.
        var remaining = [tracks[1]]
        session.applyArtwork(tracks: &remaining, changes: [:], removed: [tracks[0]], report: &report)
        XCTAssertEqual(session.artworkDB?.hasImage(imageID: link, songID: 0), true)

        // B gets a new cover: now nobody uses the old item.
        session.applyArtwork(tracks: &remaining, changes: [remaining[0].uniqueID: .set(png(0, 1, 1))], removed: [], report: &report)
        XCTAssertEqual(session.artworkDB?.hasImage(imageID: link, songID: 0), false)
        XCTAssertEqual(session.artworkDB?.imageCount, 1)
        XCTAssertNotEqual(remaining[0].mhiiLink, link)
    }

    func testNormalizedCover() throws {
        let big = png(0.2, 0.4, 0.6, width: 1400, height: 1400)
        let small = try XCTUnwrap(ArtworkPixels.normalized(big))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(small as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(img.width, 600)
        XCTAssertNil(ArtworkPixels.normalized(Data([9, 9, 9])))
    }

    // MARK: MP3 gain

    func testBitFieldAccess() {
        var d = Bytes(repeating: 0xFF, count: 4)
        MP3Gain.write8(&d, 0, 5, 0b1010_0101)
        XCTAssertEqual(MP3Gain.read8(d, 0, 5), 0b1010_0101)
        XCTAssertEqual(d[0] & 0b1111_1000, 0b1111_1000)
        XCTAssertEqual(d[1] & 0b0000_0111, 0b0000_0111)
        MP3Gain.write8(&d, 1, 8, 7)
        XCTAssertEqual(d[2], 7)
    }

    func testGainShiftAndUndo() throws {
        let original = frame(gains: [150, 140, 0, 200]) + frame(gains: [10, 250, 130, 131]) + frame(gains: [150, 150, 150, 150])
        let (changed, result) = try MP3Gain.apply(to: original, steps: -3)
        XCTAssertEqual(result.frames, 3)
        let t = MP3Gain.tail(changed)
        XCTAssertEqual(t.audioEnd, original.count)
        let fr = try MP3Gain.frames(changed, audioEnd: t.audioEnd)
        let gains = fr.flatMap { f in MP3Gain.gainBitOffsets(f).map { MP3Gain.read8(changed, f.sideInfo, $0) } }
        XCTAssertEqual(gains, [147, 137, 0, 197, 7, 247, 127, 128, 147, 147, 147, 147])
        // payload untouched
        XCTAssertEqual(Array(changed[36..<417]), Array(original[36..<417]))
        XCTAssertEqual(MP3Gain.pendingUndo(in: changed), 3)
        XCTAssertEqual(String(decoding: t.apeItems.first { $0.key == "MP3GAIN_UNDO" }!.value, as: UTF8.self), "+003,+003,N")

        // a second change accumulates
        let (twice, _) = try MP3Gain.apply(to: changed, steps: 1)
        XCTAssertEqual(MP3Gain.pendingUndo(in: twice), 2)

        let restored = try XCTUnwrap(MP3Gain.undo(twice))
        XCTAssertEqual(restored, original)
        XCTAssertNil(try MP3Gain.undo(restored))
    }

    func testCRCAndTagsArePreserved() throws {
        var id3v1 = Bytes(repeating: 0, count: 128)
        id3v1[0] = 0x54; id3v1[1] = 0x41; id3v1[2] = 0x47
        var id3v2 = Bytes([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 20])
        id3v2.append(contentsOf: Bytes(repeating: 0, count: 20))
        let audio = frame(gains: [100, 101, 102, 103], crc: true) + frame(gains: [100, 101, 102, 103], crc: true)
        let ape = MP3Gain.apeTag([MP3Gain.APEItem(key: "REPLAYGAIN_TRACK_GAIN", flags: 0, value: Array("-1.0 dB".utf8))])
        let file = id3v2 + audio + ape + id3v1

        let (changed, _) = try MP3Gain.apply(to: file, steps: 2)
        XCTAssertEqual(Array(changed.prefix(30)), id3v2)
        XCTAssertEqual(Array(changed.suffix(128)), id3v1)
        let t = MP3Gain.tail(changed)
        XCTAssertEqual(t.audioEnd, 30 + audio.count)
        XCTAssertEqual(Set(t.apeItems.map { $0.key }), ["REPLAYGAIN_TRACK_GAIN", "MP3GAIN_UNDO", "MP3GAIN_MINMAX"])
        for f in try MP3Gain.frames(changed, audioEnd: t.audioEnd) {
            let crc = MP3Gain.crc16(changed, [(f.offset + 2)..<(f.offset + 4), f.sideInfo..<(f.sideInfo + f.sideLength)])
            XCTAssertEqual(UInt8(crc >> 8), changed[f.offset + 4])
            XCTAssertEqual(UInt8(crc & 0xFF), changed[f.offset + 5])
            XCTAssertEqual(MP3Gain.read8(changed, f.sideInfo, MP3Gain.gainBitOffsets(f)[0]), 102)
        }
        XCTAssertEqual(try XCTUnwrap(MP3Gain.undo(changed)), file)
        XCTAssertThrowsError(try MP3Gain.apply(to: Bytes(repeating: 0, count: 5000), steps: 1))
    }

    func testNewSongsArriveAlreadyLeveled() throws {
        let device = try tempDevice()
        let src = device.mountURL.appendingPathComponent("song.mp3")
        let original = frame(gains: [150, 150, 150, 150]) + frame(gains: [150, 150, 150, 150])
        try Data(original).write(to: src)

        let session = try IPodSession(device: device)
        var c = CommitChanges()
        c.adds = [NewTrack(sourceURL: src, meta: meta("A"), soundCheck: 1500),
                  NewTrack(sourceURL: src, meta: meta("B"),
                           fileGain: FileGainRequest(steps: -2, fullSoundCheck: 2000, residualSoundCheck: 1100)),
                  NewTrack(sourceURL: src, meta: meta("C"))]
        let report = try session.commit(c) { _ in }
        XCTAssertEqual(report.filesChanged, 1)
        XCTAssertEqual(report.filesFailed, 0)

        let again = try IPodSession(device: device)
        XCTAssertEqual(again.tracks.map { $0.soundCheck }, [1500, 1100, 0])
        // Only the copy on the iPod is changed, the source file stays as it was.
        XCTAssertEqual(Array(try Data(contentsOf: src)), original)
        let copyB = Array(try Data(contentsOf: device.fileURL(for: again.tracks[1])))
        XCTAssertNotEqual(copyB, original)
        XCTAssertEqual(Array(try Data(contentsOf: device.fileURL(for: again.tracks[0]))), original)
        XCTAssertEqual(Int(again.tracks[1].size), copyB.count)
    }

    func testCommitChangesMP3FilesAndSoundCheck() throws {
        let device = try tempDevice()
        let src = device.mountURL.appendingPathComponent("song.mp3")
        let original = frame(gains: [150, 150, 150, 150]) + frame(gains: [150, 150, 150, 150])
        try Data(original).write(to: src)
        let notMP3 = device.mountURL.appendingPathComponent("song.m4a")
        try Data(repeating: 1, count: 3000).write(to: notMP3)

        let session = try IPodSession(device: device)
        var c = CommitChanges()
        c.adds = [NewTrack(sourceURL: src, meta: meta("A")), NewTrack(sourceURL: notMP3, meta: meta("B", kind: .aac))]
        _ = try session.commit(c) { _ in }
        let a = session.tracks[0], b = session.tracks[1]

        var g = CommitChanges()
        g.fileGain = [a.uniqueID: FileGainRequest(steps: -2, fullSoundCheck: 2000, residualSoundCheck: 1100),
                      b.uniqueID: FileGainRequest(steps: -2, fullSoundCheck: 2000, residualSoundCheck: 1100)]
        let report = try session.commit(g) { _ in }
        XCTAssertEqual(report.filesChanged, 1)
        XCTAssertEqual(report.filesFailed, 1)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.operation, .volume)
        XCTAssertEqual(report.failures.first?.title, "B")
        XCTAssertEqual(report.failures.first?.reason, .wrongFormat)
        let after = try IPodSession(device: device)
        XCTAssertEqual(after.tracks[0].soundCheck, 1100)
        XCTAssertEqual(after.tracks[1].soundCheck, 2000)
        let onDisk = Bytes(try Data(contentsOf: device.fileURL(for: after.tracks[0])))
        XCTAssertEqual(Int(after.tracks[0].size), onDisk.count)
        XCTAssertEqual(MP3Gain.pendingUndo(in: onDisk), 2)
        XCTAssertEqual(Bytes(try Data(contentsOf: device.fileURL(for: after.tracks[1]))).count, 3000)

        var u = CommitChanges()
        u.fileGainUndo = [a.uniqueID, b.uniqueID]
        let r2 = try after.commit(u) { _ in }
        XCTAssertEqual(r2.filesRestored, 1)
        let final = try IPodSession(device: device)
        XCTAssertEqual(Bytes(try Data(contentsOf: device.fileURL(for: final.tracks[0]))), original)
        XCTAssertEqual(final.tracks[0].soundCheck, 0)
        XCTAssertEqual(final.tracks[1].soundCheck, 2000)
    }
}
