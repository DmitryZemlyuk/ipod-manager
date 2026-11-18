import Foundation
import CryptoKit

// MARK: - JSON models (MusicBrainz web service v2, fmt=json)

public struct MBArtist: Decodable, Sendable {
    public let genres: [MBGenre]?
}

public struct MBArtistCredit: Decodable, Sendable {
    public let name: String?
    public let joinphrase: String?
    public let artist: MBArtist?
}

public struct MBGenre: Decodable, Sendable {
    public let name: String
    public let count: Int?
}

public struct MBReleaseGroup: Decodable, Sendable {
    public let id: String?
    public let primaryType: String?
    public let secondaryTypes: [String]?
    public let genres: [MBGenre]?
    public let firstReleaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id, genres
        case primaryType = "primary-type"
        case secondaryTypes = "secondary-types"
        case firstReleaseDate = "first-release-date"
    }

    public var firstReleaseYear: Int? {
        firstReleaseDate.flatMap { Int($0.prefix(4)) }.flatMap { $0 > 1000 ? $0 : nil }
    }
}

public struct MBRecordingRef: Decodable, Sendable {
    public let id: String
    public let title: String?
    public let length: Int?
}

public struct MBTrack: Decodable, Sendable {
    public let position: Int?
    public let number: String?
    public let title: String?
    public let length: Int?
    public let recording: MBRecordingRef?
    public let artistCredit: [MBArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case position, number, title, length, recording
        case artistCredit = "artist-credit"
    }
}

public struct MBMedium: Decodable, Sendable {
    public let position: Int?
    public let format: String?
    public let trackCount: Int?
    public let trackOffset: Int?
    /// Full track list (release lookup).
    public let tracks: [MBTrack]?
    /// Matching track(s) only (recording search).
    public let track: [MBTrack]?

    enum CodingKeys: String, CodingKey {
        case position, format, tracks, track
        case trackCount = "track-count"
        case trackOffset = "track-offset"
    }
}

public struct MBRelease: Decodable, Sendable {
    public let id: String
    public let score: Int?
    public let title: String?
    public let status: String?
    public let date: String?
    public let country: String?
    public let trackCount: Int?
    public let artistCredit: [MBArtistCredit]?
    public let releaseGroup: MBReleaseGroup?
    public let media: [MBMedium]?
    public let genres: [MBGenre]?

    enum CodingKeys: String, CodingKey {
        case id, score, title, status, date, country, media, genres
        case trackCount = "track-count"
        case artistCredit = "artist-credit"
        case releaseGroup = "release-group"
    }

    public var year: Int? { date.flatMap { Int($0.prefix(4)) } }
    public var totalTracks: Int { trackCount ?? media?.reduce(0) { $0 + ($1.trackCount ?? 0) } ?? 0 }
    public var discCount: Int { media?.count ?? 1 }
}

public struct MBRecording: Decodable, Sendable {
    public let id: String
    public let score: Int?
    public let title: String?
    public let length: Int?
    public let artistCredit: [MBArtistCredit]?
    public let releases: [MBRelease]?

    enum CodingKeys: String, CodingKey {
        case id, score, title, length, releases
        case artistCredit = "artist-credit"
    }
}

struct MBReleaseSearch: Decodable {
    let count: Int?
    let releases: [MBRelease]?
}

struct MBRecordingSearch: Decodable {
    let count: Int?
    let recordings: [MBRecording]?
}

/// Result of a search that asked for several things at once.
public struct MBBatch<T: Sendable>: Sendable {
    public let results: [T]
    /// True when the server returned every hit (nothing was cut off by the limit).
    public let complete: Bool
}

public func creditString(_ c: [MBArtistCredit]?) -> String {
    guard let c else { return "" }
    return c.map { ($0.name ?? "") + ($0.joinphrase ?? "") }.joined().trimmingCharacters(in: .whitespaces)
}

// MARK: - Client

