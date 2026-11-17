import Foundation
import AVFoundation

/// Integrated loudness per EBU R128 / ITU-R BS.1770 (K-weighting + gating).
public struct LoudnessResult: Sendable {
    /// Integrated loudness in LUFS (−70 for silence).
    public var integrated: Double
    /// Sample peak, linear (1.0 = 0 dBFS).
    public var peak: Float
    /// Mean-square energy of every 400 ms block (for album gating).
    public var blocks: [Float]
}

public enum Loudness {
    /// Combines blocks of several tracks into one gated loudness value.
    public static func gated(_ blocks: [Float]) -> Double {
        let above = blocks.filter { $0 > 0 && energyToLUFS(Double($0)) > -70 }
        guard !above.isEmpty else { return -70 }
        let meanAbove = above.reduce(0.0) { $0 + Double($1) } / Double(above.count)
        let relGate = energyToLUFS(meanAbove) - 10
        let rel = above.filter { energyToLUFS(Double($0)) > relGate }
        guard !rel.isEmpty else { return -70 }
        let mean = rel.reduce(0.0) { $0 + Double($1) } / Double(rel.count)
        return energyToLUFS(mean)
    }

    static func energyToLUFS(_ e: Double) -> Double {
        e > 0 ? -0.691 + 10 * log10(e) : -200
    }

    struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// K-weighting filter pair for a sample rate (coefficients as in libebur128).
    static func kWeighting(sampleRate rate: Double) -> (Biquad, Biquad) {
        var f0 = 1681.974450955533
        let g = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(Double.pi * f0 / rate)
        let vh = pow(10.0, g / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1.0 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0,
                           b1: 2.0 * (k * k - vh) / a0,
                           b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2.0 * (k * k - 1.0) / a0,
                           a2: (1.0 - k / q + k * k) / a0)
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / rate)
        a0 = 1.0 + k / q + k * k
        let highpass = Biquad(b0: 1.0, b1: -2.0, b2: 1.0,
                              a1: 2.0 * (k * k - 1.0) / a0,
                              a2: (1.0 - k / q + k * k) / a0)
        return (shelf, highpass)
    }

    static func channelWeight(_ index: Int, of count: Int) -> Double {
        guard count > 2 else { return 1.0 }
        // L R C LFE Ls Rs
        switch index {
        case 3: return 0.0
        case 4, 5: return 1.41
        default: return 1.0
        }
    }

    /// Analyzes PCM samples given as one array per channel.
    public static func analyze(channels: [[Float]], sampleRate: Double) -> LoudnessResult {
        var a = Analyzer(channels: channels.count, sampleRate: sampleRate)
        let frames = channels.first?.count ?? 0
        a.process(frameCount: frames) { ch, i in channels[ch][i] }
        return a.finish()
    }

    public static func analyze(url: URL, isCancelled: () -> Bool = { false }) throws -> LoudnessResult {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        var a = Analyzer(channels: channels, sampleRate: format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else {
            return a.finish()
        }
        while file.framePosition < file.length {
            if isCancelled() { throw CancellationError() }
            try file.read(into: buffer)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            a.process(frameCount: n) { ch, i in data[ch][i] }
        }
        return a.finish()
    }

    struct Analyzer {
        let channelCount: Int
        let segmentLength: Int
        var filters: [(Biquad, Biquad)]
        var weights: [Double]
        var segSum = 0.0
        var segFill = 0
        var segments: [Double] = []
        var peak: Float = 0

        init(channels: Int, sampleRate: Double) {
            channelCount = max(channels, 1)
            segmentLength = max(Int(sampleRate * 0.1), 1)
            let f = kWeighting(sampleRate: sampleRate)
            filters = Array(repeating: f, count: channelCount)
            weights = (0..<channelCount).map { Loudness.channelWeight($0, of: channelCount) }
        }

        mutating func process(frameCount: Int, sample: (Int, Int) -> Float) {
            for i in 0..<frameCount {
                var sum = 0.0
                for ch in 0..<channelCount {
                    let s = sample(ch, i)
                    let m = abs(s)
                    if m > peak { peak = m }
                    var y = filters[ch].0.process(Double(s))
                    y = filters[ch].1.process(y)
                    sum += weights[ch] * y * y
                }
                segSum += sum
                segFill += 1
                if segFill == segmentLength {
                    segments.append(segSum)
                    segSum = 0
                    segFill = 0
                }
            }
        }

        func finish() -> LoudnessResult {
            var blocks: [Float] = []
            if segments.count >= 4 {
                let denom = Double(segmentLength * 4)
                for k in 0...(segments.count - 4) {
                    let e = (segments[k] + segments[k + 1] + segments[k + 2] + segments[k + 3]) / denom
                    blocks.append(Float(e))
                }
            } else {
                let total = segments.reduce(0, +) + segSum
                let n = segments.count * segmentLength + segFill
                if n > 0 { blocks.append(Float(total / Double(n))) }
            }
            return LoudnessResult(integrated: Loudness.gated(blocks), peak: peak, blocks: blocks)
        }
    }
}

/// Converts loudness into iPod Sound Check values (ReplayGain-style 89 dB reference ≈ −18 LUFS).
public enum SoundCheck {
    public static let referenceLUFS = -18.0
    public static let referenceDB = 89.0

    /// Gain in dB needed to bring `lufs` to the target level (in ReplayGain dB, default 89).
    public static func gain(lufs: Double, targetDB: Double = 89, peak: Float? = nil, preventClipping: Bool = true) -> Double {
        var g = (targetDB - referenceDB) + (referenceLUFS - lufs)
        if preventClipping, let p = peak, p > 0 {
            let maxGain = -20 * log10(Double(p))
            g = min(g, maxGain)
        }
        return min(max(g, -30), 18)
    }

    public static func value(forGain g: Double) -> UInt32 {
        let v = 1000 * pow(10, -g / 10)
        return UInt32(clamping: Int((v).rounded()))
    }

    public static func gain(forValue v: UInt32) -> Double? {
        guard v > 0 else { return nil }
        return -10 * log10(Double(v) / 1000)
    }

    /// Loudness expressed on the ReplayGain dB scale (e.g. 89.0).
    public static func displayDB(lufs: Double) -> Double {
        lufs - referenceLUFS + referenceDB
    }
}
