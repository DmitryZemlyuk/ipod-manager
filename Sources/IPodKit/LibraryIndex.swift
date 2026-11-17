import Foundation

/// Builds the master playlist's "library playlist index" mhods (type 52) and
/// their jump tables (type 53), which the iPod uses to browse its menus.
/// Layout follows libgpod (mk_mhod: MHOD_ID_LIBPLAYLISTINDEX / JUMPTABLE).
enum LibraryIndex {
    enum Kind: UInt32, CaseIterable {
        case title = 0x03, album = 0x04, artist = 0x05, genre = 0x07, composer = 0x12
    }

    enum Key: Comparable {
        case s(String)
        case i(Int)

        static func < (a: Key, b: Key) -> Bool {
            switch (a, b) {
            case (.s(let x), .s(let y)): return compareStrings(x, y) == .orderedAscending
            case (.i(let x), .i(let y)): return x < y
            case (.i, .s): return true
            case (.s, .i): return false
            }
        }

        static func == (a: Key, b: Key) -> Bool {
            switch (a, b) {
            case (.s(let x), .s(let y)): return compareStrings(x, y) == .orderedSame
            case (.i(let x), .i(let y)): return x == y
            default: return false
            }
        }
    }

    static func compareStrings(_ a: String, _ b: String) -> ComparisonResult {
        // Empty values go last, like on the iPod.
        if a.isEmpty != b.isEmpty { return a.isEmpty ? .orderedDescending : .orderedAscending }
        return a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .numeric])
    }

    static func keys(_ t: Track, _ kind: Kind) -> [Key] {
        let disc = Key.i(Int(t.discNumber))
        let nr = Key.i(Int(t.trackNumber))
        switch kind {
        case .title:
            return [.s(t.title)]
        case .album:
            return [.s(t.album), disc, nr, .s(t.title)]
        case .artist:
            return [.s(t.artist), .s(t.album), disc, nr, .s(t.title)]
        case .genre:
            return [.s(t.genre), .s(t.artist), .s(t.album), disc, nr, .s(t.title)]
        case .composer:
            return [.s(t.composer), .s(t.title)]
        }
    }

    static func primary(_ t: Track, _ kind: Kind) -> String {
        switch kind {
        case .title: return t.title
        case .album: return t.album
        case .artist: return t.artist
        case .genre: return t.genre
        case .composer: return t.composer
        }
    }

    static func sortedIndices(_ tracks: [Track], _ kind: Kind) -> [Int] {
        let k = tracks.map { keys($0, kind) }
        return tracks.indices.sorted { a, b in
            let ka = k[a], kb = k[b]
            for (x, y) in zip(ka, kb) where x != y {
                return x < y
            }
            return a < b
        }
    }

    static func jumpLetter(_ s: String) -> UInt32 {
        guard let ch = s.first else { return 0x30 }
        let up = String(ch).uppercased()
        guard let scalar = up.unicodeScalars.first else { return 0x30 }
        if scalar.properties.isAlphabetic, let unit = up.utf16.first {
            return UInt32(unit)
        }
        return 0x30
    }

    static func makeMHODs(_ tracks: [Track]) -> [MHOD] {
        var out = [MHOD]()
        for kind in Kind.allCases {
            let order = sortedIndices(tracks, kind)

            var r = Bytes()
            r.appendTag("mhod")
            r.appendU32(24)
            r.appendU32(UInt32(72 + 4 * order.count))
            r.appendU32(52)
            r.appendU32(0)
            r.appendU32(0)
            r.appendU32(kind.rawValue)
            r.appendU32(UInt32(order.count))
            r.appendZeros(40)
            for i in order { r.appendU32(UInt32(i)) }
            out.append(MHOD(raw: r))

            // Jump table: runs of equal first letters over the sorted list.
            var runs: [(letter: UInt32, start: Int, count: Int)] = []
            for (pos, idx) in order.enumerated() {
                let letter = jumpLetter(primary(tracks[idx], kind))
                if let last = runs.last, last.letter == letter {
                    runs[runs.count - 1].count += 1
                } else {
                    runs.append((letter, pos, 1))
                }
            }
            var j = Bytes()
            j.appendTag("mhod")
            j.appendU32(24)
            j.appendU32(UInt32(40 + 12 * runs.count))
            j.appendU32(53)
            j.appendU32(0)
            j.appendU32(0)
            j.appendU32(kind.rawValue)
            j.appendU32(UInt32(runs.count))
            j.appendZeros(8)
            for run in runs {
                j.appendU32(run.letter)
                j.appendU32(UInt32(run.start))
                j.appendU32(UInt32(run.count))
            }
            out.append(MHOD(raw: j))
        }
        return out
    }
}
