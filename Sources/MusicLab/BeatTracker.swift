import AVFoundation
import Foundation

/// Beat tracking through `stems_tool.py beats` (madmom's RNN + DBN tracker,
/// librosa as fallback). Unlike the built-in period estimate it returns every
/// beat, so tempo changes inside a track become sections of the tempo map.
enum BeatTracker {
    static var available: Bool { Tagger.helper("beats") != nil }

    private struct Reply: Decodable {
        var engine: String?
        var beats: [Double]?
        var error: String?
    }

    /// Track the beats of `url`; nil when the helper is missing or found no beat.
    static func detect(_ url: URL) async -> BeatAnalysis? {
        guard let prefix = Tagger.helper("beats") else { return nil }
        let minBpm = AppPrefs.bpmMin, maxBpm = AppPrefs.bpmMax
        return await Task.detached(priority: .utility) { () -> BeatAnalysis? in
            // the trackers want plain PCM — hand them a mono wav instead of
            // relying on the python side to decode mp3/m4a
            guard let wav = writeWav(url) else { return nil }
            defer { try? FileManager.default.removeItem(at: wav) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: prefix[0])
            process.arguments = Array(prefix.dropFirst()) + [wav.path, "\(minBpm)", "\(maxBpm)"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let reply = try? JSONDecoder().decode(Reply.self, from: data),
                  let beats = reply.beats
            else { return nil }
            return analysis(beats: beats)
        }.value
    }

    private static func writeWav(_ url: URL) -> URL? {
        let rate = 44100.0
        guard let samples = try? decodeMono(url, rate: rate),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("musiclab-beats-\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: wav, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        } catch {
            return nil
        }
        return wav
    }

    /// Turn beat times into a headline tempo plus a tempo map: neighbouring
    /// beats whose local tempo agrees form one section, each anchored on its
    /// own first beat so the grid never drifts across a change.
    static func analysis(beats raw: [Double]) -> BeatAnalysis? {
        let beats = raw.sorted()
        guard beats.count >= 4 else { return nil }
        var intervals: [Double] = []
        for i in 1 ..< beats.count { intervals.append(beats[i] - beats[i - 1]) }
        let median = intervals.sorted()[intervals.count / 2]
        guard median > 0 else { return nil }

        // median-smooth the local period so a single late beat does not
        // open a section of its own
        let half = 4
        var local = intervals
        for i in intervals.indices {
            let window = intervals[max(0, i - half) ... min(intervals.count - 1, i + half)]
            local[i] = window.sorted()[window.count / 2]
        }

        struct Section { var first: Int; var count: Int; var sum: Double }
        var sections: [Section] = []
        for (i, period) in local.enumerated() {
            if var current = sections.last, abs(period / (current.sum / Double(current.count)) - 1) <= 0.025 {
                current.count += 1
                current.sum += intervals[i]
                sections[sections.count - 1] = current
            } else {
                sections.append(Section(first: i, count: 1, sum: intervals[i]))
            }
        }
        // sections shorter than two bars are noise — fold them into the
        // section before (or after, for a short intro)
        var merged: [Section] = []
        for section in sections {
            if var previous = merged.last, section.count < 8 || previous.count < 8 {
                previous.count += section.count
                previous.sum += section.sum
                merged[merged.count - 1] = previous
            } else {
                merged.append(section)
            }
        }

        let bpm = (60 / median * 100).rounded() / 100
        var map: [TempoSection]? = nil
        if merged.count >= 2 {
            map = merged.enumerated().map { index, section in
                TempoSection(
                    start: index == 0 ? 0 : (beats[section.first] * 100).rounded() / 100,
                    bpm: (60 / (section.sum / Double(section.count)) * 100).rounded() / 100,
                    phase: (beats[section.first] * 100).rounded() / 100
                )
            }
        }
        return BeatAnalysis(bpm: bpm, offset: beats[0], map: map)
    }
}
