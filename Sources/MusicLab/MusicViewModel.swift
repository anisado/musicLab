import AVFoundation
import Combine
import Foundation

struct StemMix: Equatable {
    var gain: Double = 1
    var muted = false
    var solo = false
    /// Mixer knob: -1 cuts the stem to silence, 0 is unity, +1 ducks every
    /// other stem to silence — effectively solo.
    var knob = 0.0
}

@MainActor
final class MusicViewModel: ObservableObject {
    /// The decks — A always exists, B joins when dual-deck mode is on.
    let deckA = Deck(id: 0)
    let deckB = Deck(id: 1)

    @Published var dualDeck = UserDefaults.standard.bool(forKey: "dualDeck") {
        didSet {
            UserDefaults.standard.set(dualDeck, forKey: "dualDeck")
            if !dualDeck {
                deckB.player.pause()
                activeDeckId = 0
            }
            applyOutput()
        }
    }
    /// 0 = deck A only, 1 = deck B only — equal-power crossfade.
    @Published var crossfader = 0.0 { didSet { applyOutput() } }
    /// Which deck the library loads into when two are showing.
    @Published var activeDeckId = 0

    var decks: [Deck] { [deckA, deckB] }
    var active: Deck { decks[activeDeckId] }
    /// Shorthand used by non-deck views (library row highlight etc.).
    var currentId: String? { active.trackId }
    var current: Track? { active.track }

    @Published var shuffle = false
    @Published var repeatMode = "off"
    @Published var search = ""
    @Published var playlistId: String?
    @Published var playlistName = ""
    @Published var queueing = false
    @Published var error: String?

    let separator = Separator()
    var store: Store!
    private var timer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var stemsCache: [String: [String]] = [:]

