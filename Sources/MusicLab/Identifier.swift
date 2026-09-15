import Foundation

/// Identify tracks by audio fingerprint: Chromaprint (fpcalc) → AcoustID →
/// MusicBrainz recording/release lookup → Cover Art Archive front cover.
enum Identifier {

    struct Result {
        var tags = TrackTags()
        var artwork: Data?
        var recordingId = ""
        var releaseId: String?
        /// True when a matching release was found — its compilation flag is
        /// then meaningful (vs. "no data, leave the existing flag alone").
        var hasRelease: Bool { releaseId != nil }
    }

    enum IdentifyError: LocalizedError {
        case noFpcalc, fingerprintFailed, noMatch, network(String)

        var errorDescription: String? {
            switch self {
            case .noFpcalc: "fpcalc not found — run: brew install chromaprint"
            case .fingerprintFailed: "fpcalc failed"
            case .noMatch: "no AcoustID match"
            case .network(let m): m
            }
        }
    }

    /// Full pipeline for one file. `provider` is "auto" (fingerprint when a
    /// key is set, fall back to search), "fingerprint" or "search". Throws on
    /// lookup failure; individual fields may still be empty when MusicBrainz
    /// has no data.
    static func identify(_ file: URL, key: String,
                         title: String, artist: String,
                         provider: String = "auto",
                         wantArtwork: Bool = true) async throws -> Result {
        var hit: (recordingId: String, releases: [[String: Any]])?
        if provider != "search", !key.isEmpty {
            let (duration, fp) = try await Task.detached {
                try fingerprint(file)
            }.value
            hit = try await acoustid(fp: fp, duration: duration, key: key)
        }
        if hit == nil, provider != "fingerprint", !title.isEmpty {
            hit = try await searchRecording(title: title, artist: artist)
        }
        guard let hit else { throw IdentifyError.noMatch }
        let rec = try await recording(hit.recordingId)
        var result = Result()
        result.recordingId = hit.recordingId
        result.tags = map(rec)
        // a second MB call gets media/label/release-group detail the
        // recording lookup doesn't embed
        if let relId = pickReleaseId(hit.releases),
           let rel = try? await releaseDetail(relId) {
            result.releaseId = relId
            applyRelease(rel, recordingId: hit.recordingId, to: &result.tags)
            if wantArtwork { result.artwork = await frontCover(relId) }
        }
        return result
    }

    // MARK: fpcalc

