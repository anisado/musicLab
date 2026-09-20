import Combine
import Foundation

/// One deck: its own player, track, stem mix, waveform analysis and tempo.
/// In single-deck mode only deck A is visible; deck B sleeps until the
/// two-deck toggle turns on.
@MainActor
final class Deck: ObservableObject, Identifiable {
    let id: Int
    weak var model: MusicViewModel?

    var label: String { id == 0 ? "A" : "B" }

    @Published var trackId: String?
    @Published var progress = 0.0
    @Published var peaks: [Float]?
    @Published var bands: BandEnvelope?
    @Published var stemPeaks: [String: [Float]]?
    @Published var stemBands: [String: BandEnvelope]?
    @Published var beat: BeatAnalysis?
    @Published var analysing = false
    @Published var peaksLoading = false
    @Published var zoom = 32.0
    @Published var mix: [String: StemMix] = [:] { didSet { applyMix() } }
    /// Per-deck trim — combined with the crossfader into player.volume.
    @Published var trim = 1.0 { didSet { model?.applyOutput() } }

    let player = Player()
    /// Waveform bitmap cache — model-owned so it survives view recreation.
    let strip = StripCache()
    private var pendingTempo = false
    private var subscriptions: Set<AnyCancellable> = []

    init(id: Int) {
        self.id = id
        // deck views observe the deck only — player state (play/pause) is
        // folded in so one subscription covers everything on the card
        player.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }

    private var store: Store? { model?.store }

    var track: Track? {
        store?.tracks.first { $0.id == trackId }
    }

    var separated: Bool {
        guard let track else { return false }
        return !(model?.stemsOnDisk(track).isEmpty ?? true)
    }

    var currentStems: [String] {
        guard let track else { return [] }
        return model?.stemsOnDisk(track) ?? []
    }

    /// Visible window, always centered on the fixed playhead. Matches
    /// `WaveformView.window`; the ends are clamped to the track only for the
    /// ruler labels.
    var waveformWindow: (from: Double, to: Double) {
        let duration = player.duration
        guard duration > 0 else { return (0, 0) }
        let span = duration / zoom
        let from = progress - span / 2
        return (max(0, from), min(duration, from + span))
    }

    // MARK: - playback

    func toggle(_ track: Track) {
        if track.id == trackId {
            player.playing ? player.pause() : player.play(from: progress)
            return
        }
        trackId = track.id
        start(track)
    }

    private func start(_ track: Track) {
        guard let store else { return }
        // seed the beat grid from the stored analysis — the chip and grid
        // show instantly; the background re-detect refines the offset later
        if let bpm = track.bpm {
            beat = BeatAnalysis(bpm: bpm, offset: track.beatOffset ?? 0, map: track.bpmMap)
        } else {
            beat = nil
        }
        peaks = nil
        bands = nil
        stemPeaks = nil
        stemBands = nil
        strip.image = nil
        strip.key = ""
        mix = [:]
        zoom = 32
        progress = 0
        pendingTempo = false
        peaksLoading = true

        let stems = model?.stemsOnDisk(track) ?? []
        var sources: [String: URL] = [:]
        if stems.isEmpty {
            sources["main"] = store.trackURL(track)
        } else {
            for stem in stems { sources[stem] = store.stemURL(track, stem) }
        }
        player.load(sources)
        player.play()

        let trackId = track.id
        let trackURL = store.trackURL(track)
        let cacheURL = store.envelopeCacheURL(track, "main")
        Task.detached(priority: .utility) { [weak self, trackURL, cacheURL, stems] in
            // the envelope is cached as a flat binary — after the first load
            // a track never gets decoded for the waveform again
            let decoded: (peaks: [Float], bands: BandEnvelope)? = {
                if let cached = readEnvelopeCache(cacheURL) { return cached }
                guard let samples = try? decodeMono(trackURL, rate: 4410) else { return nil }
                let peaks = peakEnvelope(samples, rate: 4410)
                let bands = bandEnvelope(samples, rate: 4410)
                writeEnvelopeCache(cacheURL, peaks: peaks, bands: bands)
                return (peaks, bands)
            }()
            guard let self = self else { return }
            await MainActor.run {
                guard self.trackId == trackId else { return }
                self.peaks = decoded?.peaks
                self.bands = decoded?.bands
                self.peaksLoading = false
            }
            // if stems already exist, decode them for the stem-colored
            // waveform and read the tempo off the drums
            if !stems.isEmpty {
                await self.analyseStemPeaks(trackId: trackId)
                if stems.contains("drums") {
                    await self.model?.detectTempo(trackId: trackId)
                }
            }
        }
    }

    func seek(_ seconds: Double) {
        let clamped = min(max(seconds, 0), player.duration)
        progress = clamped
        player.seek(clamped)
    }

    func step(_ offset: Int) {
        guard let model else { return }
        let list = model.visible
        guard !list.isEmpty else { return }
        if model.shuffle {
            let pool = list.filter { $0.id != trackId }
            if let next = pool.randomElement() ?? list.first { toggle(next) }
            return
        }
        let index = list.firstIndex { $0.id == trackId } ?? 0
        let next = list[(index + offset + list.count) % list.count]
        toggle(next)
    }

