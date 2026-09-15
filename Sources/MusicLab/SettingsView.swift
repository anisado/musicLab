import SwiftUI

/// Identify preferences persisted in UserDefaults — provider, API key and
/// which fields a lookup is allowed to write.
enum IdentifyPrefs {
    /// (defaults key, label, tag field) — the fields an Identify pass can fill.
    static let fields: [(String, String, WritableKeyPath<TrackTags, String>)] = [
        ("idf.title", "Title", \.title),
        ("idf.artist", "Artist", \.artist),
        ("idf.albumArtist", "Album artist", \.albumArtist),
        ("idf.album", "Album", \.album),
        ("idf.genre", "Genre", \.genre),
        ("idf.year", "Year", \.year),
        ("idf.originalYear", "Original year", \.originalYear),
        ("idf.trackNumber", "Track #", \.trackNumber),
        ("idf.discNumber", "Disc #", \.discNumber),
        ("idf.isrc", "ISRC", \.isrc),
        ("idf.label", "Label", \.label),
        ("idf.catalogNumber", "Catalog #", \.catalogNumber),
        ("idf.barcode", "Barcode", \.barcode),
        ("idf.version", "Version / mix", \.version),
    ]

    /// Field toggles default to on when never written.
    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func set(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static var provider: String {
        UserDefaults.standard.string(forKey: "identifyProvider") ?? "auto"
    }

    static var wantArtwork: Bool {
        UserDefaults.standard.object(forKey: "identifyArtwork") as? Bool ?? true
    }

    static var wantCompilation: Bool { isOn("idf.compilation") }

    static var acoustIdKey: String {
        UserDefaults.standard.string(forKey: "acoustIdKey") ?? ""
    }
}

/// Waveform colors persisted as #RRGGBB in UserDefaults.
enum WavePrefs {
    static let stems = ["vocals", "drums", "bass", "other"]
    /// Defaults match the dark-mode system colors used before theming.
    private static let stemDefaults: [String: String] = [
        "vocals": "#30D158", "drums": "#FF453A",
        "bass": "#0A84FF", "other": "#FF9F0A",
    ]
    private static let freqDefaults: [String: String] = [
        "low": "#FF0000", "midLow": "#FF8C00",
        "midHigh": "#00C800", "high": "#0064FF",
    ]

    static func hex(_ key: String, _ def: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? def
    }

    static func stemColor(_ stem: String) -> Color {
        Color(hex: hex("col.stem.\(stem)", stemDefaults[stem] ?? "#FF9F0A")) ?? .orange
    }

    /// Band → RGB triple used to mix the frequency-colored waveform.
    static func bandRGB(_ band: String) -> SIMD3<Double> {
        rgb(hex("col.freq.\(band)", freqDefaults[band] ?? "#FFFFFF"))
    }

    /// Stem → RGB triple used to color solo/muted stem waveforms.
    static func stemRGB(_ stem: String) -> SIMD3<Double> {
        rgb(hex("col.stem.\(stem)", stemDefaults[stem] ?? "#FF9F0A"))
    }

    private static func rgb(_ hexString: String) -> SIMD3<Double> {
        var s = hexString
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else {
            return SIMD3(1, 1, 1)
        }
        return SIMD3(Double((v >> 16) & 0xFF) / 255,
                     Double((v >> 8) & 0xFF) / 255,
                     Double(v & 0xFF) / 255)
    }

    static var freq: (low: SIMD3<Double>, midLow: SIMD3<Double>,
                      midHigh: SIMD3<Double>, high: SIMD3<Double>) {
        (bandRGB("low"), bandRGB("midLow"), bandRGB("midHigh"), bandRGB("high"))
    }

    static func reset() {
        for stem in stems { UserDefaults.standard.removeObject(forKey: "col.stem.\(stem)") }
        for band in ["low", "midLow", "midHigh", "high"] {
            UserDefaults.standard.removeObject(forKey: "col.freq.\(band)")
        }
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X",
                      Int(c.redComponent * 255 + 0.5),
                      Int(c.greenComponent * 255 + 0.5),
                      Int(c.blueComponent * 255 + 0.5))
    }
}

/// A ColorPicker bound to a hex string in UserDefaults.
private func colorBind(_ key: String, _ def: String) -> Binding<Color> {
    Binding(
        get: { Color(hex: WavePrefs.hex(key, def)) ?? .white },
        set: { UserDefaults.standard.set($0.hex, forKey: key) })
}

/// General app prefs persisted in UserDefaults.
enum AppPrefs {
    static var demucsModel: String {
        UserDefaults.standard.string(forKey: "demucsModel") ?? "htdemucs"
    }
    static var bpmMin: Double {
        let v = UserDefaults.standard.double(forKey: "bpmMin")
        return v > 0 ? v : 60
    }
    static var bpmMax: Double {
        let v = UserDefaults.standard.double(forKey: "bpmMax")
        return v > 0 ? v : 200
    }
    static var autoAnalyze: Bool {
        UserDefaults.standard.bool(forKey: "autoAnalyze")
    }
    /// Whether tag/where-from saves also hit the original imported file.
    static var mirrorToSource: Bool {
        UserDefaults.standard.object(forKey: "mirrorToSource") as? Bool ?? true
    }
    static var beatGrid: Bool {
        UserDefaults.standard.object(forKey: "beatGrid") as? Bool ?? true
    }
    /// "blend" (energy-weighted mix) or "stacked" (vertical band segments).
    static var waveStyle: String {
        UserDefaults.standard.string(forKey: "waveStyle") ?? "blend"
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gear") }
            AnalysisSettings()
                .tabItem { Label("Analysis", systemImage: "waveform.path.ecg") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            IdentifySettings()
                .tabItem { Label("Identify", systemImage: "tag") }
        }
        .frame(width: 480, height: 460)
    }
}

