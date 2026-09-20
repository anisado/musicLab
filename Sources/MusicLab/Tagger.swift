import Foundation

/// Editable file metadata, uniform across formats — the python helper maps
/// these to each container's real tag frames (ID3, MP4 atoms, Vorbis).
struct TrackTags: Equatable {
    var title = "", artist = "", album = "", albumArtist = ""
    var genre = "", year = "", trackNumber = "", discNumber = ""
    var bpm = "", key = "", composer = "", lyricist = ""
    var remixer = "", version = "", grouping = "", mood = ""
    var label = "", catalogNumber = "", barcode = ""
    var copyright = "", language = "", originalYear = ""
    var replayGain = "", isrc = "", comment = ""
    var compilation = false
    var rating = 0
    var hasArtwork = false
}

/// Reads and writes file tags through `stems_tool.py tags` (mutagen) —
/// AVFoundation can read tags but cannot write them for most formats.
enum Tagger {
    private static func helper() -> [String]? { helper("tags") }

    /// argv prefix ending in `subcommand`: the bundled PyInstaller binary, or
    /// a python from the venv plus the script itself.
    static func helper(_ subcommand: String) -> [String]? {
        let fm = FileManager.default
        if let bundled = Bundle.main.url(forResource: "stems-tool", withExtension: nil) {
            return [bundled.path, subcommand]
        }
        let env = ProcessInfo.processInfo.environment
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let scripts = [
            Bundle.main.url(forResource: "stems_tool", withExtension: "py"),
            support.appendingPathComponent("MusicLab/stems_tool.py"),
            URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent("helper/stems_tool.py"),
        ].compactMap { $0 }
        guard let script = scripts.first(where: { fm.fileExists(atPath: $0.path) })
        else { return nil }
        var pythons = [
            support.appendingPathComponent("MusicLab/venv/bin/python"),
            URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent("helper/venv/bin/python"),
        ]
        if let override = env["MUSICLAB_PYTHON"], !override.isEmpty {
            pythons.insert(URL(fileURLWithPath: override), at: 0)
        }
        guard let python = pythons.first(where: { fm.isExecutableFile(atPath: $0.path) })
        else { return nil }
        return [python.path, script.path, subcommand]
    }

    static var available: Bool { helper() != nil }

    private static func run(_ arguments: [String]) async -> (Int32, Data) {
        await Task.detached {
            guard let prefix = helper() else { return (Int32(-1), Data()) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: prefix[0])
            process.arguments = Array(prefix.dropFirst()) + arguments
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return (Int32(-1), Data())
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        }.value
    }

    static func read(_ url: URL) async -> TrackTags? {
        let (status, data) = await run(["read", url.path])
        guard status == 0,
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return tags(from: dict)
    }

    /// Batch read: one helper process handles many files, so bulk metadata
    /// views don't pay a python startup cost per track. Keyed by file path.
    static func readMany(_ urls: [URL]) async -> [String: TrackTags] {
        guard !urls.isEmpty,
              let body = try? JSONEncoder().encode(urls.map(\.path)),
              let json = String(data: body, encoding: .utf8)
        else { return [:] }
        let (status, data) = await run(["readmany", json])
        guard status == 0,
              let dicts = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return dicts.mapValues(tags(from:))
    }