public enum OnlineError: Error, LocalizedError {
    case http(Int)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .http(let c): return "HTTP \(c)"
        case .badResponse: return "Bad response"
        }
    }
}

/// MusicBrainz client honouring the 1 request/second rate limit.
public actor MusicBrainzClient {
    private let session: URLSession
    private let userAgent: String
    private var lastRequest = Date.distantPast
    private let base = "https://musicbrainz.org/ws/2/"
    private let cacheDirectory: URL?
    /// Answers are reused for two weeks, so repeating a search costs no requests.
    private let cacheLifetime: TimeInterval = 14 * 24 * 3600
    public private(set) var requestCount = 0
    public private(set) var cacheHits = 0

    public init(appVersion: String, cacheDirectory: URL? = nil) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
        userAgent = "iPodManager/\(appVersion) ( https://github.com/DmitryZemlyuk/ipod-manager )"
        self.cacheDirectory = cacheDirectory
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    private func cacheFile(_ key: String) -> URL? {
        guard let cacheDirectory else { return nil }
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(hash + ".json")
    }

    func get(_ path: String, _ query: [String: String]) async throws -> Data {
        var comps = URLComponents(string: base + path)!
        comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "fmt", value: "json")]
        let cache = cacheFile(comps.url?.absoluteString ?? path)
        if let cache,
           let modified = (try? FileManager.default.attributesOfItem(atPath: cache.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < cacheLifetime,
           let data = try? Data(contentsOf: cache) {
            cacheHits += 1
            return data
        }
        var req = URLRequest(url: comps.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0..<4 {
            // Reserve the next free slot before awaiting, so concurrent callers queue up.
            let slot = max(Date(), lastRequest.addingTimeInterval(1.05))
            lastRequest = slot
            let wait = slot.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            try Task.checkCancellation()
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw OnlineError.badResponse }
            requestCount += 1
            if http.statusCode == 200 {
                if let cache { try? data.write(to: cache) }
                return data
            }
            if http.statusCode == 503 || http.statusCode == 429 {
                try await Task.sleep(nanoseconds: UInt64(2_000_000_000 * (attempt + 1)))
                continue
            }
            if http.statusCode == 404 { return Data("{}".utf8) }
            throw OnlineError.http(http.statusCode)
        }
        throw OnlineError.http(503)
    }

    public func searchReleases(album: String, artist: String) async throws -> [MBRelease] {
        var q = "release:\"\(MusicBrainzClient.escape(album))\""
        if !artist.isEmpty { q += " AND artist:\"\(MusicBrainzClient.escape(artist))\"" }
        let data = try await get("release", ["query": q, "limit": "10"])
        return (try JSONDecoder().decode(MBReleaseSearch.self, from: data)).releases ?? []
    }

    /// One request for several albums. Results of all of them come back mixed together.
    public func searchReleasesBatch(_ queries: [(album: String, artist: String)]) async throws -> MBBatch<MBRelease> {
        let clauses = queries.map { q -> String in
            var c = "release:\"\(MusicBrainzClient.escape(q.album))\""
            if !q.artist.isEmpty { c += " AND artist:\"\(MusicBrainzClient.escape(q.artist))\"" }
            return "(" + c + ")"
        }
        let limit = min(100, 20 * queries.count)
        let data = try await get("release", ["query": clauses.joined(separator: " OR "), "limit": String(limit)])
        let r = try JSONDecoder().decode(MBReleaseSearch.self, from: data)
        let list = r.releases ?? []
        return MBBatch(results: list, complete: (r.count ?? Int.max) <= list.count)
    }

    /// One request for several songs.
    public func searchRecordingsBatch(_ queries: [(title: String, artist: String, durationMs: Int)]) async throws -> MBBatch<MBRecording> {
        let clauses = queries.map { q -> String in
            var c = "recording:\"\(MusicBrainzClient.escape(q.title))\""
            if !q.artist.isEmpty { c += " AND artist:\"\(MusicBrainzClient.escape(q.artist))\"" }
            if q.durationMs > 0 { c += " AND dur:[\(max(q.durationMs - 5000, 0)) TO \(q.durationMs + 5000)]" }
            return "(" + c + ")"
        }
        let data = try await get("recording", ["query": clauses.joined(separator: " OR "), "limit": "100"])
        let r = try JSONDecoder().decode(MBRecordingSearch.self, from: data)
        let list = r.recordings ?? []
        return MBBatch(results: list, complete: (r.count ?? Int.max) <= list.count)
    }

    public func release(id: String) async throws -> MBRelease? {
        let data = try await get("release/\(id)", ["inc": "recordings+artist-credits+release-groups+genres"])
        return try? JSONDecoder().decode(MBRelease.self, from: data)
    }

    public func releaseGroupGenres(id: String) async throws -> [MBGenre] {
        let data = try await get("release-group/\(id)", ["inc": "genres"])
        return (try? JSONDecoder().decode(MBReleaseGroup.self, from: data))?.genres ?? []
    }

    public func searchRecordings(title: String, artist: String, durationMs: Int) async throws -> [MBRecording] {
        var q = "recording:\"\(MusicBrainzClient.escape(title))\""
        if !artist.isEmpty { q += " AND artist:\"\(MusicBrainzClient.escape(artist))\"" }
        if durationMs > 0 {
            q += " AND dur:[\(max(durationMs - 5000, 0)) TO \(durationMs + 5000)]"
        }
        let data = try await get("recording", ["query": q, "limit": "10"])
        return (try JSONDecoder().decode(MBRecordingSearch.self, from: data)).recordings ?? []
    }

    public func recordings(ids: [String]) async throws -> [MBRecording] {
        guard !ids.isEmpty else { return [] }
        let q = ids.prefix(10).map { "rid:\($0)" }.joined(separator: " OR ")
        let data = try await get("recording", ["query": q, "limit": "10"])
        return (try JSONDecoder().decode(MBRecordingSearch.self, from: data)).recordings ?? []
    }

    /// Escapes Lucene special characters inside a quoted phrase.
    public static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "+-&|!(){}[]^\"~*?:\\/".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

// MARK: - AcoustID

public enum AcoustID {
    public struct Fingerprint: Sendable {
        public let duration: Int
        public let fingerprint: String
    }

    /// Runs the bundled `fpcalc` (Chromaprint) on a file.
    public static func fingerprint(url: URL, fpcalc: URL) throws -> Fingerprint? {
        let p = Process()
        p.executableURL = fpcalc
        p.arguments = ["-json", "-length", "120", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fp = obj["fingerprint"] as? String else { return nil }
        let dur = (obj["duration"] as? NSNumber)?.intValue ?? 0
        return Fingerprint(duration: dur, fingerprint: fp)
    }

    struct Response: Decodable {
        struct Result: Decodable {
            struct Rec: Decodable { let id: String }
            let score: Double?
            let recordings: [Rec]?
        }
        let status: String?
        let results: [Result]?
    }

    /// Returns MusicBrainz recording IDs, best first.
    public static func lookup(_ fp: Fingerprint, apiKey: String) async throws -> [(id: String, score: Double)] {
        var comps = URLComponents(string: "https://api.acoustid.org/v2/lookup")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: apiKey),
            URLQueryItem(name: "meta", value: "recordingids"),
            URLQueryItem(name: "duration", value: String(fp.duration)),
            URLQueryItem(name: "fingerprint", value: fp.fingerprint)
        ]
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw OnlineError.http(http.statusCode) }
        let r = try JSONDecoder().decode(Response.self, from: data)
        var out: [(String, Double)] = []
        for result in r.results ?? [] {
            for rec in result.recordings ?? [] where !out.contains(where: { $0.0 == rec.id }) {
                out.append((rec.id, result.score ?? 0))
            }
        }
        try await Task.sleep(nanoseconds: 350_000_000) // AcoustID: max 3 requests/second
        return out.map { (id: $0.0, score: $0.1) }
    }
}
