import Foundation

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

struct MBReleaseSearch: Decodable { let releases: [MBRelease]? }
struct MBRecordingSearch: Decodable { let recordings: [MBRecording]? }

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

    public init(appVersion: String) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
        userAgent = "iPodManager/\(appVersion) ( https://github.com/DmitryZemlyuk/ipod-manager )"
    }

    func get(_ path: String, _ query: [String: String]) async throws -> Data {
        var comps = URLComponents(string: base + path)!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "fmt", value: "json")]
        var req = URLRequest(url: comps.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0..<4 {
            // Reserve the next free slot before awaiting, so concurrent callers queue up.
            let slot = max(Date(), lastRequest.addingTimeInterval(1.1))
            lastRequest = slot
            let wait = slot.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            try Task.checkCancellation()
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw OnlineError.badResponse }
            if http.statusCode == 200 { return data }
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