    private static func tags(from dict: [String: String]) -> TrackTags {
        TrackTags(
            title: dict["title"] ?? "",
            artist: dict["artist"] ?? "",
            album: dict["album"] ?? "",
            albumArtist: dict["albumartist"] ?? "",
            genre: dict["genre"] ?? "",
            year: dict["date"] ?? "",
            trackNumber: dict["tracknumber"] ?? "",
            discNumber: dict["discnumber"] ?? "",
            bpm: dict["bpm"] ?? "",
            key: dict["initialkey"] ?? "",
            composer: dict["composer"] ?? "",
            lyricist: dict["lyricist"] ?? "",
            remixer: dict["remixer"] ?? "",
            version: dict["version"] ?? "",
            grouping: dict["grouping"] ?? "",
            mood: dict["mood"] ?? "",
            label: dict["organization"] ?? "",
            catalogNumber: dict["catalognumber"] ?? "",
            barcode: dict["barcode"] ?? "",
            copyright: dict["copyright"] ?? "",
            language: dict["language"] ?? "",
            originalYear: dict["originaldate"] ?? "",
            replayGain: dict["replaygain_track_gain"] ?? "",
            isrc: dict["isrc"] ?? "",
            comment: dict["comment"] ?? "",
            compilation: dict["compilation"] == "1" || dict["compilation"] == "true",
            rating: Int(dict["rating"] ?? "") ?? 0,
            hasArtwork: dict["_artwork"] == "true"
        )
    }

    /// Write tags to the file; `artwork` is an image file whose bytes get
    /// embedded. Field changes also land in the store via the view model.
    static func write(_ url: URL, tags: TrackTags, artwork: URL?) async -> Bool {
        var payload: [String: String] = [
            "title": tags.title,
            "artist": tags.artist,
            "album": tags.album,
            "albumartist": tags.albumArtist,
            "genre": tags.genre,
            "date": tags.year,
            "tracknumber": tags.trackNumber,
            "discnumber": tags.discNumber,
            "bpm": tags.bpm,
            "initialkey": tags.key,
            "composer": tags.composer,
            "lyricist": tags.lyricist,
            "remixer": tags.remixer,
            "version": tags.version,
            "grouping": tags.grouping,
            "mood": tags.mood,
            "organization": tags.label,
            "catalognumber": tags.catalogNumber,
            "barcode": tags.barcode,
            "copyright": tags.copyright,
            "language": tags.language,
            "originaldate": tags.originalYear,
            "replaygain_track_gain": tags.replayGain,
            "compilation": tags.compilation ? "1" : "",
            "rating": "\(tags.rating)",
            "isrc": tags.isrc,
            "comment": tags.comment,
        ]
        if let artwork { payload["_artwork"] = artwork.path }
        guard let body = try? JSONEncoder().encode(payload),
              let json = String(data: body, encoding: .utf8)
        else { return false }
        let (status, _) = await run(["write", url.path, json])
        return status == 0
    }

    /// The macOS "Where from" extended attribute — the URL a browser or
    /// downloader stamped on the file, stored as a binary plist of strings.
    static func whereFrom(_ url: URL) -> String? {
        let path = url.path(percentEncoded: false)
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let got = data.withUnsafeMutableBytes {
            getxattr(path, name, $0.baseAddress, size, 0, 0)
        }
        guard got > 0,
            let list = try? PropertyListSerialization.propertyList(
                from: data, format: nil
            ) as? [String],
            let first = list.first, !first.isEmpty
        else { return nil }
        return first
    }

    /// Write the "Where from" attribute — empty string removes it.
    /// Returns false when the file can't be modified (permissions, TCC).
    @discardableResult
    static func setWhereFrom(_ url: URL, _ value: String) -> Bool {
        let path = url.path(percentEncoded: false)
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if getxattr(path, name, nil, 0, 0, 0) <= 0 { return true }
            return removexattr(path, name, 0) == 0
        }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: [trimmed], format: .binary, options: 0
        ) else { return false }
        return data.withUnsafeBytes {
            setxattr(path, name, $0.baseAddress, data.count, 0, 0) == 0
        }
    }

    /// Extract embedded artwork to a temp file, for previewing files whose
    /// tags carry art that was never copied out as a cover.
    static func extractArtwork(_ url: URL) async -> URL? {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("musiclab-art-\(UUID().uuidString)")
        let (status, _) = await run(["artwork", url.path, out.path])
        guard status == 0,
              FileManager.default.fileExists(atPath: out.path)
        else { return nil }
        return out
    }
}
