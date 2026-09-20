import AVFoundation
import CoreAudio
import Foundation

/// Plays one file, or one file per stem mixed together: every stem gets its own
/// player node feeding a gain mixer into the main mixer, so mute/solo/faders
/// are just volume changes and all stems share one render timeline.
final class Player: ObservableObject {
    private let engine = AVAudioEngine()
    private var players: [String: AVAudioPlayerNode] = [:]
    private var faders: [String: AVAudioMixerNode] = [:]
    private var files: [String: AVAudioFile] = [:]

    private var startOffset: Double = 0
    /// Host time at which the current segment starts rendering — every stem
    /// node is started at exactly this time, so it anchors the playhead.
    private var anchorHostTime: UInt64 = 0
    private var fileRate: Double = 44100
    private var fileFrames: AVAudioFramePosition = 0
    private var playGraceUntil = Date.distantPast
    private var cachedLatency: Double = 0
    private var latencyCheck = Date.distantPast

    @Published var playing = false

    var volume: Float = 1 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    var duration: Double {
        fileFrames > 0 ? Double(fileFrames) / fileRate : 0
    }

    /// Load a full track ("main") or a set of stems and rewire the graph.
    func load(_ sources: [String: URL]) {
        stop()
        engine.stop()
        for node in players.values { engine.detach(node) }
        for node in faders.values { engine.detach(node) }
        players = [:]
        faders = [:]
        files = [:]

        for (name, url) in sources {
            guard let file = try? AVAudioFile(forReading: url) else { continue }
            files[name] = file
            let player = AVAudioPlayerNode()
            let fader = AVAudioMixerNode()
            engine.attach(player)
            engine.attach(fader)
            engine.connect(player, to: fader, format: file.processingFormat)
            engine.connect(fader, to: engine.mainMixerNode, format: nil)
            players[name] = player
            faders[name] = fader
        }
        if let file = files.values.first {
            fileRate = file.processingFormat.sampleRate
            fileFrames = file.length
        }
        engine.prepare()
        try? engine.start()
    }

    private static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    /// A shared future render time keeps every stem node sample-aligned.
    private func startTime() -> AVAudioTime {
        AVAudioTime(hostTime: mach_absolute_time() + UInt64(0.1 * Self.ticksPerSecond))
    }

    /// Queue the segment on every stem node and start them all at one shared
    /// host time. The segment is scheduled at the head of each player's
    /// timeline and the *player* is started at `when`, so segment start and
    /// `anchorHostTime` coincide exactly — no dependence on the node's
    /// sample counter, which is not reliably reset across stop/play.
    private func schedule(from seconds: Double) -> Bool {
        let startFrame = AVAudioFramePosition(min(max(seconds, 0), duration) * fileRate)
        let remaining = fileFrames - startFrame
        guard remaining > 0 else { return false }
        startOffset = Double(startFrame) / fileRate
        let when = startTime()
        anchorHostTime = when.hostTime
        for (name, player) in players {
            player.stop()
            // no completion handler: with compressed files it can fire when the
            // data is consumed rather than played — the view model polls
            // `running` instead, which is reliable
            player.scheduleSegment(
                files[name]!,
                startingFrame: startFrame,
                frameCount: AVAudioFrameCount(remaining),
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { _ in }
        }
        for player in players.values { player.play(at: when) }
        return true
    }

    func play(from seconds: Double = 0) {
        guard !players.isEmpty else { return }
        guard schedule(from: min(max(seconds, 0), max(duration - 0.1, 0))) else { return }
        playGraceUntil = Date().addingTimeInterval(0.4)
        playing = true
    }

    func pause() {
        let position = time
        for player in players.values { player.pause() }
        startOffset = position
        playing = false
    }

    func stop() {
        for player in players.values { player.stop() }
        startOffset = 0
        playing = false
    }

    func seek(_ seconds: Double) {
        let wasPlaying = playing
        for player in players.values { player.stop() }
        if wasPlaying { play(from: seconds) } else { startOffset = seconds }
    }

    /// True while a scheduled segment is actually rendering; goes false when it
    /// plays out — that's how the end of the track is detected.
    var running: Bool {
        Date() < playGraceUntil || players.values.contains { $0.isPlaying }
    }

    /// How long rendered audio takes to reach the speakers: safety offset,
    /// device and stream latency, and the I/O buffer. Read live from the
    /// default output device so it follows whatever output is in use,
    /// cached briefly to avoid hammering the HAL.
    private var outputLatency: Double {
        let now = Date()
        if now.timeIntervalSince(latencyCheck) > 0.5 {
            latencyCheck = now
            // HAL queries can take a few ms — keep them off the render path
            Task.detached { [weak self] in
                let latency = Self.queryLatency()
                guard let self else { return }
                await MainActor.run { self.cachedLatency = latency }
            }
        }
        return cachedLatency
    }

    private static func queryLatency() -> Double {
        var deviceID = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return 0 }

        func frames(_ selector: AudioObjectPropertySelector) -> UInt32 {
            var value = UInt32(0)
            var propSize = UInt32(MemoryLayout<UInt32>.size)
            var prop = address
            prop.mSelector = selector
            prop.mScope = kAudioObjectPropertyScopeOutput
            AudioObjectGetPropertyData(deviceID, &prop, 0, nil, &propSize, &value)
            return value
        }

        var rate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = address
        rateAddress.mSelector = kAudioDevicePropertyNominalSampleRate
        AudioObjectGetPropertyData(deviceID, &rateAddress, 0, nil, &rateSize, &rate)
        guard rate > 0 else { return 0 }

        var total = Double(frames(kAudioDevicePropertySafetyOffset)
            + frames(kAudioDevicePropertyLatency)
            + frames(kAudioDevicePropertyBufferFrameSize))

        // the output stream carries its own latency on top of the device's
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize) == noErr,
           streamSize > 0 {
            var streams = [AudioStreamID](repeating: 0, count: Int(streamSize) / MemoryLayout<AudioStreamID>.size)
            AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &streamSize, &streams)
            if let stream = streams.first {
                var latency = UInt32(0)
                var latencySize = UInt32(MemoryLayout<UInt32>.size)
                var latencyAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioStreamPropertyLatency,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectGetPropertyData(stream, &latencyAddress, 0, nil, &latencySize, &latency)
                total += Double(latency)
            }
        }

        return total / rate
    }

    /// Where playback currently sits in the file, in seconds: the segment
    /// start plus the host time elapsed since the nodes were started, minus
    /// the presentation latency so it matches what is actually audible.
    /// Host-clock based, so it is smooth at display rate and cannot jump
    /// when a node's sample counter carries over from an earlier run.
    var time: Double {
        guard playing else { return startOffset }
        let elapsed = (Double(mach_absolute_time()) - Double(anchorHostTime)) / Self.ticksPerSecond
            - outputLatency
        return min(startOffset + max(elapsed, 0), duration)
    }

    func setGain(_ stem: String, _ gain: Float) {
        faders[stem]?.outputVolume = gain
    }
}
