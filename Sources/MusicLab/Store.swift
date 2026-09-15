import AppKit
import AVFoundation
import CryptoKit
import Foundation

@MainActor
final class Store: ObservableObject {
    @Published var tracks: [Track] = []
    @Published var playlists: [Playlist] = []

    let root: URL
    let tracksDir: URL
    let stemsDir: URL
    /// Derived data that is expensive to recompute — waveform envelopes etc.
    let cachesDir: URL
    private var storeURL: URL { root.appendingPathComponent("store.json") }
    private let coverCache = NSCache<NSString, NSImage>()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("MusicLab", isDirectory: true)
        tracksDir = root.appendingPathComponent("tracks", isDirectory: true)
        stemsDir = root.appendingPathComponent("stems", isDirectory: true)
        cachesDir = root.appendingPathComponent("caches", isDirectory: true)
        try? FileManager.default.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stemsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        struct Persisted: Codable { var tracks: [Track]; var playlists: [Playlist] }
        guard let data = try? Data(contentsOf: storeURL),
              let saved = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return }
        // drop entries whose file vanished, then collapse exact duplicates:
        // same content hash (computed on demand for pre-hash imports)
        var unique: [Track] = []
        var hashes: [String: String] = [:]
        var remap: [String: String] = [:]
        var backfilled = false
        for var track in saved.tracks {
            let url = tracksDir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // hash backfill must be persisted or every launch re-hashes
            // every pre-hash import — that is a multi-second stall
            backfilled = backfilled || track.hash == nil
            let hash = track.hash ?? fileHash(url)
            // earlier imports may carry a UUID inside the title — strip it
            // and re-split on " - " if the cleaner name has one
            let cleaned = stripUUIDs(track.title)
            if cleaned != track.title {
                track.title = cleaned.isEmpty ? "Untitled" : cleaned
                backfilled = true
            }
            if let hash, let other = unique.first(where: { $0.size == track.size && hashes[$0.id] == hash }) {
                if other.hash == nil, let index = unique.firstIndex(where: { $0.id == other.id }) {
                    unique[index].hash = hash
                }
                remap[track.id] = other.id
                try? FileManager.default.removeItem(at: url)
                if let cover = track.cover {
                    try? FileManager.default.removeItem(at: tracksDir.appendingPathComponent(cover))
                }
                try? FileManager.default.removeItem(at: stemsDir.appendingPathComponent(track.id))
                continue
            }
            track.hash = hash
            if let hash { hashes[track.id] = hash }
            unique.append(track)
        }
        tracks = unique
        playlists = saved.playlists.map { playlist in
            var playlist = playlist
            playlist.trackIds = playlist.trackIds.map { remap[$0] ?? $0 }
            return playlist
        }
        if !remap.isEmpty || backfilled { save() }
    }

    func save() {
        struct Persisted: Codable { var tracks: [Track]; var playlists: [Playlist] }
        guard let data = try? JSONEncoder().encode(Persisted(tracks: tracks, playlists: playlists)) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Some exports embed a UUID in the file name — strip it wherever it
    /// appears so titles never carry DD791D29-… noise.
    private func stripUUIDs(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
            with: "",
            options: .regularExpression
        )
        return stripped
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// "Artist - Title.ext" is the common naming scheme; fall back to the file name.
    private func parseName(_ url: URL) -> (title: String, artist: String) {
        let base = stripUUIDs(
            url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        )
        guard let range = base.range(of: " - ") else { return (base, "") }
        return (String(base[range.upperBound...]).trimmingCharacters(in: .whitespaces),
                String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces))
    }

    /// Tags and the embedded cover, read straight from the file.
    private func readTags(_ url: URL) async -> (title: String?, artist: String?, album: String?, artwork: Data?) {
        let asset = AVAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return (nil, nil, nil, nil) }
        func value(_ key: AVMetadataKey) async -> String? {
            guard let item = items.first(where: { $0.commonKey == key }),
                  let text = try? await item.load(.stringValue)
            else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
        }
        var artwork: Data?
        if let item = items.first(where: { $0.commonKey == .commonKeyArtwork }) {
            artwork = try? await item.load(.dataValue)
        }
        return (await value(.commonKeyTitle), await value(.commonKeyArtist), await value(.commonKeyAlbumName), artwork)
    }

    /// SHA-256 of the file contents, so the same song is never imported twice
    /// even if it is dropped under a different name.
    private func fileHash(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func importFile(_ url: URL) async -> Track? {
        let ext = url.pathExtension.lowercased()
        guard ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"].contains(ext) else { return nil }
        guard let hash = fileHash(url) else { return nil }

        // already imported? same-size legacy tracks (no stored hash) are
        // hashed on demand and get their hash backfilled
        let sourceSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        for index in tracks.indices where tracks[index].size == sourceSize {
            let storedHash = tracks[index].hash ?? fileHash(trackURL(tracks[index]))
            if storedHash == hash {
                var dirty = false
                if tracks[index].hash == nil {
                    tracks[index].hash = hash
                    dirty = true
                }
                if tracks[index].source == nil {
                    tracks[index].source = url.path
                    dirty = true
                }
                if dirty { save() }
                return tracks[index]
            }
        }

        let id = UUID().uuidString
        let storedName = "\(id).\(ext)"
        let destination = tracksDir.appendingPathComponent(storedName)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            return nil
        }

        let parsed = parseName(url)
        let tags = await readTags(destination)
        let asset = AVAsset(url: destination)
        let duration = (try? await asset.load(.duration).seconds) ?? 0

        var cover: String?
        if let data = tags.artwork {
            let name = "cover-\(id)"
            let coverURL = tracksDir.appendingPathComponent(name)
            try? data.write(to: coverURL)
            cover = name
        }

        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // a UUID can live inside the embedded tag too, not just the file name
        let tagTitle = tags.title.map(stripUUIDs)
        let tagArtist = tags.artist.map(stripUUIDs)
        let tagAlbum = tags.album.map(stripUUIDs)
        let track = Track(
            id: id,
            title: tagTitle?.isEmpty == false ? tagTitle! : (parsed.title.isEmpty ? "Untitled" : parsed.title),
            artist: tagArtist ?? parsed.artist,
            album: tagAlbum ?? "",
            file: storedName,
            size: size,
            duration: duration,
            cover: cover,
            hash: hash,
            source: url.path
        )
        tracks.append(track)
        save()
        return track
    }

    func update(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index] = track
        save()
    }

    func delete(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
        for index in playlists.indices {
            playlists[index].trackIds.removeAll { $0 == track.id }
        }
        try? FileManager.default.removeItem(at: tracksDir.appendingPathComponent(track.file))
        if let cover = track.cover {
            try? FileManager.default.removeItem(at: tracksDir.appendingPathComponent(cover))
        }
        try? FileManager.default.removeItem(at: stemsDir.appendingPathComponent(track.id))
        let cached = (try? FileManager.default.contentsOfDirectory(
            at: cachesDir, includingPropertiesForKeys: nil
        )) ?? []
        for url in cached where url.lastPathComponent.hasPrefix("\(track.id)-") {
            try? FileManager.default.removeItem(at: url)
        }
        save()
    }

    func trackURL(_ track: Track) -> URL {
        tracksDir.appendingPathComponent(track.file)
    }

    func coverURL(_ track: Track) -> URL? {
        track.cover.map { tracksDir.appendingPathComponent($0) }
    }

    func coverImage(_ track: Track) -> NSImage? {
        guard let key = track.cover as NSString? else { return nil }
        if let img = coverCache.object(forKey: key) { return img }
        guard let url = coverURL(track), let img = NSImage(contentsOf: url) else { return nil }
        coverCache.setObject(img, forKey: key)
        return img
    }

    func stemURL(_ track: Track, _ stem: String) -> URL {
        stemsDir.appendingPathComponent("\(track.id)/\(stem).mp3")
    }

    /// Cache file for a track's derived analysis data ("main" or a stem name).
    func envelopeCacheURL(_ track: Track, _ key: String) -> URL {
        cachesDir.appendingPathComponent("\(track.id)-\(key).env")
    }

    /// Stems already on disk for a track, in mixer order.
    func existingStems(_ track: Track) -> [String] {
        let names = ["vocals", "drums", "bass", "other"]
        return names.filter {
            FileManager.default.fileExists(atPath: stemURL(track, $0).path)
        }
    }

    // Playlists

    @discardableResult
    func createPlaylist(_ name: String) -> Playlist {
        let playlist = Playlist(id: UUID().uuidString, name: name, trackIds: [])
        playlists.insert(playlist, at: 0)
        save()
        return playlist
    }

    func removePlaylist(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        save()
    }

    func renamePlaylist(_ playlist: Playlist, name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].name = name
        save()
    }

    func addToPlaylist(_ playlist: Playlist, trackId: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }),
              !playlists[index].trackIds.contains(trackId) else { return }
        playlists[index].trackIds.append(trackId)
        save()
    }

    func removeFromPlaylist(_ playlist: Playlist, trackId: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].trackIds.removeAll { $0 == trackId }
        save()
    }
}
