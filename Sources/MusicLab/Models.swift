import Foundation

/// One tempo section of a track: `bpm` applies from `start` seconds until the
/// next section. `phase` is the absolute time of a beat inside the section, so
/// the grid lands on the section's own beats rather than drifting across a
/// tempo change.
struct TempoSection: Codable, Equatable {
    var start: Double
    var bpm: Double
    var phase: Double?
}

struct Track: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var file: String
    var size: Int
    var duration: Double
    var cover: String?
    var bpm: Double?
    /// "mix" = guessed on the full track, "drums" = read off the isolated stem,
    /// "manual" = corrected by hand; a weaker source may always be replaced.
    var bpmSource: String?
    var bpmMap: [TempoSection]?
    /// Absolute time of the first beat — persisted so the beat grid can be
    /// drawn on load without re-running detection.
    var beatOffset: Double?
    /// SHA-256 of the audio file, so re-imports of the same song are deduped.
    var hash: String?
    /// Where the file originally came from, so tag edits can be mirrored
    /// back to the user's own copy on disk.
    var source: String?
    var genre: String?
    var year: String?
    var trackNumber: String?
    var comment: String?
    var rating: Int?
}

struct Playlist: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var trackIds: [String]
}

enum StemState: Equatable {
    case idle
    case running(progress: Double)
    case done(stems: [String])
    case failed(String)

    var stems: [String] {
        if case .done(let stems) = self { return stems }
        return []
    }

    var progress: Double {
        if case .running(let progress) = self { return progress }
        return 0
    }
}

/// What the beat detector found: headline tempo, first-beat offset and an
/// optional tempo map for tracks that do not keep one tempo.
struct BeatAnalysis {
    var bpm: Double
    var offset: Double
    var map: [TempoSection]?

    /// Beat times inside [from, to], stepping with each map section so the grid
    /// follows tempo changes. A section with its own `phase` starts on its own
    /// aligned beat; otherwise the beat clock carries over the boundary, so a
    /// tempo change lands on the next beat rather than mid-bar.
    func beats(from: Double, to: Double) -> [(time: Double, index: Int)] {
        let map = map?.isEmpty == false ? map! : [TempoSection(start: 0, bpm: bpm)]
        var beats: [(Double, Int)] = []
        var index = 0
        var carry = offset
        for (i, section) in map.enumerated() {
            let period = 60 / section.bpm
            let end = i + 1 < map.count ? map[i + 1].start : .infinity
            var time = section.phase ?? carry
            while time < section.start { time += period }
            while time < end {
                if time > to { return beats }
                if time >= from { beats.append((time, index)) }
                time += period
                index += 1
            }
            carry = time
        }
        return beats
    }
}