private struct GeneralSettings: View {
    @AppStorage("autoAnalyze") private var autoAnalyze = false
    @AppStorage("mirrorToSource") private var mirrorToSource = true
    @AppStorage("dualDeck") private var dualDeck = false

    var body: some View {
        Form {
            Section("Library") {
                Toggle("Analyze stems and BPM after import", isOn: $autoAnalyze)
                Toggle("Write metadata to the original file too", isOn: $mirrorToSource)
                Text("When off, tag edits only touch MusicLab's library copy — your source files are never modified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Playback") {
                Toggle("Two decks and a mixer", isOn: $dualDeck)
                Text("Shows decks A and B side by side with an equal-power crossfader. Click a deck to pick where the library loads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AnalysisSettings: View {
    @AppStorage("demucsModel") private var model = "htdemucs"
    @AppStorage("bpmMin") private var bpmMin = 60.0
    @AppStorage("bpmMax") private var bpmMax = 200.0

    var body: some View {
        Form {
            Section("Stem separation") {
                Picker("Demucs model", selection: $model) {
                    Text("htdemucs — fast").tag("htdemucs")
                    Text("htdemucs_ft — finer, ~4× slower").tag("htdemucs_ft")
                }
                .pickerStyle(.radioGroup)
                Text("Applies to the next analysis — existing stems are not re-run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("BPM detection") {
                LabeledContent("Minimum BPM") {
                    TextField("", value: $bpmMin, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                }
                LabeledContent("Maximum BPM") {
                    TextField("", value: $bpmMax, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                }
                Text("Narrow the range for your genre to avoid half/double-time mistakes — e.g. 70–150 for hip-hop, 115–135 for house.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct AppearanceSettings: View {
    @AppStorage("waveStyle") private var waveStyle = "blend"
    @AppStorage("beatGrid") private var beatGrid = true

    var body: some View {
        Form {
            Section("Waveform") {
                Picker("Frequency display", selection: $waveStyle) {
                    Text("Blended").tag("blend")
                    Text("Stacked bands").tag("stacked")
                }
                .pickerStyle(.segmented)
                Toggle("Beat grid", isOn: $beatGrid)
            }
            Section("Frequency colors") {
                LabeledContent("Low  <200 Hz") {
                    ColorPicker("", selection: colorBind("col.freq.low", "#FF0000")).labelsHidden()
                }
                LabeledContent("Mid-low  200–700 Hz") {
                    ColorPicker("", selection: colorBind("col.freq.midLow", "#FF8C00")).labelsHidden()
                }
                LabeledContent("Mid-high  700–1400 Hz") {
                    ColorPicker("", selection: colorBind("col.freq.midHigh", "#00C800")).labelsHidden()
                }
                LabeledContent("High  >1400 Hz") {
                    ColorPicker("", selection: colorBind("col.freq.high", "#0064FF")).labelsHidden()
                }
            }
            Section("Stem colors") {
                ForEach(WavePrefs.stems, id: \.self) { stem in
                    LabeledContent(stem.capitalized) {
                        ColorPicker("", selection: colorBind(
                            "col.stem.\(stem)",
                            WavePrefs.hex("col.stem.\(stem)",
                                          ["vocals": "#30D158", "drums": "#FF453A",
                                           "bass": "#0A84FF", "other": "#FF9F0A"][stem] ?? "#FF9F0A")))
                            .labelsHidden()
                    }
                }
                Button("Reset colors to defaults") { WavePrefs.reset() }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct IdentifySettings: View {
    @AppStorage("acoustIdKey") private var acoustIdKey = ""
    @AppStorage("identifyProvider") private var provider = "auto"
    @AppStorage("identifyArtwork") private var artwork = true
    @State private var allOn = true

    var body: some View {
        Form {
            Section("Identification source") {
                Picker("Identify using", selection: $provider) {
                    Text("Fingerprint, then search").tag("auto")
                    Text("Fingerprint only").tag("fingerprint")
                    Text("Search only").tag("search")
                }
                .pickerStyle(.radioGroup)
                LabeledContent("AcoustID API key") {
                    TextField("from acoustid.org — optional", text: $acoustIdKey)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Fingerprinting matches on the audio itself and works even with wrong or missing tags. It needs a free AcoustID key and is non-commercial use only. Without a key, Identify falls back to a MusicBrainz search on the existing title/artist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Fields to write on Identify") {
                Toggle("Select all", isOn: $allOn)
                    .onChange(of: allOn) { _, on in
                        for (key, _, _) in IdentifyPrefs.fields { IdentifyPrefs.set(key, on) }
                        IdentifyPrefs.set("idf.compilation", on)
                        artwork = on
                    }
                ForEach(IdentifyPrefs.fields, id: \.0) { key, label, _ in
                    Toggle(label, isOn: Binding(
                        get: { IdentifyPrefs.isOn(key) },
                        set: { IdentifyPrefs.set(key, $0) }))
                }
                Toggle("Compilation flag", isOn: Binding(
                    get: { IdentifyPrefs.wantCompilation },
                    set: { IdentifyPrefs.set("idf.compilation", $0) }))
                Toggle("Artwork", isOn: $artwork)
                Text("Only enabled fields are overwritten — everything else on the file stays as it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