    private static var fpcalcPath: String? {
        for p in ["/opt/homebrew/bin/fpcalc", "/usr/local/bin/fpcalc"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    private static func fingerprint(_ url: URL) throws -> (Int, String) {
        guard let bin = fpcalcPath else { throw IdentifyError.noFpcalc }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-json", url.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dur = j["duration"] as? Double,
              let fp = j["fingerprint"] as? String
        else { throw IdentifyError.fingerprintFailed }
        return (Int(dur.rounded()), fp)
    }

    // MARK: HTTP

    private static func get(_ urlString: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString) else { throw IdentifyError.network("bad url") }
        var req = URLRequest(url: url)
        // MusicBrainz requires a meaningful UA; Cover Art Archive too
        req.setValue("MusicLab/0.1.0 ( https://devin.ai )", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw IdentifyError.network("bad response") }
        return (data, http)
    }

    private static func getJSON(_ urlString: String) async throws -> [String: Any] {
        // MusicBrainz throttles anonymous clients hard — one retry on 503
        for attempt in 0...1 {
            let (data, http) = try await get(urlString)
            if http.statusCode == 200 {
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            }
            if http.statusCode != 503 || attempt == 1 {
                throw IdentifyError.network("HTTP \(http.statusCode)")
            }
            try? await Task.sleep(for: .seconds(3))
        }
        return [:]
    }

    // MARK: AcoustID

    /// Best recording candidate by match score, plus its candidate releases
    /// (each has id/title/date/country — enough to pick the earliest).
    private static func acoustid(fp: String, duration: Int, key: String)
        async throws -> (recordingId: String, releases: [[String: Any]])?
    {
        var c = URLComponents(string: "https://api.acoustid.org/v2/lookup")!
        c.queryItems = [
            .init(name: "client", value: key),
            .init(name: "fingerprint", value: fp),
            .init(name: "duration", value: String(duration)),
            .init(name: "meta", value: "recordings+releases"),
            .init(name: "format", value: "json"),
        ]
        let j = try await getJSON(c.url!.absoluteString)
        if let err = (j["error"] as? [String: Any])?["message"] as? String {
            throw IdentifyError.network("AcoustID: \(err)")
        }
        let results = (j["results"] as? [[String: Any]] ?? [])
            .sorted { ($0["score"] as? Double ?? 0) > ($1["score"] as? Double ?? 0) }
        for r in results {
            for rec in r["recordings"] as? [[String: Any]] ?? [] {
                guard let id = rec["id"] as? String else { continue }
                return (id, rec["releases"] as? [[String: Any]] ?? [])
            }
        }
        return nil
    }

    // MARK: MusicBrainz

    /// Keyless fallback — search recordings by existing title/artist text.
    /// Less reliable than a fingerprint but needs no setup.
    private static func searchRecording(title: String, artist: String)
        async throws -> (recordingId: String, releases: [[String: Any]])?
    {
        let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: " ") }
        var q = "recording:\"\(esc(title))\""
        if !artist.isEmpty { q += " AND artist:\"\(esc(artist))\"" }
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")!
        c.queryItems = [
            .init(name: "query", value: q),
            .init(name: "fmt", value: "json"),
            .init(name: "limit", value: "5"),
        ]
        let j = try await getJSON(c.url!.absoluteString)
        guard let best = (j["recordings"] as? [[String: Any]])?.first,
              let id = best["id"] as? String
        else { return nil }
        return (id, best["releases"] as? [[String: Any]] ?? [])
    }

    private static func recording(_ mbid: String) async throws -> [String: Any] {
        try await getJSON(
            "https://musicbrainz.org/ws/2/recording/\(mbid)?fmt=json&inc=artists+isrcs+tags")
    }

    private static func releaseDetail(_ mbid: String) async throws -> [String: Any] {
        // pace the two MB calls — anonymous clients are limited to ~1 req/sec
        try? await Task.sleep(for: .milliseconds(1050))
        return try await getJSON(
            "https://musicbrainz.org/ws/2/release/\(mbid)?fmt=json&inc=artists+labels+recordings+release-groups")
    }

    /// Release candidates carry an id plus a date — AcoustID gives a
    /// {year,month,day} dict, MusicBrainz search gives a "YYYY-MM-DD" string.
    /// Pick the earliest dated one: the original release, not a reissue.
    private static func pickReleaseId(_ releases: [[String: Any]]) -> String? {
        func year(_ r: [String: Any]) -> Int {
            if let d = r["date"] as? [String: Any] { return d["year"] as? Int ?? 9999 }
            return Int(((r["date"] as? String) ?? "").prefix(4)) ?? 9999
        }
        return releases.sorted { year($0) < year($1) }
            .first?["id"] as? String
    }

    /// Recording-level fields: title, artist, ISRC, genre, disambiguation.
    private static func map(_ rec: [String: Any]) -> TrackTags {
        var t = TrackTags()
        t.title = rec["title"] as? String ?? ""
        t.artist = artistCredit(rec["artist-credit"])
        t.isrc = (rec["isrcs"] as? [String])?.first ?? ""
        t.version = rec["disambiguation"] as? String ?? ""
        let tags = (rec["tags"] as? [[String: Any]] ?? [])
            .sorted { ($0["count"] as? Int ?? 0) > ($1["count"] as? Int ?? 0) }
        t.genre = (tags.first?["name"] as? String ?? "").capitalized
        return t
    }

    /// Release-level fields: album, date, track/disc position, label, barcode.
    private static func applyRelease(_ rel: [String: Any], recordingId: String, to t: inout TrackTags) {
        t.album = rel["title"] as? String ?? ""
        t.year = String((rel["date"] as? String ?? "").prefix(4))
        t.barcode = rel["barcode"] as? String ?? ""
        let credit = artistCredit(rel["artist-credit"])
        t.albumArtist = credit.isEmpty || credit == t.artist ? "" : credit
        let info = (rel["label-info"] as? [[String: Any]])?.first
        t.label = (info?["label"] as? [String: Any])?["name"] as? String ?? ""
        t.catalogNumber = info?["catalog-number"] as? String ?? ""
        if let group = rel["release-group"] as? [String: Any] {
            t.originalYear = String((group["first-release-date"] as? String ?? "").prefix(4))
            t.compilation = (group["secondary-types"] as? [String] ?? []).contains("Compilation")
        }
        for med in rel["media"] as? [[String: Any]] ?? [] {
            guard let hit = (med["tracks"] as? [[String: Any]] ?? []).first(where: {
                ($0["recording"] as? [String: Any])?["id"] as? String == recordingId
            }) else { continue }
            t.trackNumber = (hit["number"] as? String) ?? "\(hit["position"] as? Int ?? 0)"
            if let disc = med["position"] as? Int, (rel["media"] as? [[String: Any]] ?? []).count > 1 {
                t.discNumber = String(disc)
            }
            break
        }
    }

    /// "Name & Name" style credit — name plus joinphrase concatenation.
    private static func artistCredit(_ ac: Any?) -> String {
        (ac as? [[String: Any]] ?? [])
            .map { ($0["name"] as? String ?? "") + ($0["joinphrase"] as? String ?? "") }
            .joined()
    }

    // MARK: Cover Art Archive

    private static func frontCover(_ releaseId: String) async -> Data? {
        guard let (data, http) = try? await get(
            "https://coverartarchive.org/release/\(releaseId)/front-500"),
            http.statusCode == 200, !data.isEmpty
        else { return nil }
        return data
    }
}

extension TrackTags {
    /// Every writable string field — used to merge identified tags over
    /// existing ones without clobbering fields the lookup knows nothing
    /// about (comment, rating, detected bpm, etc.).
    static let stringKeyPaths: [WritableKeyPath<TrackTags, String>] = [
        \.title, \.artist, \.albumArtist, \.album, \.genre, \.year,
        \.originalYear, \.trackNumber, \.discNumber, \.bpm, \.key,
        \.composer, \.lyricist, \.remixer, \.version, \.grouping, \.mood,
        \.label, \.catalogNumber, \.barcode, \.copyright, \.language,
        \.replayGain, \.isrc, \.comment,
    ]

    /// Copy non-empty fields of `other` over self.
    func mergedNonEmpty(from other: TrackTags) -> TrackTags {
        var t = self
        for kp in TrackTags.stringKeyPaths where !other[keyPath: kp].isEmpty {
            t[keyPath: kp] = other[keyPath: kp]
        }
        return t
    }
}
