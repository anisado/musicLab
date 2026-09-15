import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Identity colors for stems — user-configurable in Settings.
private func stemColor(_ stem: String) -> Color { WavePrefs.stemColor(stem) }

private func clock(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = max(0, Int(seconds))
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var model: MusicViewModel
    @State private var importing = false
    @State private var editing: Track?
    @State private var selection: Set<Track.ID> = []
    @State private var browsing = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 12) {
            if model.dualDeck {
                HStack(alignment: .top, spacing: 12) {
                    DeckCardView(deck: model.deckA)
                    DeckCardView(deck: model.deckB)
                }
                mixerRow
            } else {
                DeckCardView(deck: model.deckA)
            }
            playlistsBar
            libraryCard
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.14),
                    Color(red: 0.02, green: 0.02, blue: 0.07)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .onAppear { model.attach(store) }
        .sheet(item: $editing) { track in
            TagEditor(track: track, model: model, store: store) {
                editing = $0
                selection = [$0.id]
            }
        }
        .sheet(isPresented: $browsing) {
            MetadataBrowser(model: model, store: store, selection: selection)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.importFiles(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil)
                    else { return }
                    Task { @MainActor in await model.importFiles([url]) }
                }
            }
            return true
        }
    }

    // MARK: - decks

    /// The two-deck mixer: channel trim + equal-power crossfader between A and B.
    private var mixerRow: some View {
        HStack(spacing: 16) {
            Text("MIXER").font(.caption.bold()).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("A").font(.caption.bold())
                Text("\(Int(model.deckA.trim * 100))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $model.crossfader, in: 0 ... 1)
                .tint(.cyan)
                .help("crossfader — center plays both decks equally")
            HStack(spacing: 6) {
                Text("\(Int(model.deckB.trim * 100))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Text("B").font(.caption.bold())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    LinearGradient(colors: [.cyan.opacity(0.5), .purple.opacity(0.4)],
                                   startPoint: .leading, endPoint: .trailing),
                    lineWidth: 1
                )
        )
    }

    /// One deck card — it observes just its own deck, so 10 Hz progress ticks
    /// repaint this card instead of the whole window.
    private struct DeckCardView: View {
        @ObservedObject var deck: Deck
        @EnvironmentObject private var model: MusicViewModel
        @EnvironmentObject private var store: Store
        /// Hovered by a library drag — shows the drop highlight.
        @State private var targeted = false

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    coverView
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if model.dualDeck {
                                Text(deck.label)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(model.activeDeckId == deck.id ? Color.accentColor : Color.secondary.opacity(0.3),
                                                in: Capsule())
                            }
                            Text(deck.track?.title ?? "Nothing playing").font(.headline)
                        }
                        Text(deck.track.map { [$0.artist, $0.album].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "pick a track from the library")
                            .font(.subheadline).foregroundStyle(.secondary)
                        chipsRow
                    }
                    Spacer()
                }
                waveformRuler
                waveform
                transportRow
                stemsRow
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        targeted
                            ? LinearGradient(colors: [.green.opacity(0.9), .cyan.opacity(0.9)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
                            : model.dualDeck && model.activeDeckId == deck.id
                            ? LinearGradient(colors: [.cyan.opacity(0.9), .blue.opacity(0.6), .purple.opacity(0.7)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [.cyan.opacity(0.6), .blue.opacity(0.35), .purple.opacity(0.5)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: targeted || (model.dualDeck && model.activeDeckId == deck.id) ? 2 : 1
                    )
            )
            .shadow(color: .cyan.opacity(0.15), radius: 18)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                if model.dualDeck { model.activeDeckId = deck.id }
            })
            .onDrop(of: [UTType.plainText], isTargeted: $targeted) { providers in
                providers.first?.loadObject(ofClass: NSString.self) { item, _ in
                    guard let id = item as? String else { return }
                    Task { @MainActor in
                        guard let track = store.tracks.first(where: { $0.id == id }) else { return }
                        model.activeDeckId = deck.id
                        deck.toggle(track)
                    }
                }
                return true
            }
        }

        private var coverView: some View {
            Group {
                if let track = deck.track, let image = store.coverImage(track) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Text("♫").font(.title).foregroundStyle(.cyan.opacity(0.7))
                }
            }
            .frame(width: 64, height: 64)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        LinearGradient(colors: [.cyan.opacity(0.7), .purple.opacity(0.5)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            )
            .shadow(color: .cyan.opacity(0.25), radius: 8)
        }

        private var waveformRuler: some View {
            let (from, to) = deck.waveformWindow
            return HStack {
                Text(clock(from)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Text("zoom").font(.caption).foregroundStyle(.secondary)
                    Button { deck.zoom = max(deck.zoom / 2, 1) } label: {
                        Text("−").frame(width: 14)
                    }
                    .chip()
                    .disabled(deck.zoom <= 1)
                    Text(deck.zoom > 1 ? "\(deck.zoom, specifier: "%.1f")×" : "1×")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 32)
                    Button { deck.zoom = min(deck.zoom * 2, 128) } label: {
                        Text("+").frame(width: 14)
                    }
                    .chip()
                    .disabled(deck.zoom >= 128)
                }
                Spacer()
                Text(clock(to)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }

        private var waveform: some View {
            Group {
                if deck.player.playing {
                    TimelineView(.animation) { _ in
                        waveformView(progress: deck.player.time)
                    }
                } else {
                    waveformView(progress: deck.player.time)
                }
            }
            .frame(height: model.dualDeck ? 110 : 160)
        }

        private func waveformView(progress: Double) -> WaveformView {
            WaveformView(
                peaks: deck.peaks,
                bands: deck.bands,
                stemPeaks: deck.stemPeaks,
                stemBands: deck.stemBands,
                mix: deck.mix,
                progress: progress,
                beat: deck.beat,
                zoom: deck.zoom,
                duration: deck.player.duration,
                onSeek: { deck.seek($0) },
                onZoom: { deck.zoom = $0 },
                strip: deck.strip,
                onStripReady: { deck.objectWillChange.send() }
            )
        }

        private var tempoLabel: String {
            if let map = deck.beat?.map, map.count > 1 {
                let range = map.map(\.bpm)
                return "\(Int(range.min()!.rounded()))–\(Int(range.max()!.rounded())) BPM"
            }
            if let tempo = deck.beat?.bpm ?? deck.track?.bpm { return "\(Int(tempo.rounded())) BPM" }
            if deck.track != nil { return deck.analysing ? "detecting BPM…" : "no steady beat" }
            return "BPM —"
        }

        private var chipsRow: some View {
            HStack(spacing: 6) {
                Text(tempoLabel).chip()
                Button { Task { await deck.detectTempo() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .chip()
                .disabled(deck.track == nil || deck.analysing)
                .help(deck.separated ? "re-detect BPM from the drums stem" : "re-detect BPM from the full mix")
                Button("÷2") { deck.scaleTempo(0.5) }.chip().disabled((deck.beat?.bpm ?? deck.track?.bpm) == nil)
                Button("×2") { deck.scaleTempo(2) }.chip().disabled((deck.beat?.bpm ?? deck.track?.bpm) == nil)
            }
        }

        private var transportRow: some View {
            // transport on the left, shuffle/repeat/trim pinned right so the
            // row fills the card instead of leaving dead space at the edge
            HStack(spacing: 10) {
                Button { deck.step(-1) } label: {
                    Image(systemName: "backward.end.fill")
                }
                .disabled(deck.track == nil)
                playButton
                Button { deck.step(1) } label: {
                    Image(systemName: "forward.end.fill")
                }
                .disabled(deck.track == nil)
                Text(clock(deck.progress)).monospacedDigit()
                Slider(value: Binding(
                    get: { deck.progress },
                    set: { deck.seek($0) }
                ), in: 0 ... max(deck.player.duration, 0.01))
                .tint(.cyan)
                .disabled(deck.track == nil)
                .frame(minWidth: 60)
                Text(clock(deck.player.duration)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                extraControls
            }
            .buttonStyle(.plain)
        }

        /// Round filled transport button — the visual anchor of the deck.
        /// Space toggles the active deck only.
        private var playButton: some View {
            Group {
                if deck.id == model.activeDeckId {
                    playButtonBody.keyboardShortcut(.space, modifiers: [])
                } else {
                    playButtonBody
                }
            }
            .disabled(deck.track == nil)
        }

        private var playButtonBody: some View {
            Button { deck.track.map(deck.toggle) } label: {
                Image(systemName: deck.player.playing ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(
                        deck.player.playing
                            ? AnyShapeStyle(Color.blue.gradient)
                            : AnyShapeStyle(Color.white.opacity(0.12).gradient),
                        in: Circle()
                    )
                    .overlay(
                        Circle().strokeBorder(
                            deck.player.playing ? Color.cyan.opacity(0.9) : Color.white.opacity(0.25),
                            lineWidth: 1
                        )
                    )
                    .shadow(color: deck.player.playing ? .blue.opacity(0.5) : .clear, radius: 8)
            }
        }

        private var extraControls: some View {
            HStack(spacing: 10) {
                Button { model.shuffle.toggle() } label: {
                    Image(systemName: "shuffle")
                }
                .activePill(model.shuffle, .blue)
                Button {
                    model.repeatMode = model.repeatMode == "off" ? "all" : model.repeatMode == "all" ? "one" : "off"
                } label: {
                    Image(systemName: model.repeatMode == "one" ? "repeat.1" : "repeat")
                }
                .activePill(model.repeatMode != "off", .blue)
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.cyan)
                Slider(value: Binding(
                    get: { deck.trim },
                    set: { deck.trim = $0 }
                ), in: 0 ... 1).tint(.cyan).frame(width: 90)
            }
        }

        @ViewBuilder
        private var stemsRow: some View {
            let track = deck.track
            let state = track.map(model.stemState) ?? .idle
            HStack(spacing: 10) {
                if case .done(let stems) = state {
                    ForEach(stems, id: \.self) { stem in
                        stemControl(stem)
                    }
                    Spacer()
                    Button("re-analyze") { deck.analyse(force: true) }
                        .disabled(deck.analysing)
                        .help("separate again and re-detect the BPM from the drums")
                } else {
                    Text({
                        switch state {
                        case .running(let progress):
                            return "\(Int((progress * 100).rounded()))% — separating stems, then BPM from the drums"
                        case .failed(let error):
                            return "separation failed: \(error)"
                        case .idle:
                            return model.separator.available
                                ? "separate the stems, then detect the BPM on the drums"
                                : "no demucs helper — run scripts/setup-venv.sh"
                        case .done:
                            return ""
                        }
                    }())
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        deck.analyse()
                    } label: {
                        Text({
                            if case .running = state { return "analyzing…" }
                            return deck.analysing ? "detecting BPM…" : "Analyze"
                        }())
                    }
                    .chip()
                    .disabled(track == nil || deck.analysing || isRunning(state))
                }
            }
        }

        private func isRunning(_ state: StemState) -> Bool {
            if case .running = state { return true }
            return false
        }

        private func stemControl(_ stem: String) -> some View {
            let settings = deck.mix[stem] ?? StemMix()
            return VStack(spacing: 3) {
                StemKnob(
                    value: Binding(
                        get: { settings.knob },
                        set: { v in deck.setStem(stem) { $0.knob = v } }
                    ),
                    tint: stemColor(stem)
                )
                Text(stem)
                    .font(.system(size: 9, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .help("\(stem): drag up to isolate, down to cut — double-click to center")
        }
    }

    // MARK: - playlists

    private var playlistsBar: some View {
        HStack(spacing: 8) {
            Button("All tracks (\(store.tracks.count))") { model.playlistId = nil }
                .chip(active: model.playlistId == nil)
            ForEach(store.playlists) { playlist in
                HStack(spacing: 2) {
                    Button("\(playlist.name) (\(playlist.trackIds.count))") { model.playlistId = playlist.id }
                        .chip(active: model.playlistId == playlist.id)
                    Button("✕") { store.removePlaylist(playlist) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
                }
            }
            TextField("New playlist name", text: $model.playlistName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .onSubmit { createPlaylist() }
            Button("Create playlist") { createPlaylist() }
                .disabled(model.playlistName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func createPlaylist() {
        let playlist = store.createPlaylist(model.playlistName.trimmingCharacters(in: .whitespaces))
        model.playlistName = ""
        model.playlistId = playlist.id
    }

    // MARK: - library

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.playlist.map { "\($0.name) (\(model.visible.count))" } ?? "Library (\(store.tracks.count))")
                    .font(.headline)
                Spacer()
                TextField("Search title, artist or album", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                let pending = model.visible.filter {
                    if case .done = model.stemState($0) { return false }
                    if case .running = model.stemState($0) { return false }
                    return true
                }
                Button(model.queueing ? "queueing…" : "Analyze all (\(pending.count))") {
                    model.queueSeparation(all: false)
                }
                .disabled(model.queueing || pending.isEmpty)
                Button("Re-run all") { model.queueSeparation(all: true) }
                    .disabled(model.queueing || !model.separator.available || model.visible.isEmpty)
                    .help("re-run stem separation for every listed track, including ones already analyzed")
                Button("Metadata") { browsing = true }
                    .help("view every tag across the library and bulk-edit the selected rows")
                Button(model.dualDeck ? "A·B" : "2 decks") { model.dualDeck.toggle() }
                    .activePill(model.dualDeck, .blue)
                    .help("toggle a second deck with a crossfader — in dual mode a library click loads the highlighted deck")
                Button { openSettings() } label: {
                    Image(systemName: "gearshape")
                }
                .help("settings (⌘,)")
                if !selection.isEmpty {
                    Button("Remove \(selection.count) selected", role: .destructive) {
                        let targets = store.tracks.filter { selection.contains($0.id) }
                        for track in targets { store.delete(track) }
                        selection = []
                    }
                    .help("removes the tracks from the library — the files on disk stay untouched")
                }
            }

            if model.visible.isEmpty {
                ContentUnavailableView(
                    store.tracks.isEmpty ? "No tracks yet" : "Nothing matches",
                    systemImage: "music.note.list",
                    description: Text(store.tracks.isEmpty ? "Drop audio files or use Import." : "Try a different search.")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Table(model.visible, selection: $selection) {
                    TableColumn(" ") { track in
                        HStack(spacing: 6) {
                            Button { model.active.toggle(track) } label: {
                                let deck = model.decks.first { $0.trackId == track.id }
                                Text(deck?.player.playing == true ? "❚❚" : "▶")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(model.decks.contains { $0.trackId == track.id && $0.player.playing } ? Color.blue : .primary)
                            if let image = store.coverImage(track) {
                                Image(nsImage: image).resizable()
                                    .frame(width: 24, height: 24)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
                                Text("♫").frame(width: 24, height: 24)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        .onDrag { NSItemProvider(object: track.id as NSString) }
                    }
                    .width(60)
                    TableColumn("Title") { track in
                        TextField("", text: trackBinding(track, \.title)).textFieldStyle(.plain)
                            .onDrag { NSItemProvider(object: track.id as NSString) }
                    }
                    TableColumn("Artist") { track in
                        TextField("artist", text: trackBinding(track, \.artist))
                            .textFieldStyle(.plain).foregroundStyle(.secondary)
                            .onDrag { NSItemProvider(object: track.id as NSString) }
                    }
                    TableColumn("BPM") { track in
                        if let bpm = track.bpm {
                            Text("\(Int(bpm.rounded()))")
                                .monospacedDigit().foregroundStyle(.secondary)
                                .onDrag { NSItemProvider(object: track.id as NSString) }
                        }
                    }
                    .width(70)
                    TableColumn("Stems") { track in
                        switch model.stemState(track) {
                        case .done:
                            Text("stems").chip().onDrag { NSItemProvider(object: track.id as NSString) }
                        case .running(let progress):
                            Text("\(Int((progress * 100).rounded()))%").chip().onDrag { NSItemProvider(object: track.id as NSString) }
                        case .failed:
                            Text("failed").chip().onDrag { NSItemProvider(object: track.id as NSString) }
                        case .idle:
                            EmptyView()
                        }
                    }
                    .width(70)
                    TableColumn("Size") { track in
                        Text(String(format: "%.1f MB", Double(track.size) / 1024 / 1024))
                            .font(.caption).foregroundStyle(.secondary)
                            .onDrag { NSItemProvider(object: track.id as NSString) }
                    }
                    .width(70)
                    TableColumn(" ") { track in
                        HStack(spacing: 6) {
                            Button { editing = track } label: {
                                Image(systemName: "tag")
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("edit metadata")
                            if let playlist = model.playlist {
                                Button("remove") { store.removeFromPlaylist(playlist, trackId: track.id) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            } else if !store.playlists.isEmpty {
                                Menu("add to…") {
                                    ForEach(store.playlists) { playlist in
                                        Button(playlist.name) { store.addToPlaylist(playlist, trackId: track.id) }
                                    }
                                }
                                .menuStyle(.borderlessButton)
                                .frame(width: 70)
                            }
                            Button("delete", role: .destructive) { store.delete(track) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .onDrag { NSItemProvider(object: track.id as NSString) }
                    }
                    .width(150)
                }
                .scrollContentBackground(.hidden)
                .onDeleteCommand {
                    let targets = store.tracks.filter { selection.contains($0.id) }
                    for track in targets { store.delete(track) }
                    selection = []
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func trackBinding(_ track: Track, _ keyPath: WritableKeyPath<Track, String>) -> Binding<String> {
        Binding(
            get: { track[keyPath: keyPath] },
            set: { value in
                var updated = track
                updated[keyPath: keyPath] = String(value.prefix(200))
                store.update(updated)
            }
        )
    }
}

// MARK: - waveform

private struct WaveformView: View {
    let peaks: [Float]?
    let bands: BandEnvelope?
    let stemPeaks: [String: [Float]]?
    let stemBands: [String: BandEnvelope]?
    let mix: [String: StemMix]
    let progress: Double
    let beat: BeatAnalysis?
    let zoom: Double
    let duration: Double
    let onSeek: (Double) -> Void
    let onZoom: (Double) -> Void
    let strip: StripCache
    /// Called on the main actor when a background strip render lands — while
    /// paused nothing else repaints, so the new bitmap needs this nudge.
    let onStripReady: () -> Void
    @State private var pinchStart: Double = 1

    /// Window centered on the playhead but clamped to the track — at the
    /// start and end the playhead travels inside a still window instead of
    /// half the view showing dead space beyond the track.
    private var window: (from: Double, to: Double) {
        let span = duration / zoom
        var from = progress - span / 2
        if from < 0 { from = 0 }
        if from + span > duration { from = max(0, duration - span) }
        return (from, from + span)
    }

    /// Playhead position inside the window — 0.5 while scrolling, off-center
    /// inside the clamped regions at the track edges.
    private var playheadX: CGFloat {
        let (from, to) = window
        guard to > from else { return 0.5 }
        return CGFloat((progress - from) / (to - from))
    }

    var body: some View {
        GeometryReader { geometry in
            let _ = refreshStrip(size: geometry.size)
            ZStack(alignment: .topLeading) {
                if strip.image == nil {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: geometry.size.width, height: 0.5)
                        .offset(y: geometry.size.height / 2)
                }
                stripImage(in: geometry.size)
                PlayheadView(position: playheadX)
                    .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        if pinchStart == 1 { pinchStart = zoom }
                        let new = pinchStart * scale
                        onZoom(max(1, min(new, 128)))
                    }
                    .onEnded { _ in pinchStart = 1 }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let (from, to) = window
                        let span = to - from
                        guard span > 0 else { return }
                        let width = geometry.size.width
                        // scrub: the grabbed point follows the finger while the
                        // window stays centered on the playhead
                        let grabbed = from + value.startLocation.x / width * span
                        onSeek(grabbed + span * (0.5 - value.location.x / width))
                    }
            )
        }
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.cyan.opacity(0.12), lineWidth: 1)
        )
    }

    /// The strip bitmap laid out at its natural scale and moved by `offset` —
    /// once rasterized into a layer the compositor glides it on the GPU, so a
    /// frame is just a layer-position change with no draw work at all.
    @ViewBuilder
    private func stripImage(in size: CGSize) -> some View {
        if let image = strip.image {
            let span = window.to - window.from
            let w = strip.span / span * size.width
            Image(decorative: image, scale: strip.scale)
                .resizable()
                .frame(width: w, height: size.height)
                .offset(x: stripOffsetX(size: size))
        }
    }

    /// Offset of the strip's left edge: sub-pixel while the playhead moves so
    /// the layer glides, snapped to device pixels when still so a paused
    /// waveform stays pixel-crisp instead of resampling soft.
    private func stripOffsetX(size: CGSize) -> CGFloat {
        let (from, to) = window
        let exact = (strip.from - from) / (to - from) * size.width
        let moving = abs(progress - strip.lastProgress) > 0.0001
        strip.lastProgress = progress
        return moving ? exact : (exact * strip.scale).rounded() / strip.scale
    }

    /// Work out which stems are audible and kick off a background strip
    /// re-render when the visible window drifts near the strip's edge or
    /// anything in the render key changed. Mutating `strip` is safe — it is
    /// a reference-type cache, not view state.
    private func refreshStrip(size: CGSize) {
        let (from, to) = window
        let span = to - from
        guard span > 0, duration > 0 else {
            strip.image = nil
            strip.key = ""
            return
        }

        // same audible logic as the player: a soloed stem is the only one
        // heard, otherwise muted stems drop out and gains scale the rest
        var sources: [(peaks: [Float], bands: BandEnvelope?, gain: Float, color: SIMD3<Double>?)] = []
        if let stemPeaks, !stemPeaks.isEmpty {
            let stemNames = ["vocals", "drums", "bass", "other"]
            let soloed = stemNames.contains { stemPeaks[$0] != nil && mix[$0]?.solo == true }
            // same gain math as the player: knob left cuts the stem, knob
            // right ducks the others — the waveform tracks the audible mix
            func level(_ stem: String) -> Float {
                let settings = mix[stem] ?? StemMix()
                guard soloed ? settings.solo : !settings.muted else { return 0 }
                // isolate group: right-turned stems are never ducked
                if settings.knob > 0 { return Float(settings.gain) }
                let duck = stemNames
                    .map { max(0, mix[$0]?.knob ?? 0) }
                    .max() ?? 0
                return Float(1 + min(0, settings.knob)) * Float(settings.gain) * Float(1 - duck)
            }
            let audible = stemNames.filter {
                stemPeaks[$0]?.isEmpty == false && level($0) > 0.001
            }
            // solo mode (or a single audible stem) draws stem colors blended
            // per column by energy — a vocal-only section stays vocal-colored
            // even when a second stem is soloed but silent there; the full
            // mix keeps the frequency colors
            let tinted = soloed || audible.count == 1
            sources = audible.map {
                (stemPeaks[$0]!, stemBands?[$0], level($0),
                 tinted ? WavePrefs.stemRGB($0) : nil)
            }
        } else if let peaks {
            sources = [(peaks, bands, 1, nil)]
        }
        guard !sources.isEmpty else {
            strip.image = nil
            strip.key = ""
            return
        }

        // the waveform is rendered into an image strip five windows wide;
        // scrolling just repositions it, so every frame is a compositor move.
        // re-renders happen on a background queue — the old strip keeps
        // translating until the new one is ready
        let freq = WavePrefs.freq
        let stacked = AppPrefs.waveStyle == "stacked"
        let beat = AppPrefs.beatGrid ? beat : nil
        let key = stripKey(span: span, size: size, sources: sources,
                           freq: freq, stacked: stacked, gridOn: beat != nil)
        guard strip.key != key || from - strip.from < span * 0.5
                || strip.from + strip.span - to < span * 0.5,
              !strip.rendering else { return }
        strip.rendering = true
        // five windows wide centered on the visible window — enough margin
        // that scrolling only needs a re-render every few spans of travel
        let stripSpan = span * 5
        let widthPoints = size.width * 5
        // snap strip.from to the bitmap's pixel grid so column boundaries
        // land on the same absolute times for every strip — swaps are
        // pixel-identical, never a visible jump
        let pixelTime = stripSpan / Double(widthPoints * strip.scale)
        let mid = (from + to) / 2
        let stripFrom = ((mid - stripSpan / 2) / pixelTime).rounded(.down) * pixelTime
        let scale = strip.scale
        Task.detached { [strip, duration] in
            let image = Self.makeStripImage(
                widthPoints: widthPoints, heightPoints: size.height,
                scale: scale, from: stripFrom, span: stripSpan,
                duration: duration, sources: sources,
                freq: freq, stacked: stacked, beat: beat
            )
            await MainActor.run {
                strip.image = image
                strip.from = stripFrom
                strip.span = stripSpan
                strip.key = key
                strip.rendering = false
                onStripReady()
            }
        }
    }

    /// A signature of everything that changes how the strip is rendered —
    /// when it changes the strip is re-rendered instead of translated.
    private func stripKey(
        span: Double,
        size: CGSize,
        sources: [(peaks: [Float], bands: BandEnvelope?, gain: Float, color: SIMD3<Double>?)],
        freq: (low: SIMD3<Double>, midLow: SIMD3<Double>,
               midHigh: SIMD3<Double>, high: SIMD3<Double>),
        stacked: Bool,
        gridOn: Bool
    ) -> String {
        var key = "\(span)|\(size.width)x\(size.height)"
        key += "|\(freq.low)|\(freq.midLow)|\(freq.midHigh)|\(freq.high)|\(stacked)|\(gridOn)"
        key += "|beat:\(beat?.bpm ?? 0):\(beat?.map?.count ?? 0)"
        for source in sources {
            key += "|\(source.peaks.count):\(source.peaks.first ?? 0):\(source.gain):\(source.color?.description ?? "-")"
        }
        return key
    }

    /// Frequency-colored waveform like djay Pro: four bands blended per
    /// pixel column with the colors picked in Settings, so the color shifts
    /// continuously with the spectrum. The beat grid is baked in too — it is
    /// time-locked to the waveform so it scrolls with it.
    private nonisolated static func makeStripImage(
        widthPoints: CGFloat,
        heightPoints: CGFloat,
        scale: CGFloat,
        from: Double,
        span: Double,
        duration: Double,
        sources: [(peaks: [Float], bands: BandEnvelope?, gain: Float, color: SIMD3<Double>?)],
        freq: (low: SIMD3<Double>, midLow: SIMD3<Double>,
               midHigh: SIMD3<Double>, high: SIMD3<Double>),
        stacked: Bool,
        beat: BeatAnalysis?
    ) -> CGImage? {
        let width = Int(widthPoints * scale)
        let pixelHeight = Int(heightPoints * scale)
        guard width > 0, pixelHeight > 0, duration > 0, duration.isFinite,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let middle = CGFloat(pixelHeight) / 2
        for x in 0 ..< width {
            // each column covers a time range — take the loudest envelope
            // bucket inside it, so heights stay stable while scrolling
            let t0 = from + span * (Double(x) / Double(width))
            let t1 = from + span * (Double(x + 1) / Double(width))
            var total: Float = 0
            var lo: Float = 0, ml: Float = 0, mh: Float = 0, hi: Float = 0
            var stemR = 0.0, stemG = 0.0, stemB = 0.0, stemTotal: Float = 0
            for source in sources {
                let envelope = source.peaks
                guard !envelope.isEmpty else { continue }
                let perSecond = Double(envelope.count) / duration
                let energy = columnMax(envelope, t0, t1, perSecond) * source.gain
                total += energy
                if let c = source.color {
                    stemR += c.x * Double(energy)
                    stemG += c.y * Double(energy)
                    stemB += c.z * Double(energy)
                    stemTotal += energy
                }
                if let bands = source.bands {
                    // mean (not max) per band: the peaks could land on
                    // different instants inside the column and exaggerate
                    // mixing — color wants the column's true spectral balance
                    lo += columnMean(bands.low, t0, t1, perSecond) * source.gain
                    ml += columnMean(bands.midLow, t0, t1, perSecond) * source.gain
                    mh += columnMean(bands.midHigh, t0, t1, perSecond) * source.gain
                    hi += columnMean(bands.high, t0, t1, perSecond) * source.gain
                }
            }
            if lo + ml + mh + hi <= 0 {
                lo = total * 0.5
                ml = total * 0.25
                mh = total * 0.15
                hi = total * 0.1
            }
            let sum = lo + ml + mh + hi
            // loud columns bright, quiet ones dim — color reads off
            // loudness the way height does
            let brightness = 0.35 + 0.65 * min(1, Double(total))
            let columnHeight = max(CGFloat(total) * (middle - 3 * scale), scale)
            let rect = CGRect(
                x: CGFloat(x), y: middle - columnHeight,
                width: 1, height: columnHeight * 2
            )

            if stemTotal > 0 {
                // stem-colored: energy-weighted blend of stem identity colors
                context.setFillColor(CGColor(
                    red: stemR / Double(stemTotal) * brightness,
                    green: stemG / Double(stemTotal) * brightness,
                    blue: stemB / Double(stemTotal) * brightness,
                    alpha: 1
                ))
                context.fill(rect)
            } else if stacked {
                // stacked mode: the column is split vertically by band share
                // — low at the bottom, high at the top
                var y = rect.minY
                for (e, c) in [(lo, freq.low), (ml, freq.midLow),
                               (mh, freq.midHigh), (hi, freq.high)] {
                    let h = rect.height * CGFloat(e / sum)
                    context.setFillColor(CGColor(
                        red: c.x * brightness, green: c.y * brightness,
                        blue: c.z * brightness, alpha: 1
                    ))
                    context.fill(CGRect(x: rect.minX, y: y, width: 1, height: h))
                    y += h
                }
            } else {
                // gamma on the shares: the dominant band keeps more of its
                // hue instead of washing out into an even mix
                let wl = pow(Double(lo / sum), 1.6)
                let wml = pow(Double(ml / sum), 1.6)
                let wmh = pow(Double(mh / sum), 1.6)
                let whi = pow(Double(hi / sum), 1.6)
                let wsum = wl + wml + wmh + whi
                var r = (freq.low.x * wl + freq.midLow.x * wml + freq.midHigh.x * wmh + freq.high.x * whi) / wsum
                var g = (freq.low.y * wl + freq.midLow.y * wml + freq.midHigh.y * wmh + freq.high.y * whi) / wsum
                var b = (freq.low.z * wl + freq.midLow.z * wml + freq.midHigh.z * wmh + freq.high.z * whi) / wsum
                let strongest = max(r, g, b)
                if strongest > 0 {
                    r /= strongest
                    g /= strongest
                    b /= strongest
                }
                context.setFillColor(CGColor(
                    red: CGFloat(r * brightness), green: CGFloat(g * brightness),
                    blue: CGFloat(b * brightness), alpha: 1
                ))
                context.fill(rect)
            }
        }

        // beat grid baked into the strip — it is time-locked to the waveform
        if let beat {
            let pixelWidth = CGFloat(width)
            let barSpacing = ((60 / beat.bpm) * 4 / span) * pixelWidth
            for (time, index) in beat.beats(from: from, to: from + span) {
                let x = CGFloat((time - from) / span) * pixelWidth
                let downbeat = index % 4 == 0
                context.setStrokeColor(CGColor(
                    red: 1, green: 1, blue: 1,
                    alpha: downbeat ? 0.8 : 0.35
                ))
                context.setLineWidth(scale)
                context.move(to: CGPoint(
                    x: x,
                    y: downbeat ? 0 : CGFloat(pixelHeight) * 0.12
                ))
                context.addLine(to: CGPoint(
                    x: x,
                    y: downbeat ? CGFloat(pixelHeight) : CGFloat(pixelHeight) * 0.88
                ))
                context.strokePath()
                if downbeat, barSpacing >= 34 * scale {
                    let label = NSAttributedString(
                        string: "\(index / 4 + 1)",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 9 * scale),
                            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
                        ]
                    )
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(
                        cgContext: context, flipped: true
                    )
                    label.draw(at: NSPoint(x: x + 3 * scale, y: 6 * scale))
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        }
        return context.makeImage()
    }

}

// MARK: - tag editor

/// Modal metadata editor: reads the file's real tags via the mutagen helper
/// and writes them back on save, then mirrors the display fields onto the
/// library record.
private struct TagEditor: View {
    let track: Track
    @ObservedObject var model: MusicViewModel
    let store: Store
    /// Sets the edited track in the parent, which drives the sheet item.
    var onNavigate: (Track) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tags = TrackTags()
    @State private var loading = true
    @State private var saving = false
    @State private var artwork: URL?
    @State private var loaded = TrackTags()
    @State private var pickingArtwork = false
    @State private var embeddedArt: NSImage?
    @State private var whereFrom = ""
    @State private var loadedWhereFrom = ""
    @State private var navSearch = ""
    @State private var error: String?
    /// Which metadata field is being edited — restored on the next track so
    /// Next keeps you in the same section while retagging a whole list.
    @FocusState private var focus: String?
    @State private var resumeFocus: String?

    /// Tracks the nav buttons walk: the selected playlist's scope (or the
    /// whole library), filtered by the modal's own metadata search —
    /// independent of the library search field.
    private var navList: [Track] {
        let pool = model.playlist?.trackIds.compactMap { id in
            store.tracks.first { $0.id == id }
        } ?? store.tracks
        let needle = navSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return pool }
        return pool.filter {
            "\($0.title) \($0.artist) \($0.album)".lowercased().contains(needle)
        }
    }

    /// Index of the edited track in the nav list — prev/next walk it.
    private var listIndex: Int? {
        navList.firstIndex { $0.id == track.id }
    }

    /// Move to the adjacent track — saves pending edits first so nothing is
    /// lost when stepping through the library to retag.
    private func navigate(_ offset: Int) {
        guard !saving, !navList.isEmpty else { return }
        // current track filtered out? start from the nearest end; wrap around
        // the list edges so stepping through search results never dead-ends
        let index = listIndex ?? (offset > 0 ? -1 : 0)
        let next = (index + offset + navList.count) % navList.count
        let destination = navList[next]
        resumeFocus = focus
        guard tags != loaded || artwork != nil || whereFrom != loadedWhereFrom else {
            onNavigate(destination)
            return
        }
        saving = true
        Task {
            let ok = await persist()
            saving = false
            if ok { onNavigate(destination) }
            else { error = "could not write tags — edits kept" }
        }
    }

    /// Write tags, artwork and the where-from xattr in one save.
    private func persist() async -> Bool {
        let ok = await model.saveTags(track, tags, artwork: artwork)
        if ok {
            Tagger.setWhereFrom(store.trackURL(track), whereFrom)
            if let source = track.source,
               FileManager.default.fileExists(atPath: source),
               !Tagger.setWhereFrom(URL(fileURLWithPath: source), whereFrom) {
                error = "where-from saved to library only — macOS blocked the original file"
            }
            loadedWhereFrom = whereFrom
        }
        return ok
    }

    private var coverPreview: some View {
        Group {
            if let artwork, let image = NSImage(contentsOf: artwork) {
                Image(nsImage: image)
            } else if let image = store.coverImage(track) ?? embeddedArt {
                Image(nsImage: image)
            } else {
                Text("♫").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .frame(width: 72, height: 72)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Whether the modal's search needle appears in a metadata value —
    /// matching fields get a colored outline + label.
    private func matches(_ value: String) -> Bool {
        let needle = navSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return !needle.isEmpty && value.lowercased().contains(needle)
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        let hit = matches(text.wrappedValue)
        return VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption)
                .foregroundStyle(hit ? Color.accentColor : .secondary)
            TextField("", text: text).textFieldStyle(.roundedBorder)
                .focused($focus, equals: label)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(hit ? Color.accentColor : .clear, lineWidth: 1))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                coverPreview
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.headline)
                    Text(track.file)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if let source = track.source {
                        Text(source)
                            .font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Text("\(clock(track.duration)) · \(String(format: "%.1f", Double(track.size) / 1024 / 1024)) MB")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("from:")
                            .font(.caption2).foregroundStyle(.tertiary)
                        TextField("where-from URL", text: $whereFrom)
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: "from")
                            .font(.caption2)
                    }
                }
                Spacer()
                TextField("Filter list", text: $navSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                Button("Artwork…") { pickingArtwork = true }
            }

            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .frame(height: 380)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 8) {
                        field("Title", $tags.title)
                        field("Artist", $tags.artist)
                        field("Album artist", $tags.albumArtist)
                        field("Album", $tags.album)
                        field("Genre", $tags.genre)
                        HStack(spacing: 8) {
                            field("Year", $tags.year)
                            field("Orig. year", $tags.originalYear)
                        }
                        HStack(spacing: 8) {
                            field("Track #", $tags.trackNumber)
                            field("Disc #", $tags.discNumber)
                        }
                        field("Composer", $tags.composer)
                        field("Lyricist", $tags.lyricist)
                        field("Copyright", $tags.copyright)
                    }
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            field("BPM", $tags.bpm)
                            field("Key", $tags.key)
                        }
                        HStack(spacing: 8) {
                            field("ReplayGain", $tags.replayGain)
                            field("Language", $tags.language)
                        }
                        field("Remixer", $tags.remixer)
                        field("Version / mix", $tags.version)
                        field("Label", $tags.label)
                        HStack(spacing: 8) {
                            field("Catalog #", $tags.catalogNumber)
                            field("Barcode", $tags.barcode)
                        }
                        field("ISRC", $tags.isrc)
                        HStack(spacing: 8) {
                            field("Mood", $tags.mood)
                            field("Grouping", $tags.grouping)
                        }
                        HStack(spacing: 12) {
                            Toggle("Compilation", isOn: $tags.compilation)
                                .font(.caption)
                            Spacer()
                            Text("Rating").font(.caption).foregroundStyle(.secondary)
                            ForEach(1 ... 5, id: \.self) { star in
                                Button {
                                    tags.rating = tags.rating == star ? 0 : star
                                } label: {
                                    Image(systemName: star <= tags.rating ? "star.fill" : "star")
                                        .foregroundStyle(star <= tags.rating ? Color.yellow : .secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Comment").font(.caption)
                        .foregroundStyle(matches(tags.comment) ? Color.accentColor : .secondary)
                    TextEditor(text: $tags.comment)
                        .font(.caption)
                        .focused($focus, equals: "Comment")
                        .frame(height: 56)
                        .scrollContentBackground(.hidden)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(matches(tags.comment) ? Color.accentColor : .clear, lineWidth: 1))
                }
            }

            HStack {
                Button { navigate(-1) } label: {
                    Label("Prev", systemImage: "chevron.up")
                }
                .help("Previous track in list")
                .disabled(navList.isEmpty)
                Button { navigate(1) } label: {
                    Label("Next", systemImage: "chevron.down")
                }
                .help("Next track in list")
                .disabled(navList.isEmpty)
                Spacer()
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        let ok = await persist()
                        saving = false
                        if ok { dismiss() }
                        else { error = "could not write tags — is the helper set up?" }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(loading || saving)
            }
        }
        .padding(16)
        .frame(width: 640)
        .fileImporter(isPresented: $pickingArtwork, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { artwork = url }
        }
        .task(id: track.id) {
            loading = true
            artwork = nil
            embeddedArt = nil
            whereFrom = ""
            error = nil
            tags = await model.readTags(track)
            loaded = tags
            whereFrom = Tagger.whereFrom(store.trackURL(track)) ?? ""
            loadedWhereFrom = whereFrom
            if store.coverImage(track) == nil {
                if let url = await model.extractArtwork(track) {
                    embeddedArt = NSImage(contentsOf: url)
                }
            }
            loading = false
            if let resumeFocus {
                let target = resumeFocus
                self.resumeFocus = nil
                // fields re-render with the loading branch — focus after that,
                // then select the content so typing replaces it outright
                DispatchQueue.main.async {
                    focus = target
                    DispatchQueue.main.async {
                        (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                    }
                }
            }
        }
    }
}

/// Spreadsheet of every tag across the visible library. Selecting rows and
/// committing a bulk-bar field writes that value into all selected files —
/// the library copy and the recorded source — and each apply can be undone.
private struct MetadataBrowser: View {
    @ObservedObject var model: MusicViewModel
    let store: Store
    /// Owns its selection locally — a @Binding to the library selection would
    /// re-render the whole main window (player, table) on every row click.
    @State private var selection: Set<Track.ID>
    @Environment(\.dismiss) private var dismiss

    init(model: MusicViewModel, store: Store, selection: Set<Track.ID>) {
        self.model = model
        self.store = store
        _selection = State(initialValue: selection)
    }

    /// One bulk-apply snapshot — tags plus the where-from xattr, which lives
    /// outside TrackTags.
    private struct UndoEntry { var id: String; var tags: TrackTags; var whereFrom: String }

    @State private var rows: [MetaRow] = []
    /// The column the table is sorted by — the matching bulk field gets a
    /// blue ring. Reported up from the NSTableView on header clicks.
    @State private var sortedField: String?
    @State private var bulk = TrackTags()
    @State private var bulkWhereFrom = ""
    @State private var undoStack: [[UndoEntry]] = []
    @State private var busy = false
    @State private var status: String?

    /// An inline cell edit committed — writes just that row, or the whole
    /// selection when the edited row sits inside a multi-selection.
    private func commitCell(_ rowId: String, _ field: String, _ value: String) {
        guard let row = rows.first(where: { $0.id == rowId }),
              let spec = MetaCol.all.first(where: { $0.id == field }),
              spec.get(row) != value   // aborted edit — nothing to write
        else { return }
        let targets = selection.count > 1 && selection.contains(rowId)
            ? rows.filter { selection.contains($0.id) }
            : [row]
        if field == "Where from" {
            applyWhereFrom(value, to: targets)
        } else if let kp = MetaCol.all.first(where: { $0.id == field })?.kp {
            apply(kp, value, to: targets)
        }
    }

    /// Fields written wholesale to every selected track. Per-song values
    /// (title, track/disc #, ISRC) are excluded — identical across songs is
    /// wrong by definition.
    private let bulkFields: [(String, WritableKeyPath<TrackTags, String>)] = [
        ("Artist", \.artist), ("Album artist", \.albumArtist), ("Album", \.album),
        ("Genre", \.genre), ("Year", \.year), ("Orig. year", \.originalYear),
        ("BPM", \.bpm), ("Key", \.key), ("Composer", \.composer),
        ("Lyricist", \.lyricist), ("Remixer", \.remixer), ("Version", \.version),
        ("Label", \.label), ("Catalog #", \.catalogNumber), ("Barcode", \.barcode),
        ("Mood", \.mood), ("Grouping", \.grouping), ("Language", \.language),
        ("Copyright", \.copyright), ("ReplayGain", \.replayGain),
        ("Comment", \.comment),
    ]

    /// Fingerprint each selected track and fetch proper tags from
    /// MusicBrainz — undoable like a bulk apply. MusicBrainz allows
    /// 1 request/sec, so the loop is deliberately paced.
    private func identifySelected() {
        let targets = rows.filter { selection.contains($0.id) }
        guard !targets.isEmpty, !busy else { return }
        undoStack.append(targets.map { UndoEntry(id: $0.id, tags: $0.tags, whereFrom: $0.whereFrom) })
        busy = true
        status = nil
        Task {
            var done = 0, missed = 0
            for (i, row) in targets.enumerated() {
                status = "identifying \(i + 1)/\(targets.count)…"
                do {
                    let res = try await Identifier.identify(
                        store.trackURL(row.track), key: IdentifyPrefs.acoustIdKey,
                        title: row.tags.title.isEmpty ? row.track.title : row.tags.title,
                        artist: row.tags.artist.isEmpty ? row.track.artist : row.tags.artist,
                        provider: IdentifyPrefs.provider,
                        wantArtwork: IdentifyPrefs.wantArtwork)
                    // only the fields enabled in Settings get overwritten
                    var merged = row.tags
                    for (key, _, kp) in IdentifyPrefs.fields where IdentifyPrefs.isOn(key) {
                        if !res.tags[keyPath: kp].isEmpty { merged[keyPath: kp] = res.tags[keyPath: kp] }
                    }
                    if res.hasRelease && IdentifyPrefs.wantCompilation {
                        merged.compilation = res.tags.compilation
                    }
                    // saveTags embeds an image file, not raw bytes
                    var artURL: URL?
                    if let data = res.artwork {
                        let tmp = FileManager.default.temporaryDirectory
                            .appendingPathComponent("musiclab-art-\(UUID().uuidString).jpg")
                        try? data.write(to: tmp)
                        artURL = tmp
                    }
                    if await model.saveTags(row.track, merged, artwork: artURL) {
                        if let j = rows.firstIndex(where: { $0.id == row.id }) {
                            rows[j].tags = merged
                        }
                        done += 1
                    } else { missed += 1 }
                } catch { missed += 1 }
                try? await Task.sleep(for: .seconds(1.1))
            }
            busy = false
            status = "identified \(done)/\(targets.count)"
                + (missed > 0 ? " — \(missed) unmatched" : "")
        }
    }

    /// Write one field into every selected track, snapshotting first for undo.
    private func apply(_ kp: WritableKeyPath<TrackTags, String>, _ value: String,
                       to targets: [MetaRow]) {
        guard !targets.isEmpty, !busy else {
            status = targets.isEmpty ? "select rows first" : nil
            return
        }
        undoStack.append(targets.map { UndoEntry(id: $0.id, tags: $0.tags, whereFrom: $0.whereFrom) })
        busy = true
        status = nil
        Task {
            for row in targets {
                var t = row.tags
                t[keyPath: kp] = value
                if await model.saveTags(row.track, t, artwork: nil),
                   let i = rows.firstIndex(where: { $0.id == row.id }) {
                    rows[i].tags = t
                }
            }
            busy = false
            status = "applied to \(targets.count) tracks"
        }
    }

    /// Same as `apply` but for the where-from extended attribute, which sits
    /// outside the tag payload and writes via setxattr on both files.
    private func applyWhereFrom(_ value: String, to targets: [MetaRow]) {
        guard !targets.isEmpty, !busy else {
            status = targets.isEmpty ? "select rows first" : nil
            return
        }
        undoStack.append(targets.map { UndoEntry(id: $0.id, tags: $0.tags, whereFrom: $0.whereFrom) })
        busy = true
        status = nil
        Task {
            for row in targets {
                Tagger.setWhereFrom(store.trackURL(row.track), value)
                if let source = row.track.source,
                   FileManager.default.fileExists(atPath: source) {
                    Tagger.setWhereFrom(URL(fileURLWithPath: source), value)
                }
                if let i = rows.firstIndex(where: { $0.id == row.id }) {
                    rows[i].whereFrom = value
                }
            }
            busy = false
            status = "applied to \(targets.count) tracks"
        }
    }

    private func revert() {
        guard let snapshot = undoStack.popLast(), !busy else { return }
        busy = true
        status = nil
        Task {
            for entry in snapshot {
                guard let i = rows.firstIndex(where: { $0.id == entry.id }) else { continue }
                if await model.saveTags(rows[i].track, entry.tags, artwork: nil) {
                    rows[i].tags = entry.tags
                }
                Tagger.setWhereFrom(store.trackURL(rows[i].track), entry.whereFrom)
                if let source = rows[i].track.source,
                   FileManager.default.fileExists(atPath: source) {
                    Tagger.setWhereFrom(URL(fileURLWithPath: source), entry.whereFrom)
                }
                rows[i].whereFrom = entry.whereFrom
            }
            busy = false
            status = "undone"
        }
    }

    private func bulkField(_ label: String, _ kp: WritableKeyPath<TrackTags, String>) -> some View {
        let sorted = sortedField == label
        return VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2)
                .foregroundStyle(sorted ? Color.accentColor : .secondary)
            TextField("", text: Binding(
                get: { bulk[keyPath: kp] },
                set: { bulk[keyPath: kp] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 96)
            .disabled(selection.isEmpty || busy)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(sorted ? Color.accentColor : .clear, lineWidth: 1))
            .onSubmit {
                apply(kp, bulk[keyPath: kp],
                      to: rows.filter { selection.contains($0.id) })
                bulk[keyPath: kp] = ""
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Library metadata").font(.headline)
                Text("\(model.visible.count) tracks · \(selection.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Identify") { identifySelected() }
                    .disabled(selection.isEmpty || busy)
                    .help(IdentifyPrefs.acoustIdKey.isEmpty
                          ? "match on existing title/artist via MusicBrainz — set an AcoustID key in Settings (⌘,) for audio fingerprinting"
                          : "fingerprint the selected tracks and fetch proper tags from MusicBrainz")
                if busy { ProgressView().controlSize(.small) }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            MetadataTable(rows: rows, selection: $selection,
                          sortedField: $sortedField, onCommit: commitCell)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Bulk edit — type a value, Return writes it to all \(selection.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") { revert() }
                        .disabled(undoStack.isEmpty || busy)
                        .help("restore the previous values from the last bulk apply")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(bulkFields, id: \.0) { label, kp in
                            bulkField(label, kp)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Where from").font(.caption2)
                                .foregroundStyle(sortedField == "Where from" ? Color.accentColor : .secondary)
                            TextField("", text: $bulkWhereFrom)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 96)
                                .disabled(selection.isEmpty || busy)
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .stroke(sortedField == "Where from" ? Color.accentColor : .clear, lineWidth: 1))
                                .onSubmit {
                                    applyWhereFrom(bulkWhereFrom,
                                        to: rows.filter { selection.contains($0.id) })
                                    bulkWhereFrom = ""
                                }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 920, minHeight: 500)
        .task {
            let tracks = model.visible
            rows = tracks.map { track in
                var row = MetaRow(track: track,
                                  whereFrom: Tagger.whereFrom(store.trackURL(track)) ?? "")
                // seed with the library record so cells aren't empty while
                // the real file tags stream in
                row.tags.title = track.title
                row.tags.artist = track.artist
                row.tags.album = track.album
                row.tags.genre = track.genre ?? ""
                row.tags.year = track.year ?? ""
                row.tags.trackNumber = track.trackNumber ?? ""
                row.tags.comment = track.comment ?? ""
                row.tags.bpm = track.bpm.map { String(Int($0.rounded())) } ?? ""
                row.tags.rating = track.rating ?? 0
                return row
            }
            let indexOf = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
            let pairs = tracks.map { ($0, store.trackURL($0)) }
            // one helper process per chunk — a batch read is far cheaper than
            // a python startup per file, and chunks still run in parallel
            let chunkSize = max(1, (pairs.count + 5) / 6)
            await withTaskGroup(of: [(String, TrackTags)].self) { group in
                for start in stride(from: 0, to: pairs.count, by: chunkSize) {
                    let chunk = pairs[start ..< min(start + chunkSize, pairs.count)]
                    group.addTask {
                        let byPath = await Tagger.readMany(chunk.map(\.1))
                        return chunk.map { ($0.id, byPath[$1.path] ?? TrackTags()) }
                    }
                }
                for await pairs in group {
                    for (id, t) in pairs {
                        if let i = indexOf[id] { rows[i].tags = t }
                    }
                }
            }
        }
    }
}

/// A metadata-grid row: the track record plus its on-disk tags.
private struct MetaRow: Identifiable {
    var track: Track
    var tags = TrackTags()
    var whereFrom = ""
    var id: String { track.id }
}

/// One metadata column: display value, optional editable tag field, and how
/// to sort (localized text, or numeric when `numeric` is set).
private struct MetaCol {
    var id: String
    var kp: WritableKeyPath<TrackTags, String>?
    var numeric = false
    var get: (MetaRow) -> String

    init(_ id: String, _ kp: WritableKeyPath<TrackTags, String>? = nil,
         numeric: Bool = false, get: @escaping (MetaRow) -> String) {
        self.id = id
        self.kp = kp
        self.numeric = numeric
        self.get = get
    }

    var editable: Bool { kp != nil || id == "Where from" }

    func compare(_ a: MetaRow, _ b: MetaRow) -> ComparisonResult {
        if numeric {
            let x = Double(get(a)) ?? 0, y = Double(get(b)) ?? 0
            return x == y ? .orderedSame : x < y ? .orderedAscending : .orderedDescending
        }
        return get(a).localizedStandardCompare(get(b))
    }

    static let all: [MetaCol] = [
        .init("Title", \.title) { $0.tags.title },
        .init("Artist", \.artist) { $0.tags.artist },
        .init("Album artist", \.albumArtist) { $0.tags.albumArtist },
        .init("Album", \.album) { $0.tags.album },
        .init("Genre", \.genre) { $0.tags.genre },
        .init("Year", \.year) { $0.tags.year },
        .init("Orig. year", \.originalYear) { $0.tags.originalYear },
        .init("Track #", \.trackNumber, numeric: true) { $0.tags.trackNumber },
        .init("Disc #", \.discNumber, numeric: true) { $0.tags.discNumber },
        .init("BPM", \.bpm, numeric: true) { $0.tags.bpm },
        .init("Key", \.key) { $0.tags.key },
        .init("Composer", \.composer) { $0.tags.composer },
        .init("Lyricist", \.lyricist) { $0.tags.lyricist },
        .init("Remixer", \.remixer) { $0.tags.remixer },
        .init("Version", \.version) { $0.tags.version },
        .init("Label", \.label) { $0.tags.label },
        .init("Catalog #", \.catalogNumber) { $0.tags.catalogNumber },
        .init("Barcode", \.barcode) { $0.tags.barcode },
        .init("ISRC", \.isrc) { $0.tags.isrc },
        .init("Mood", \.mood) { $0.tags.mood },
        .init("Grouping", \.grouping) { $0.tags.grouping },
        .init("Language", \.language) { $0.tags.language },
        .init("Copyright", \.copyright) { $0.tags.copyright },
        .init("ReplayGain", \.replayGain) { $0.tags.replayGain },
        .init("Comment", \.comment) { $0.tags.comment },
        .init("Compil.") { $0.tags.compilation ? "✓" : "" },
        .init("Rating", numeric: true) { $0.tags.rating > 0 ? "\($0.tags.rating)" : "" },
        .init("Where from") { $0.whereFrom },
    ]
}

/// NSTableView-backed metadata grid — SwiftUI's Table was too slow at ~700×28
/// cells and per-cell gestures fought row selection. This is virtualized with
/// native multi-selection, header-click sorting and double-click editing.
private struct MetadataTable: NSViewRepresentable {
    var rows: [MetaRow]
    @Binding var selection: Set<String>
    @Binding var sortedField: String?
    /// (rowId, columnId, newValue)
    var onCommit: (String, String, String) -> Void

    func makeCoordinator() -> Coord { Coord(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let tv = NSTableView()
        tv.headerView = NSTableHeaderView()
        tv.allowsMultipleSelection = true
        tv.allowsEmptySelection = true
        tv.allowsColumnReordering = false
        tv.usesAlternatingRowBackgroundColors = true
        tv.dataSource = context.coordinator
        tv.delegate = context.coordinator
        tv.doubleAction = #selector(Coord.doubleClicked(_:))
        for spec in MetaCol.all {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            col.title = spec.id
            col.width = 110
            col.minWidth = 50
            tv.addTableColumn(col)
        }
        scroll.documentView = tv
        context.coordinator.tv = tv
        context.coordinator.rows = rows
        context.coordinator.applySort()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        coord.rows = rows
        coord.applySort()
        // a live field editor must not be reloaded out from under the user
        if !coord.isEditing {
            coord.tv?.reloadData()
            coord.syncSelection()
        }
    }

    final class Coord: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: MetadataTable
        weak var tv: NSTableView?
        var rows: [MetaRow] = []
        var sorted: [MetaRow] = []
        var sortId: String?
        var ascending = true
        var editing: (rowId: String, colId: String)?
        var isEditing: Bool { editing != nil }

        init(_ parent: MetadataTable) { self.parent = parent }

        func applySort() {
            guard let spec = MetaCol.all.first(where: { $0.id == sortId }) else {
                sorted = rows
                return
            }
            sorted = rows.sorted {
                ascending ? spec.compare($0, $1) == .orderedAscending
                          : spec.compare($0, $1) == .orderedDescending
            }
        }

        func syncSelection() {
            guard let tv else { return }
            let current = Set(tv.selectedRowIndexes.map { sorted[$0].id })
            guard current != parent.selection else { return }
            var indexes = IndexSet()
            for (i, row) in sorted.enumerated() where parent.selection.contains(row.id) {
                indexes.insert(i)
            }
            tv.selectRowIndexes(indexes, byExtendingSelection: false)
        }

        // MARK: NSTableViewDataSource / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { sorted.count }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn,
                  let spec = MetaCol.all.first(where: { $0.id == tableColumn.identifier.rawValue })
            else { return nil }
            let cellID = NSUserInterfaceItemIdentifier("metaCell")
            let field = (tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTextField) ?? {
                let f = NSTextField()
                f.identifier = cellID
                f.isBordered = false
                f.isBezeled = false
                f.drawsBackground = false
                f.lineBreakMode = .byTruncatingTail
                f.font = .systemFont(ofSize: 12)
                f.delegate = self
                return f
            }()
            let meta = sorted[row]
            field.stringValue = spec.get(meta)
            field.isEditable = editing?.rowId == meta.id && editing?.colId == spec.id
            field.isSelectable = field.isEditable
            field.textColor = .labelColor
            return field
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tv else { return }
            let ids = Set(tv.selectedRowIndexes.map { sorted[$0].id })
            if ids != parent.selection { parent.selection = ids }
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            let id = tableColumn.identifier.rawValue
            if sortId == id { ascending.toggle() } else { sortId = id; ascending = true }
            applySort()
            tableView.reloadData()
            syncSelection()
            parent.sortedField = id
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow, col = sender.clickedColumn
            guard row >= 0, col >= 0,
                  let spec = MetaCol.all.first(where: {
                      $0.id == sender.tableColumns[col].identifier.rawValue
                  }), spec.editable
            else { return }
            editing = (sorted[row].id, spec.id)
            sender.reloadData(forRowIndexes: IndexSet(integer: row),
                              columnIndexes: IndexSet(integer: col))
            sender.editColumn(col, row: row, with: nil, select: true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let editing,
                  let field = notification.object as? NSTextField
            else { return }
            parent.onCommit(editing.rowId, editing.colId, field.stringValue)
            self.editing = nil
            field.isEditable = false
            field.isSelectable = false
            tv?.reloadData()
        }
    }
}

/// The loudest envelope bucket within a column's time range, so heights
/// stay stable while scrolling.
private func columnMax(_ envelope: [Float], _ t0: Double, _ t1: Double, _ perSecond: Double) -> Float {
    // the strip runs three windows wide, so columns can land fully past the
    // end of the track — clamp i0 or i0..<i1 traps
    let i0 = min(envelope.count, max(0, Int(t0 * perSecond)))
    let i1 = min(envelope.count, max(i0 + 1, Int((t1 * perSecond).rounded(.up))))
    var peak: Float = 0
    for i in i0 ..< i1 {
        if envelope[i] > peak { peak = envelope[i] }
    }
    return peak
}

/// Average envelope level within a column's time range — used for color so
/// the mix reflects the column's actual spectral balance, not coincidental
/// per-band peaks.
private func columnMean(_ envelope: [Float], _ t0: Double, _ t1: Double, _ perSecond: Double) -> Float {
    let i0 = max(0, Int(t0 * perSecond))
    let i1 = min(envelope.count, max(i0 + 1, Int((t1 * perSecond).rounded(.up))))
    guard i1 > i0 else { return 0 }
    var sum: Float = 0
    for i in i0 ..< i1 where i < envelope.count { sum += envelope[i] }
    return sum / Float(i1 - i0)
}

/// The rendered waveform bitmap plus the time range it covers. A plain
/// reference type — mutating it must not trigger view updates, it is a cache.
/// It lives on the Deck rather than in view @State: the playing/paused
/// branches build different subtrees, and state-owned strips were thrown
/// away on every play/pause switch — the blank-waveform flash.
final class StripCache {
    var image: CGImage?
    var from: Double = 0
    var span: Double = 0
    var scale: CGFloat = 2
    var key = ""
    var rendering = false
    var lastProgress = -1.0
}

private struct PlayheadView: View {
    /// Horizontal position as a fraction of the width — 0.5 while the
    /// waveform scrolls, off-center inside the clamped end regions.
    var position: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.red)
                .frame(width: 1.5, height: geometry.size.height)
                .shadow(color: .red, radius: 4)
                .offset(x: (geometry.size.width - 1.5) * position)
        }
    }
}

// MARK: - stem knob

/// Rotary mixer knob: drag up turns clockwise (isolate), drag down cuts.
/// -1 = stem silenced, 0 = unity, +1 = every other stem ducked to silence.
/// Double-click snaps back to center.
private struct StemKnob: View {
    @Binding var value: Double
    var tint: Color
    @State private var dragStart: Double?

    /// Needle angle on the CG clock: 0° points right, y grows downward —
    /// so 270° is top (center), 135° bottom-left (cut), 405° bottom-right.
    private var degrees: Double { 270 + value * 135 }

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2 - 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var track = Path()
            track.addArc(center: center, radius: radius,
                         startAngle: .degrees(135), endAngle: .degrees(405),
                         clockwise: false)
            context.stroke(track, with: .color(.white.opacity(0.15)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            if value != 0 {
                var active = Path()
                active.addArc(center: center, radius: radius,
                              startAngle: .degrees(270), endAngle: .degrees(degrees),
                              clockwise: value > 0)
                context.stroke(active, with: .color(tint),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            let rad = degrees * .pi / 180
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: CGPoint(
                x: center.x + cos(rad) * radius * 0.62,
                y: center.y + sin(rad) * radius * 0.62
            ))
            context.stroke(needle, with: .color(.white.opacity(0.9)), lineWidth: 2)
        }
        .frame(width: 34, height: 34)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if dragStart == nil { dragStart = value }
                    value = min(1, max(-1, (dragStart ?? 0) - drag.translation.height / 80))
                }
                .onEnded { _ in dragStart = nil }
        )
        // simultaneous so the drag is not held back waiting for a second tap
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
    }
}

// MARK: - chip style

private struct Chip: ViewModifier {
    var active = false
    func body(content: Content) -> some View {
        content
            .font(.caption)
            .foregroundStyle(active ? .white : .primary.opacity(0.85))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(active ? Color.blue : Color.white.opacity(0.07), in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    active ? Color.cyan.opacity(0.9) : Color.white.opacity(0.15),
                    lineWidth: 1
                )
            )
            .shadow(color: active ? Color.blue.opacity(0.6) : .clear, radius: 6)
    }
}

private struct ActivePill: ViewModifier {
    var active: Bool
    var color: Color
    var inactive: Color = .primary
    func body(content: Content) -> some View {
        content
            .foregroundStyle(active ? .white : inactive)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(active ? color : .clear, in: Capsule())
            .shadow(color: active ? color.opacity(0.7) : .clear, radius: 8)
    }
}

private extension View {
    func chip(active: Bool = false) -> some View {
        modifier(Chip(active: active))
    }

    /// White text on a colored pill while the control is on.
    func activePill(_ active: Bool, _ color: Color, inactive: Color = .primary) -> some View {
        modifier(ActivePill(active: active, color: color, inactive: inactive))
    }
}
