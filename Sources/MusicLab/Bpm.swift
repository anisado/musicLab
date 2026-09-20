import Foundation

enum Bpm {
    static var minBpm: Double { AppPrefs.bpmMin }
    static var maxBpm: Double { AppPrefs.bpmMax }
    static let rate = 22050.0
    static let frame = 1024
    static let hop = 256
    static let fps = rate / Double(hop)
    /// Tempi far from here are usually the double or half of the real one.
    static let preferred = 125.0
    static let preferenceWidth = 1.1

    /// In-place iterative radix-2 FFT.
    private static func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        var j = 0
        for i in 1 ..< n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var len = 2
        while len <= n {
            let angle = -2 * .pi / Double(len)
            let wRe = cos(angle), wIm = sin(angle)
            var start = 0
            while start < n {
                var curRe = 1.0, curIm = 0.0
                for offset in 0 ..< len / 2 {
                    let a = start + offset, b = a + len / 2
                    let tRe = re[b] * curRe - im[b] * curIm
                    let tIm = re[b] * curIm + im[b] * curRe
                    re[b] = re[a] - tRe
                    im[b] = im[a] - tIm
                    re[a] += tRe
                    im[a] += tIm
                    let nextRe = curRe * wRe - curIm * wIm
                    curIm = curRe * wIm + curIm * wRe
                    curRe = nextRe
                }
                start += len
            }
            len <<= 1
        }
    }

    /// Spectral flux: how much energy rises between successive spectra, minus the
    /// local average so build-ups and loudness changes do not drown the beats.
    private static func onsetEnvelope(_ samples: [Float]) -> [Double]? {
        let frames = (samples.count - frame) / hop
        guard frames >= 16 else { return nil }

        var window = [Double](repeating: 0, count: frame)
        for i in 0 ..< frame { window[i] = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(frame)) }

        let bins = frame / 2
        var previous = [Double](repeating: 0, count: bins)
        var flux = [Double](repeating: 0, count: frames)
        var re = [Double](repeating: 0, count: frame)
        var im = [Double](repeating: 0, count: frame)

        for f in 0 ..< frames {
            let start = f * hop
            for i in 0 ..< frame {
                re[i] = Double(samples[start + i]) * window[i]
                im[i] = 0
            }
            fft(&re, &im)
            // band-weighted flux: the kick defines the beat, so low-frequency
            // onsets dominate while mids and highs still contribute
            var low = 0.0, mid = 0.0, high = 0.0
            for bin in 0 ..< bins {
                let magnitude = log1p(20 * (re[bin] * re[bin] + im[bin] * im[bin]).squareRoot())
                let rise = magnitude - previous[bin]
                previous[bin] = magnitude
                guard rise > 0 else { continue }
                let hz = Double(bin) * rate / Double(frame)
                if hz < 200 { low += rise }
                else if hz < 1500 { mid += rise }
                else { high += rise }
            }
            flux[f] = low + 0.45 * mid + 0.2 * high
        }

        let half = Int((fps * 0.12).rounded())
        var envelope = [Double](repeating: 0, count: frames)
        for f in 0 ..< frames {
            var sum = 0.0, count = 0
            for i in max(f - half, 0) ..< min(f + half, frames) {
                sum += flux[i]
                count += 1
            }
            envelope[f] = max(flux[f] - sum / Double(count), 0)
        }
        return envelope
    }

    /// Autocorrelation via FFT: zero-pad, take the power spectrum and transform
    /// it back. Mean-centering first removes the DC pedestal that would inflate
    /// every lag and blur the tempo peak.
    private static func autocorrelation(_ envelope: [Double], maxLag: Int) -> [Double] {
        let n = envelope.count
        let mean = envelope.reduce(0, +) / Double(n)
        var size = 1
        while size < n * 2 { size <<= 1 }
        var re = [Double](repeating: 0, count: size)
        var im = [Double](repeating: 0, count: size)
        for i in 0 ..< n { re[i] = envelope[i] - mean }
        fft(&re, &im)
        for i in 0 ..< size {
            re[i] = re[i] * re[i] + im[i] * im[i]
            im[i] = 0
        }
        fft(&re, &im)
        var values = [Double](repeating: 0, count: maxLag + 1)
        for lag in 1 ... min(maxLag, n - 1) {
            values[lag] = re[lag] / Double(size * (n - lag))
        }
        return values
    }

    private static func at(_ values: [Double], _ lag: Double) -> Double {
        guard lag >= 1, lag < Double(values.count - 1) else { return 0 }
        let low = Int(lag)
        return values[low] + (values[low + 1] - values[low]) * (lag - Double(low))
    }

    /// Comb-filter score: a real tempo lines up at its beat period and whole
    /// multiples of it, ruling out periods that are not a beat at all.
    private static func combScore(_ correlation: [Double], _ bpm: Double) -> Double {
        let lag = fps * 60 / bpm
        return at(correlation, lag) + 0.7 * at(correlation, lag * 2)
            + 0.5 * at(correlation, lag * 3) + 0.3 * at(correlation, lag * 4)
    }

    /// Multiples of a beat score alike, so lean towards a human-countable tempo.
    /// With a `reference` (the track's global tempo) the lean is a tight band
    /// around it, which rejects half/double-tempo windows outright.
    private static func scoreTempo(_ correlation: [Double], _ bpm: Double, reference: Double?) -> Double {
        let anchor = reference ?? preferred
        let width = reference == nil ? preferenceWidth : 0.35
        let distance = log2(bpm / anchor) / width
        return combScore(correlation, bpm) * exp(-0.5 * distance * distance)
    }

    /// Highest-scoring tempo in a correlation curve, nil when the curve is flat.
    private static func scanTempo(_ correlation: [Double], reference: Double? = nil) -> Double? {
        var best: Double? = nil
        var bestScore = 0.0, total = 0.0, candidates = 0
        var bpm = minBpm
        while bpm <= maxBpm {
            let score = scoreTempo(correlation, bpm, reference: reference)
            total += max(score, 0)
            candidates += 1
            if score > bestScore {
                bestScore = score
                best = bpm
            }
            bpm += 0.1
        }
        let average = total / Double(candidates)
        guard let best, average > 0, bestScore / average >= 1.5 else { return nil }
        return best
    }

    /// Local maxima of the tempo score — the correlation's top few peaks are
    /// all plausible, so each gets verified by real beat tracking rather than
    /// trusting the tallest one. This is what resolves the half/double-tempo
    /// ambiguity that a correlation peak alone cannot.
    private static func tempoCandidates(_ correlation: [Double], limit: Int = 6) -> [Double] {
        var scored: [(bpm: Double, score: Double)] = []
        var bpm = minBpm
        while bpm <= maxBpm {
            let score = scoreTempo(correlation, bpm, reference: nil)
            if score > 0 { scored.append((bpm, score)) }
            bpm += 0.1
        }
        var peaks: [(Double, Double)] = []
        for (index, candidate) in scored.enumerated() {
            let window = scored[max(0, index - 3) ... min(scored.count - 1, index + 3)]
            if candidate.score >= window.map(\.score).max() ?? 0 {
                peaks.append(candidate)
            }
        }
        peaks.sort { $0.1 > $1.1 }
        var out: [Double] = []
        for peak in peaks where !out.contains(where: { abs(log2($0 / peak.0)) < 0.02 }) {
            out.append(peak.0)
            if out.count == limit { break }
        }
        return out
    }

    /// Dynamic-programming beat tracking (Ellis): the globally most consistent
    /// beat sequence at a target period — each beat collects onset strength,
    /// and intervals that deviate from the period pay a quadratic log penalty.
    /// Returns the beat positions (envelope frames) and the mean onset energy
    /// they land on — the quality score used to compare tempo candidates.
    private static func trackBeats(_ envelope: [Double], period: Double)
        -> (beats: [Double], score: Double)
    {
        let n = envelope.count
        guard n > 0, period >= 2 else { return ([], 0) }
        let loLag = max(1, Int(period * 0.85))
        let hiLag = Int(period * 1.15)
        var score = [Double](repeating: 0, count: n)
        var back = [Int](repeating: 0, count: n)
        let tightness = 400.0
        for i in 0 ..< n {
            var best = -Double.infinity
            var bestLag = 0
            if i >= loLag {
                for lag in loLag ... min(hiLag, i) {
                    let dev = log(Double(lag) / period)
                    let value = score[i - lag] - tightness * dev * dev
                    if value > best { best = value; bestLag = lag }
                }
            }
            score[i] = envelope[i] + (bestLag > 0 ? best : 0)
            back[i] = bestLag
        }
        // finish on the strongest beat within the last period
        var end = 0
        var bestEnd = -Double.infinity
        for i in max(0, n - hiLag) ..< n where score[i] > bestEnd {
            bestEnd = score[i]
            end = i
        }
        var beats: [Double] = []
        var position = end
        while position > 0 {
            beats.append(Double(position))
            let lag = back[position]
            guard lag > 0 else { break }
            position -= lag
        }
        beats.append(Double(position))
        let mean = beats.isEmpty ? 0 :
            beats.map { envelope[Int($0)] }.reduce(0, +) / Double(beats.count)
        return (beats.reversed(), mean)
    }

    /// Onset energy collected by a pulse train of period `lag` starting at `phase`.
    private static func pulseTrain(_ envelope: [Double], lag: Double, phase: Double) -> Double {
        var sum = 0.0
        var position = phase
        while position < Double(envelope.count) {
            sum += at(envelope, position)
            position += lag
        }
        return sum
    }

    /// Land the grid on the beats: search period and phase around the detected
    /// tempo for the pulse train that collects the most onset energy.
    private static func alignGrid(_ envelope: [Double], lag: Double) -> (lag: Double, phase: Double) {
        var best = (lag: lag, phase: 0.0, score: -1.0)
        for step in -20 ... 20 {
            let candidate = lag * (1 + Double(step) * 0.001)
            var phase = 0.0
            while phase < candidate {
                let score = pulseTrain(envelope, lag: candidate, phase: phase)
                if score > best.score { best = (candidate, phase, score) }
                phase += 0.25
            }
        }
        return (best.lag, best.phase)
    }

    /// Tempo of successive windows, so a track that speeds up or slows down gets
    /// a map of sections instead of one average. Each section also gets its own
    /// beat phase so the grid stays aligned across tempo changes.
    private static func tempoMap(_ envelope: [Double], reference: Double, maxLag: Int) -> [TempoSection]? {
        let windowFrames = Int(fps * 8)
        let hop = Int(fps * 3)
        let shortest = Int(fps * 4)
        guard envelope.count >= windowFrames + shortest else { return nil }

        struct Window { var start: Double; var bpm: Double? }
        var windows: [Window] = []
        var start = 0
        while start + shortest <= envelope.count {
            let slice = Array(envelope[start ..< min(start + windowFrames, envelope.count)])
            let correlation = autocorrelation(slice, maxLag: maxLag)
            var bpm = scanTempo(correlation, reference: reference)
            if bpm == nil, let raw = scanTempo(correlation) {
                // the anchored scan came up flat — take the raw peak but only
                // when it still sits within the reference band after folding
                var b = raw
                while b < reference * 0.8 { b *= 2 }
                while b > reference * 1.25 { b /= 2 }
                if abs(log2(b / reference)) <= 0.35 { bpm = b }
            }
            windows.append(Window(start: Double(start) / fps, bpm: bpm))
            start += hop
        }
        guard windows.contains(where: { $0.bpm != nil }) else { return nil }

        // median-smooth neighbours to reject single-window outliers
        let raw = windows.map { $0.bpm }
        for i in windows.indices {
            let neighbors = raw[max(0, i - 1) ... min(raw.count - 1, i + 1)].compactMap { $0 }
            if neighbors.count >= 2 { windows[i].bpm = neighbors.sorted()[neighbors.count / 2] }
        }

        // stretches without a clear beat (breaks, intros) keep the tempo around them
        var last = reference
        for i in windows.indices {
            if let bpm = windows[i].bpm { last = bpm } else { windows[i].bpm = last }
        }

        // neighbours that agree within a few percent are one section
        struct Section { var start: Double; var bpm: Double; var count: Int }
        var sections: [Section] = []
        for window in windows {
            let bpm = window.bpm!
            if var previous = sections.last,
               abs(bpm - previous.bpm) / previous.bpm <= 0.035 {
                previous.bpm = (previous.bpm * Double(previous.count) + bpm) / Double(previous.count + 1)
                previous.count += 1
                sections[sections.count - 1] = previous
            } else {
                sections.append(Section(start: window.start, bpm: bpm, count: 1))
            }
        }
        guard sections.count >= 2 else { return nil }
        sections[0].start = 0

        // align each section's grid on its own beats so a tempo change does
        // not leave the rest of the track out of phase
        return sections.enumerated().map { index, section in
            let lag = fps * 60 / section.bpm
            let f0 = Int(section.start * fps)
            let f1 = index + 1 < sections.count ? Int(sections[index + 1].start * fps) : envelope.count
            var phase: Double? = nil
            if Double(f1 - f0) > lag * 2 {
                var bestScore = -1.0
                var candidate = 0.0
                while candidate < lag {
                    var sum = 0.0
                    var position = candidate
                    while Double(f0) + position < Double(f1) {
                        sum += at(envelope, Double(f0) + position)
                        position += lag
                    }
                    if sum > bestScore { bestScore = sum; phase = (Double(f0) + candidate) / fps }
                    candidate += 0.25
                }
            }
            return TempoSection(
                start: (section.start * 100).rounded() / 100,
                bpm: (section.bpm * 100).rounded() / 100,
                phase: phase.map { ($0 * 100).rounded() / 100 }
            )
        }
    }

    /// Mean onset energy the grid lands on when it is offset from the tracked
    /// beats by `fraction` of a period.
    private static func gridEnergy(_ envelope: [Double], beats: [Double], lag: Double, fraction: Double) -> Double {
        guard !beats.isEmpty else { return 0 }
        return beats.map { at(envelope, $0 + lag * fraction) }.reduce(0, +) / Double(beats.count)
    }

    /// Beat tracking cannot tell a tempo from its half or double: both grids
    /// land on real onsets. The offbeats decide it — hits between the tracked
    /// beats that are nearly as strong mean the real beat is twice as fast;
    /// every other tracked beat being weak means it is half as fast.
    private static func resolveOctave(_ envelope: [Double], beats: [Double], lag: Double)
        -> (lag: Double, offset: Double)
    {
        let bpm = fps * 60 / lag
        let onBeat = gridEnergy(envelope, beats: beats, lag: lag, fraction: 0)
        guard onBeat > 0 else { return (lag, beats[0]) }

        if bpm * 2 <= maxBpm, bpm < preferred {
            let offBeat = gridEnergy(envelope, beats: beats, lag: lag, fraction: 0.5)
            let quarter = max(gridEnergy(envelope, beats: beats, lag: lag, fraction: 0.25),
                              gridEnergy(envelope, beats: beats, lag: lag, fraction: 0.75))
            // offbeats carry the beat, and the quarter positions do not — so
            // this is not just a dense hi-hat pattern
            if offBeat / onBeat > 0.75, quarter / onBeat < 0.6 {
                return (lag / 2, beats[0])
            }
        }

        if bpm / 2 >= minBpm, bpm > preferred * 1.2, beats.count >= 8 {
            var even = 0.0, odd = 0.0
            for (index, beat) in beats.enumerated() {
                if index % 2 == 0 { even += at(envelope, beat) } else { odd += at(envelope, beat) }
            }
            even /= Double((beats.count + 1) / 2)
            odd /= Double(beats.count / 2)
            let strong = max(even, odd), weak = min(even, odd)
            if strong > 0, weak / strong < 0.3 {
                return (lag * 2, even >= odd ? beats[0] : beats[1])
            }
        }
        return (lag, beats[0])
    }

    /// Kick onsets per millisecond: the low band, rectified, smoothed, and
    /// half-wave differentiated so only energy rises count.
    private static func kickOnsets(_ samples: [Float]) -> [Double] {
        let rc = 1 / (2 * Double.pi * 150)
        let a = Float((1 / rate) / (rc + 1 / rate))
        var prev: Float = 0
        var envelope = [Double](repeating: 0, count: Int(Double(samples.count) * 1000 / rate) + 1)
        for k in samples.indices {
            prev += a * (samples[k] - prev)
            let i = Int(Double(k) * 1000 / rate)
            envelope[i] = max(envelope[i], Double(abs(prev)))
        }
        var smooth = envelope
        for i in 1 ..< smooth.count { smooth[i] = max(envelope[i], smooth[i - 1] * 0.9) }
        var onsets = [Double](repeating: 0, count: smooth.count)
        for i in 1 ..< smooth.count { onsets[i] = max(0, smooth[i] - smooth[i - 1]) }
        return onsets
    }

    /// Shift the grid so its lines sit on the kick hits the waveform shows.
    /// Every phase within one period is tried and the shift is only taken
    /// when it clearly beats the tracker's own phase — so an offbeat or a
    /// constant lag gets corrected while syncopated grooves keep their beat.
    static func refinePhase(_ analysis: BeatAnalysis, samples: [Float]) -> BeatAnalysis {
        let onsets = kickOnsets(samples)
        guard onsets.count > 2000 else { return analysis }
        let duration = Double(onsets.count) / 1000
        let beats = analysis.beats(from: 0, to: duration).map(\.time)
        guard beats.count >= 8 else { return analysis }
        let period = 60 / analysis.bpm

        func score(_ shift: Double) -> Double {
            var total = 0.0
            for beat in beats {
                let centre = Int((beat + shift) * 1000)
                let lo = max(0, centre - 12), hi = min(onsets.count - 1, centre + 12)
                guard lo <= hi else { continue }
                var best = 0.0
                for i in lo ... hi { best = max(best, onsets[i]) }
                total += best
            }
            return total
        }

        let steps = max(Int(period * 1000 / 4), 1)
        let current = score(0)
        var bestShift = 0.0, bestScore = current
        for step in 0 ..< steps {
            let shift = -period / 2 + period * Double(step) / Double(steps)
            let value = score(shift)
            if value > bestScore { bestScore = value; bestShift = shift }
        }
        // a small correction is always cheap; jumping to another phase of
        // the bar needs a clear win over where the tracker put the beat
        let small = abs(bestShift) < period * 0.15
        guard bestShift != 0, small || bestScore > current * 1.35 else { return analysis }

        var refined = analysis
        refined.offset = ((analysis.offset + bestShift).truncatingRemainder(dividingBy: period) + period)
            .truncatingRemainder(dividingBy: period)
        refined.map = analysis.map?.map { section in
            var section = section
            if let phase = section.phase { section.phase = phase + bestShift }
            return section
        }
        return refined
    }

    /// Estimate the tempo of decoded mono samples (at `rate`), with the offset
    /// of the first beat and a tempo map when the tempo changes inside the
    /// track. Nil when there is no clear beat.
    static func detect(_ samples: [Float]) -> BeatAnalysis? {
        guard samples.count >= Int(rate) * 5,
              let envelope = onsetEnvelope(samples),
              envelope.reduce(0, +) > 0
        else { return nil }

        let maxLag = Int(((fps * 60) / minBpm * 4).rounded(.up))
        let correlation = autocorrelation(envelope, maxLag: maxLag)

        // every correlation peak is a plausible tempo — track actual beats at
        // each and keep the sequence that lands hardest on real onsets
        var lag = 0.0
        var beatFrames: [Double] = []
        var bestScore = -Double.infinity
        for candidate in tempoCandidates(correlation) {
            let tracked = trackBeats(envelope, period: fps * 60 / candidate)
            let combined = tracked.score * max(combScore(correlation, candidate), 1e-6)
            if combined > bestScore {
                bestScore = combined
                beatFrames = tracked.beats
                lag = fps * 60 / candidate
            }
        }
        if lag == 0 {
            guard let best = scanTempo(correlation) else { return nil }
            lag = fps * 60 / best
        }

        var offsetFrame = 0.0
        if beatFrames.count >= 2 {
            // beats sit on whole frames, so any single interval is quantised
            // to ~1.5% at 128 BPM; averaging the regular intervals of the
            // whole grid reads the period to a fraction of a frame
            var sum = 0.0, count = 0
            for i in 1 ..< beatFrames.count {
                let interval = beatFrames[i] - beatFrames[i - 1]
                if abs(interval / lag - 1) <= 0.15 { sum += interval; count += 1 }
            }
            if count > 0 { lag = sum / Double(count) }
            offsetFrame = beatFrames[0]
            (lag, offsetFrame) = resolveOctave(envelope, beats: beatFrames, lag: lag)
        } else {
            let grid = alignGrid(envelope, lag: lag)
            lag = grid.lag
            offsetFrame = grid.phase
        }

        // flux at a frame is the rise from the frame before it, and a frame reacts
        // to a transient anywhere inside its window, so the hit itself sits a hop
        // plus half a window later than the frame the energy lands on
        let offset = (Double(offsetFrame + 1) * Double(hop) + Double(frame) / 2) / rate
        let period = lag / fps
        let refined = fps * 60 / lag
        return BeatAnalysis(
            bpm: (refined * 100).rounded() / 100,
            offset: (offset.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period),
            map: tempoMap(envelope, reference: refined, maxLag: maxLag)
        )
    }
}