    init() {
        deckA.model = self
        deckB.model = self
        applyOutput()
        // the Settings scene writes UserDefaults directly (@AppStorage) — pick
        // up changes made there without a restart
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pref = UserDefaults.standard.bool(forKey: "dualDeck")
                if pref != self.dualDeck { self.dualDeck = pref }
            }
        }
    }

    /// Master volume lives on each deck's trim × crossfader — recomputed
    /// whenever either changes.
    func applyOutput() {
        // equal-power crossfade: constant loudness through the middle
        let wA = dualDeck ? cos(crossfader * .pi / 2) : 1.0
        let wB = dualDeck ? sin(crossfader * .pi / 2) : 0.0
        deckA.player.volume = Float(deckA.trim * wA)
        deckB.player.volume = Float(deckB.trim * wB)
    }

    func attach(_ store: Store) {
        guard self.store == nil else { return }
        self.store = store
        // nested objects publish their own changes; forward them so views
        // observing the model redraw — without this, pausing would not flip
        // the play button back to ▶
        separator.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        for deck in decks {
            // only the player is forwarded — the library's play/pause icons
            // need it. deck.objectWillChange is deliberately NOT forwarded:
            // progress ticks at 10 Hz would repaint the whole window,
            // library table included. deck cards observe their deck directly.
            deck.player.objectWillChange
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &subscriptions)
        }
        timer?.invalidate()
        // 10 Hz is plenty for labels, the seek slider and end-of-track
        // detection — the waveform reads player.time at display rate itself
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for deck in self.decks where deck.player.playing {
                    let t = deck.player.time
                    if abs(t - deck.progress) > 0.02 { deck.progress = t }
                    // detect end of track by polling the player nodes; this is
                    // more reliable than scheduleSegment completion for mp3s
                    if !deck.player.running {
                        deck.player.playing = false
                        deck.trackEnded()
                    }
                }
            }
        }
    }

    // MARK: - selection

    var playlist: Playlist? {
        store?.playlists.first { $0.id == playlistId }
    }

    var visible: [Track] {
        guard let store else { return [] }
        let pool = playlist?.trackIds.compactMap { id in store.tracks.first { $0.id == id } } ?? store.tracks
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return pool }
        return pool.filter {
            "\($0.title) \($0.artist) \($0.album)".lowercased().contains(needle)
        }
    }

    func stemsOnDisk(_ track: Track) -> [String] {
        if let cached = stemsCache[track.id] { return cached }
        let stems = store.existingStems(track)
        stemsCache[track.id] = stems
        return stems
    }

    func cacheStems(_ id: String, _ stems: [String]) { stemsCache[id] = stems }

    /// Separation state for a library row: a running job beats files on disk.
    func stemState(_ track: Track) -> StemState {
        if let job = separator.jobs[track.id], case .running = job { return job }
        let stems = stemsOnDisk(track)
        if !stems.isEmpty { return .done(stems: stems) }
        return separator.jobs[track.id] ?? .idle
    }

    // MARK: - metadata

    /// Full tag read off the file via the mutagen helper; falls back to the
    /// library record when the helper is unavailable.
    func readTags(_ track: Track) async -> TrackTags {
        if let store, let tags = await Tagger.read(store.trackURL(track)) {
            return tags
        }
        return TrackTags(
            title: track.title, artist: track.artist, album: track.album,
            genre: track.genre ?? "", year: track.year ?? "",
            trackNumber: track.trackNumber ?? "",
            bpm: track.bpm.map { "\(Int($0.rounded()))" } ?? "",
            comment: track.comment ?? "", hasArtwork: track.cover != nil
        )
    }

    /// Write tags into the audio file, then mirror the library-facing fields
    /// back onto the track record.
    @discardableResult
    func saveTags(_ track: Track, _ tags: TrackTags, artwork: URL?) async -> Bool {
        guard let store else { return false }
        let ok = await Tagger.write(store.trackURL(track), tags: tags, artwork: artwork)

        // mirror into the original file too when we know where it lives —
        // the library copy is authoritative, the source write is best-effort
        if AppPrefs.mirrorToSource, let source = track.source, !source.isEmpty,
           FileManager.default.fileExists(atPath: source) {
            _ = await Tagger.write(URL(fileURLWithPath: source), tags: tags, artwork: artwork)
        }

        var updated = track
        if !tags.title.isEmpty { updated.title = tags.title }
        updated.artist = tags.artist
        updated.album = tags.album
        updated.genre = tags.genre.isEmpty ? nil : tags.genre
        updated.year = tags.year.isEmpty ? nil : tags.year
        updated.trackNumber = tags.trackNumber.isEmpty ? nil : tags.trackNumber
        updated.comment = tags.comment.isEmpty ? nil : tags.comment
        updated.rating = tags.rating > 0 ? tags.rating : nil
        if let bpm = Double(tags.bpm), bpm > 0 {
            updated.bpm = bpm
            updated.bpmSource = "manual"
        }
        if let artwork, let data = try? Data(contentsOf: artwork) {
            // fresh name each save — the cover cache keys on the file name
            let name = "cover-\(track.id)-\(Int(Date().timeIntervalSince1970))"
            try? data.write(to: store.tracksDir.appendingPathComponent(name))
            if let old = track.cover {
                try? FileManager.default.removeItem(at: store.tracksDir.appendingPathComponent(old))
            }
            updated.cover = name
        }
        store.update(updated)
        return ok
    }

    /// Embedded artwork pulled out of the file for the tag editor preview.
    func extractArtwork(_ track: Track) async -> URL? {
        guard let store else { return nil }
        return await Tagger.extractArtwork(store.trackURL(track))
    }

    // MARK: - tempo

    /// Detect the tempo off the isolated drums stem, or the full mix when there
    /// are no stems yet. Works on any track — the result is stored, and decks
    /// currently playing it get the live beat grid.
    func detectTempo(trackId: String) async {
        guard let track = store.tracks.first(where: { $0.id == trackId })
        else { return }
        for deck in decks where deck.trackId == trackId { deck.analysing = true }
        defer { for deck in decks where deck.trackId == trackId { deck.analysing = false } }
        let useDrums = stemsOnDisk(track).contains("drums")
        let url = useDrums ? store.stemURL(track, "drums") : store.trackURL(track)
        let analysis = await Task.detached(priority: .utility) { () -> BeatAnalysis? in
            guard let samples = try? decodeMono(url) else { return nil }
            return Bpm.detect(samples)
        }.value
        applyTempo(analysis, source: useDrums ? "drums" : "mix", trackId: trackId)
    }

    /// A manually corrected or drums-derived BPM is trusted and only takes the
    /// beat offset; a full-mix guess is replaced by anything better. The result
    /// is stored on the track even when no deck is playing it — that is how
    /// batch analysis fills in the library.
    private func applyTempo(_ analysis: BeatAnalysis?, source: String, trackId: String) {
        guard let analysis,
              var track = store.tracks.first(where: { $0.id == trackId })
        else { return }
        let keep = track.bpm != nil && track.bpmSource != "mix"
        if keep && source == "mix" && track.bpmSource == "drums" { return }

        let map: [TempoSection]?
        if keep {
            map = track.bpmMap ?? (analysis.map != nil
                && abs(analysis.bpm - track.bpm!) / track.bpm! < 0.03 ? analysis.map : nil)
        } else {
            map = analysis.map
        }
        for deck in decks where deck.trackId == trackId {
            deck.beat = BeatAnalysis(bpm: keep ? track.bpm! : analysis.bpm,
                                     offset: analysis.offset, map: map)
        }

        if !keep {
            track.bpm = analysis.bpm
            track.bpmSource = source
            track.bpmMap = map
            track.beatOffset = analysis.offset
            store.update(track)
        } else if (track.bpmMap == nil && map != nil) || track.beatOffset == nil {
            track.bpmMap = track.bpmMap ?? map
            track.beatOffset = analysis.offset
            store.update(track)
        }
    }

    /// Whether one of the current tracks is currently being separated.
    private func isRunning(_ track: Track) -> Bool {
        if case .running = separator.jobs[track.id] { return true }
        return false
    }

    // MARK: - import & queue

    func importFiles(_ urls: [URL]) async {
        for url in urls {
            _ = await store.importFile(url)
        }
        if AppPrefs.autoAnalyze { queueSeparation(all: false) }
    }

    /// Queue separation for every listed track; `all` also re-runs done tracks.
    func queueSeparation(all: Bool) {
        guard let store else { return }
        queueing = true
        let targets = visible.filter { all || stemsOnDisk($0).isEmpty }
            .filter { !isRunning($0) }
        Task {
            for track in targets {
                let produced = await separator.separate(
                    track: track,
                    source: store.trackURL(track),
                    stemsDir: store.stemsDir
                )
                if produced.isEmpty { continue }
                stemsCache[track.id] = produced
                // every queued track gets its tempo read off the fresh drums
                // stem, not just the one that happens to be playing
                await detectTempo(trackId: track.id)
                for deck in decks where deck.trackId == track.id {
                    await deck.reloadStems(produced)
                }
            }
            queueing = false
        }
    }
}