    func trackEnded() {
        guard let model else { return }
        if model.repeatMode == "one" {
            progress = 0
            player.play(from: 0)
        } else if model.repeatMode == "all" || model.shuffle {
            step(1)
        }
    }

    /// Reload the playing file set after (re)separation — keeps position
    /// and play state, then re-reads stems waveforms and tempo.
    func reloadStems(_ produced: [String]) async {
        guard let store, let track, !produced.isEmpty else { return }
        var sources: [String: URL] = [:]
        for stem in produced { sources[stem] = store.stemURL(track, stem) }
        let wasPlaying = player.playing
        let at = progress
        player.load(sources)
        if wasPlaying { player.play(from: at) }
        applyMix()
        await analyseStemPeaks(trackId: track.id)
    }

    // MARK: - tempo

    func detectTempo() async {
        guard let trackId else { return }
        await model?.detectTempo(trackId: trackId)
    }

    /// Half and double a tempo fit the same beats, so let the reading be corrected.
    func scaleTempo(_ factor: Double) {
        guard var track else { return }
        let tempo = beat?.bpm ?? track.bpm
        guard let tempo else { return }
        let scaled = (tempo * factor * 10).rounded() / 10
        let scaledMap = (beat?.map ?? track.bpmMap)?.map {
            TempoSection(start: $0.start, bpm: ($0.bpm * factor * 10).rounded() / 10, phase: $0.phase)
        }
        beat = BeatAnalysis(bpm: scaled, offset: beat?.offset ?? 0, map: scaledMap)
        track.bpm = scaled
        track.bpmSource = "manual"
        if let scaledMap { track.bpmMap = scaledMap }
        store?.update(track)
    }

    // MARK: - stems

    /// One click: separate the stems if needed, then read the tempo off the drums.
    func analyse(force: Bool = false) {
        guard let track else { return }
        if separated, !force {
            pendingTempo = false
            Task { await detectTempo() }
            return
        }
        pendingTempo = true
        Task { await runSeparation(track) }
    }

    private func runSeparation(_ track: Track) async {
        guard let model, let store else { return }
        let produced = await model.separator.separate(
            track: track,
            source: store.trackURL(track),
            stemsDir: store.stemsDir
        )
        if !produced.isEmpty { model.cacheStems(track.id, produced) }
        guard trackId == track.id, !produced.isEmpty else { return }
        // rewire playback to the fresh stems and re-read the waveforms
        await reloadStems(produced)
        if pendingTempo || track.bpmSource == "mix" || track.bpm == nil {
            pendingTempo = false
            await detectTempo()
        }
    }

    func analyseStemPeaks(trackId: String) async {
        guard let model, let store,
              let track = store.tracks.first(where: { $0.id == trackId })
        else { return }
        let stemNames = model.stemsOnDisk(track)
        let urls = stemNames.reduce(into: [:]) {
            $0[$1] = (store.stemURL(track, $1), store.envelopeCacheURL(track, $1))
        }
        // decode all stems in parallel — each is an independent file read,
        // and each result is cached so later loads skip the decode entirely
        let analysed = await withTaskGroup(
            of: (String, [Float], BandEnvelope)?.self
        ) { group -> (peaks: [String: [Float]], bands: [String: BandEnvelope]) in
            for (stem, pair) in urls {
                group.addTask(priority: .utility) {
                    if let cached = readEnvelopeCache(pair.1) {
                        return (stem, cached.peaks, cached.bands)
                    }
                    guard let samples = try? decodeMono(pair.0, rate: 4410) else { return nil }
                    let peaks = peakEnvelope(samples, rate: 4410)
                    let bands = bandEnvelope(samples, rate: 4410)
                    writeEnvelopeCache(pair.1, peaks: peaks, bands: bands)
                    return (stem, peaks, bands)
                }
            }
            var peaks: [String: [Float]] = [:]
            var bands: [String: BandEnvelope] = [:]
            for await result in group {
                if let (stem, envelope, band) = result {
                    peaks[stem] = envelope
                    bands[stem] = band
                }
            }
            return (peaks, bands)
        }
        guard self.trackId == trackId else { return }
        stemPeaks = analysed.peaks
        stemBands = analysed.bands
    }

    // MARK: - mix

    /// How loud each stem is in the current mix. The knob cuts its own stem
    /// when turned left and ducks all other stems when turned right.
    private func effectiveGain(_ stem: String) -> Float {
        let soloed = currentStems.contains { mix[$0]?.solo == true }
        let settings = mix[stem] ?? StemMix()
        let audible = soloed ? settings.solo : !settings.muted
        guard audible else { return 0 }
        // right-turned stems form the isolate group — members play at full
        // level and are never ducked, so two or three knobs right means you
        // hear exactly those stems
        if settings.knob > 0 { return Float(settings.gain) }
        let duck = currentStems
            .map { max(0, mix[$0]?.knob ?? 0) }
            .max() ?? 0
        return Float(1 + min(0, settings.knob)) * Float(settings.gain) * Float(1 - duck)
    }

    private func applyMix() {
        for stem in currentStems { player.setGain(stem, effectiveGain(stem)) }
    }

    func setStem(_ stem: String, patch: (inout StemMix) -> Void) {
        var settings = mix[stem] ?? StemMix()
        patch(&settings)
        mix[stem] = settings
        applyMix()
    }
}
