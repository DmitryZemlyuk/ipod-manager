import XCTest
@testable import IPodKit

final class LoudnessTests: XCTestCase {
    func sine(freq: Double, dbfs: Double, seconds: Double, rate: Double) -> [Float] {
        let amp = pow(10, dbfs / 20)
        let n = Int(seconds * rate)
        return (0..<n).map { Float(amp * sin(2 * Double.pi * freq * Double($0) / rate)) }
    }

    /// EBU Tech 3341: stereo 1 kHz sine at −23 dBFS → −23 LUFS.
    func testReferenceSine48k() {
        let s = sine(freq: 1000, dbfs: -23, seconds: 10, rate: 48000)
        let r = Loudness.analyze(channels: [s, s], sampleRate: 48000)
        XCTAssertEqual(r.integrated, -23, accuracy: 0.1)
        XCTAssertEqual(Double(r.peak), pow(10, -23.0 / 20), accuracy: 0.001)
    }

    func testReferenceSine44k() {
        let s = sine(freq: 1000, dbfs: -20, seconds: 5, rate: 44100)
        let r = Loudness.analyze(channels: [s, s], sampleRate: 44100)
        XCTAssertEqual(r.integrated, -20, accuracy: 0.1)
    }

    func testSilenceIsGated() {
        let s = [Float](repeating: 0, count: 48000 * 2)
        let r = Loudness.analyze(channels: [s], sampleRate: 48000)
        XCTAssertEqual(r.integrated, -70)
    }

    func testSoundCheckMath() {
        XCTAssertEqual(SoundCheck.value(forGain: 0), 1000)
        XCTAssertEqual(SoundCheck.value(forGain: -3), 1995)
        XCTAssertEqual(SoundCheck.gain(forValue: 1000)!, 0, accuracy: 0.001)
        XCTAssertNil(SoundCheck.gain(forValue: 0))
        // −13 LUFS track at 89 dB target → −5 dB
        XCTAssertEqual(SoundCheck.gain(lufs: -13), -5, accuracy: 0.001)
        // positive gain limited by peak
        XCTAssertEqual(SoundCheck.gain(lufs: -24, peak: 0.9, preventClipping: true), -20 * log10(0.9), accuracy: 0.01)
        XCTAssertEqual(SoundCheck.gain(lufs: -24, peak: 0.9, preventClipping: false), 6, accuracy: 0.001)
    }

    func testAlbumGatingCombinesBlocks() {
        let loud = sine(freq: 1000, dbfs: -14, seconds: 5, rate: 48000)
        let quiet = sine(freq: 1000, dbfs: -20, seconds: 5, rate: 48000)
        let a = Loudness.analyze(channels: [loud, loud], sampleRate: 48000)
        let b = Loudness.analyze(channels: [quiet, quiet], sampleRate: 48000)
        let album = Loudness.gated(a.blocks + b.blocks)
        XCTAssertGreaterThan(album, b.integrated)
        XCTAssertLessThan(album, a.integrated)
    }
}
