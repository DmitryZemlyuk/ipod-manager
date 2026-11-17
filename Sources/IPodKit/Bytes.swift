import Foundation

public typealias Bytes = [UInt8]

/// Little-endian helpers used by the iTunesDB reader/writer.
/// Reads past the end return 0, writes past the end grow the array with zeros.
extension Array where Element == UInt8 {
    func u8(_ o: Int) -> UInt8 {
        (o >= 0 && o < count) ? self[o] : 0
    }

    func u16(_ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= count else { return 0 }
        return UInt16(self[o]) | (UInt16(self[o + 1]) << 8)
    }

    func u32(_ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= count else { return 0 }
        return UInt32(self[o])
            | (UInt32(self[o + 1]) << 8)
            | (UInt32(self[o + 2]) << 16)
            | (UInt32(self[o + 3]) << 24)
    }

    func u64(_ o: Int) -> UInt64 {
        UInt64(u32(o)) | (UInt64(u32(o + 4)) << 32)
    }

    func f32(_ o: Int) -> Float {
        Float(bitPattern: u32(o))
    }

    func tag(_ o: Int) -> String {
        guard o >= 0, o + 4 <= count else { return "" }
        return String(bytes: self[o..<(o + 4)], encoding: .ascii) ?? ""
    }

    mutating func ensureSize(_ size: Int) {
        if count < size {
            append(contentsOf: [UInt8](repeating: 0, count: size - count))
        }
    }

    mutating func setU8(_ o: Int, _ v: UInt8) {
        ensureSize(o + 1)
        self[o] = v
    }

    mutating func setU16(_ o: Int, _ v: UInt16) {
        ensureSize(o + 2)
        self[o] = UInt8(truncatingIfNeeded: v)
        self[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }

    mutating func setU32(_ o: Int, _ v: UInt32) {
        ensureSize(o + 4)
        self[o] = UInt8(truncatingIfNeeded: v)
        self[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
        self[o + 2] = UInt8(truncatingIfNeeded: v >> 16)
        self[o + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }

    mutating func setU64(_ o: Int, _ v: UInt64) {
        setU32(o, UInt32(truncatingIfNeeded: v))
        setU32(o + 4, UInt32(truncatingIfNeeded: v >> 32))
    }

    mutating func setF32(_ o: Int, _ v: Float) {
        setU32(o, v.bitPattern)
    }

    mutating func setTag(_ o: Int, _ s: String) {
        let b = Array(s.utf8.prefix(4))
        ensureSize(o + 4)
        for i in 0..<b.count { self[o + i] = b[i] }
    }

    mutating func appendU32(_ v: UInt32) {
        append(UInt8(truncatingIfNeeded: v))
        append(UInt8(truncatingIfNeeded: v >> 8))
        append(UInt8(truncatingIfNeeded: v >> 16))
        append(UInt8(truncatingIfNeeded: v >> 24))
    }

    mutating func appendTag(_ s: String) {
        var b = Array(s.utf8.prefix(4))
        while b.count < 4 { b.append(0x20) }
        append(contentsOf: b)
    }

    mutating func appendZeros(_ n: Int) {
        if n > 0 { append(contentsOf: [UInt8](repeating: 0, count: n)) }
    }
}

/// HFS-style timestamps used by the iPod: seconds since 1904-01-01, local time.
public enum MacTime {
    static let offset1904: Double = 2_082_844_800

    public static func now() -> UInt32 {
        from(Date())
    }

    public static func from(_ date: Date) -> UInt32 {
        let local = date.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: date))
        let v = local + offset1904
        if v <= 0 { return 0 }
        if v >= Double(UInt32.max) { return UInt32.max }
        return UInt32(v)
    }

    public static func toDate(_ v: UInt32) -> Date? {
        guard v != 0 else { return nil }
        let local = Double(v) - offset1904
        let utc = local - Double(TimeZone.current.secondsFromGMT())
        return Date(timeIntervalSince1970: utc)
    }
}
