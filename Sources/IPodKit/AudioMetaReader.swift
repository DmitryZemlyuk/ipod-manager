import Foundation
import AVFoundation

/// Reads tags and stream info from local audio files.
public enum AudioMetaReader {
    /// Files the 5th gen iPod can play.
    public static let playableExtensions: Set<String> = ["mp3", "m4a", "m4b", "wav", "aif", "aiff"]
    /// Audio files we list (unplayable ones are shown as unsupported).
    public static let listedExtensions: Set<String> = playableExtensions.union(["flac", "ogg", "opus", "wma", "ape", "aac", "dsf", "wv"])

    public static func isListed(_ url: URL) -> Bool {
        listedExtensions.contains(url.pathExtension.lowercased())
    }

    public static func read(url: URL) async -> AudioMeta {
        var m = AudioMeta()
        let ext = url.pathExtension.lowercased()
        m.title = url.deletingPathExtension().lastPathComponent
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            m.fileSize = size.int64Value
        }

        if playableExtensions.contains(ext), let file = try? AVAudioFile(forReading: url) {
            let rate = file.fileFormat.sampleRate
            if rate > 0 {
                m.sampleRate = Int(rate)
                m.sampleCount = file.length
                m.durationMs = Int(Double(file.length) / rate * 1000)
            }
            let fid = file.fileFormat.streamDescription.pointee.mFormatID
            m.kind = kind(ext: ext, formatID: fid)
        } else {
            m.kind = .unsupported(ext)
        }

        let asset = AVURLAsset(url: url)
        if m.durationMs == 0, let d = try? await asset.load(.duration), d.seconds.isFinite {
            m.durationMs = Int(d.seconds * 1000)
        }
        if m.durationMs > 0 {
            m.bitrateKbps = Int(Double(m.fileSize) * 8 / Double(m.durationMs))
        }

        guard let items = try? await asset.load(.metadata) else { return m }
        var tagTitle: String?
        for item in items {
            let id = item.identifier?.rawValue ?? ""
            let s = (try? await item.load(.stringValue)) ?? nil
            let text = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            switch id {
            case AVMetadataIdentifier.id3MetadataTrackNumber.rawValue:
                let (a, b) = pair(text)
                if a > 0 { m.trackNumber = a }
                if b > 0 { m.trackCount = b }
                continue
            case AVMetadataIdentifier.id3MetadataPartOfASet.rawValue:
                let (a, b) = pair(text)
                if a > 0 { m.discNumber = a }
                if b > 0 { m.discCount = b }
                continue
            case AVMetadataIdentifier.iTunesMetadataTrackNumber.rawValue,
                 AVMetadataIdentifier.iTunesMetadataDiscNumber.rawValue:
                if let d = (try? await item.load(.dataValue)) ?? nil, d.count >= 6 {
                    let b = [UInt8](d)
                    let a = Int(b[2]) << 8 | Int(b[3])
                    let t = Int(b[4]) << 8 | Int(b[5])
                    if id == AVMetadataIdentifier.iTunesMetadataTrackNumber.rawValue {
                        if a > 0 { m.trackNumber = a }
                        if t > 0 { m.trackCount = t }
                    } else {
                        if a > 0 { m.discNumber = a }
                        if t > 0 { m.discCount = t }
                    }
                } else if !text.isEmpty {
                    let (a, b) = pair(text)
                    if id == AVMetadataIdentifier.iTunesMetadataTrackNumber.rawValue {
                        if a > 0 { m.trackNumber = a }
                        if b > 0 { m.trackCount = b }
                    } else {
                        if a > 0 { m.discNumber = a }
                        if b > 0 { m.discCount = b }
                    }
                }
                continue
            case AVMetadataIdentifier.id3MetadataBand.rawValue,
                 AVMetadataIdentifier.iTunesMetadataAlbumArtist.rawValue:
                if !text.isEmpty { m.albumArtist = text }
                continue
            case AVMetadataIdentifier.id3MetadataComposer.rawValue,
                 AVMetadataIdentifier.iTunesMetadataComposer.rawValue:
                if !text.isEmpty { m.composer = text }
                continue
            case AVMetadataIdentifier.id3MetadataContentType.rawValue,
                 AVMetadataIdentifier.iTunesMetadataUserGenre.rawValue:
                if !text.isEmpty { m.genre = genreName(text) }
                continue
            case AVMetadataIdentifier.iTunesMetadataPredefinedGenre.rawValue:
                if m.genre.isEmpty, let d = (try? await item.load(.dataValue)) ?? nil, d.count >= 2 {
                    let b = [UInt8](d)
                    let idx = (Int(b[0]) << 8 | Int(b[1])) - 1
                    if idx >= 0, idx < id3Genres.count { m.genre = id3Genres[idx] }
                }
                continue
            case AVMetadataIdentifier.id3MetadataYear.rawValue,
                 AVMetadataIdentifier.id3MetadataRecordingTime.rawValue,
                 AVMetadataIdentifier.iTunesMetadataReleaseDate.rawValue:
                if let y = year(text) { m.year = y }
                continue
            case AVMetadataIdentifier.iTunesMetadataDiscCompilation.rawValue, "id3/TCMP":
                if let n = (try? await item.load(.numberValue)) ?? nil {
                    m.compilation = n.boolValue
                } else if text == "1" {
                    m.compilation = true
                } else if let d = (try? await item.load(.dataValue)) ?? nil, let first = d.first {
                    m.compilation = first != 0
                }
                continue
            default:
                break
            }

            guard !text.isEmpty, let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle: tagTitle = text
            case .commonKeyArtist: m.artist = text
            case .commonKeyAlbumName: m.album = text
            case .commonKeyType: if m.genre.isEmpty { m.genre = genreName(text) }
            case .commonKeyCreationDate: if m.year == 0, let y = year(text) { m.year = y }
            default: break
            }
        }
        if let t = tagTitle { m.title = t }
        return m
    }

    /// Embedded cover art, if any.
    public static func artworkData(url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let d = (try? await item.load(.dataValue)) ?? nil, !d.isEmpty { return d }
        }
        return nil
    }

    static func kind(ext: String, formatID: AudioFormatID) -> AudioKind {
        switch ext {
        case "mp3": return .mp3
        case "wav": return .wav
        case "aif", "aiff": return .aiff
        case "m4a", "m4b":
            switch formatID {
            case kAudioFormatAppleLossless: return .alac
            case kAudioFormatMPEG4AAC: return .aac
            case kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return .unsupported("HE-AAC")
            default: return .unsupported(ext)
            }
        default:
            return .unsupported(ext)
        }
    }

    /// "3/12" → (3, 12)
    static func pair(_ s: String) -> (Int, Int) {
        let parts = s.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return (parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
    }

    static func year(_ s: String) -> Int? {
        var digits = ""
        for ch in s {
            if ch.isASCII, ch.isNumber {
                digits.append(ch)
                if digits.count == 4 { break }
            } else if !digits.isEmpty {
                digits = ""
            }
        }
        guard digits.count == 4, let y = Int(digits), y > 1000 else { return nil }
        return y
    }

    /// Resolves ID3v1 numeric genres like "(17)" or "17".
    static func genreName(_ s: String) -> String {
        var t = s
        if t.hasPrefix("("), let close = t.firstIndex(of: ")") {
            let inner = t[t.index(after: t.startIndex)..<close]
            if let n = Int(inner), n >= 0, n < id3Genres.count {
                let rest = t[t.index(after: close)...].trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? id3Genres[n] : rest
            }
            t = String(t)
        }
        if let n = Int(t), n >= 0, n < id3Genres.count { return id3Genres[n] }
        return t
    }

    static let id3Genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk",
        "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
        "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes",
        "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock"
    ]
}

// MARK: - Export naming

public enum ExportLayout: String, CaseIterable, Identifiable {
    case artistAlbumTrack
    case artistDashAlbumTrack
    case flat

    public var id: String { rawValue }

    public func relativePath(for t: Track, fileExtension ext: String) -> String {
        let artist = ExportLayout.clean(t.albumArtist.isEmpty ? (t.artist.isEmpty ? "Unknown Artist" : t.artist) : t.albumArtist)
        let album = ExportLayout.clean(t.album.isEmpty ? "Unknown Album" : t.album)
        let title = ExportLayout.clean(t.title.isEmpty ? "Track \(t.uniqueID)" : t.title)
        let number: String
        if t.trackNumber > 0 {
            number = (t.discCount > 1 && t.discNumber > 0)
                ? String(format: "%d-%02d ", t.discNumber, t.trackNumber)
                : String(format: "%02d ", t.trackNumber)
        } else {
            number = ""
        }
        let e = ext.isEmpty ? "" : "." + ext
        switch self {
        case .artistAlbumTrack:
            return "\(artist)/\(album)/\(number)\(title)\(e)"
        case .artistDashAlbumTrack:
            return "\(artist) – \(album)/\(number)\(title)\(e)"
        case .flat:
            let trackArtist = ExportLayout.clean(t.artist.isEmpty ? "Unknown Artist" : t.artist)
            return "\(trackArtist) – \(title)\(e)"
        }
    }

    static func clean(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        r = r.components(separatedBy: .controlCharacters).joined()
        r = r.trimmingCharacters(in: .whitespacesAndNewlines)
        while r.hasPrefix(".") { r.removeFirst() }
        if r.count > 120 { r = String(r.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return r.isEmpty ? "_" : r
    }
}
