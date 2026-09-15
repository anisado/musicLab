import Accelerate
import AVFoundation
import Foundation

enum AudioError: Error {
    case cannotDecode
}

/// Decode any readable audio file to mono Float32 samples at `rate`, so the
/// analysis is independent of the source format.
func decodeMono(_ url: URL, rate: Double = 22050) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let source = file.processingFormat
    guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: source, to: target)
    else { throw AudioError.cannotDecode }

    let capacity = AVAudioFrameCount(Double(file.length) / source.sampleRate * rate) + 1024
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity),
          let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 32768)
    else { throw AudioError.cannotDecode }

    var conversionError: NSError?
    converter.convert(to: output, error: &conversionError) { _, status in
        if file.framePosition >= file.length {
            status.pointee = .endOfStream
            return nil
        }
        do {
            try file.read(into: input)
            status.pointee = input.frameLength == 0 ? .endOfStream : .haveData
            return input
        } catch {
            status.pointee = .endOfStream
            return nil
        }
    }
    if let conversionError { throw conversionError }

    let count = Int(output.frameLength)
    guard count > 0, let channel = output.floatChannelData?[0] else { throw AudioError.cannotDecode }
    return Array(UnsafeBufferPointer(start: channel, count: count))
}

/// Per-millisecond energy in four bands, used to colour the waveform:
/// low (kick/sub), midLow (bass/body), midHigh (vocals/instruments), high
/// (hats/air).
struct BandEnvelope {
    var low: [Float]
    var midLow: [Float]
    var midHigh: [Float]
    var high: [Float]
}

/// Max magnitude per fixed-size bucket — vectorized by folding each bucket
/// position with a strided maximum-magnitude pass instead of a scalar loop.
private func bucketMax(_ samples: [Float], perBucket: Int) -> [Float] {
    let count = samples.count / perBucket
    guard count > 0 else { return [] }
    var peaks = [Float](repeating: 0, count: count)
    samples.withUnsafeBufferPointer { src in
        let base = src.baseAddress!
        let stride = vDSP_Stride(perBucket)
        vDSP_vabs(base, stride, &peaks, 1, vDSP_Length(count))
        for k in 1 ..< perBucket {
            vDSP_vmaxmg(base + k, stride, peaks, 1, &peaks, 1, vDSP_Length(count))
        }
    }
    if samples.count > count * perBucket {
        var tail: Float = 0
        for i in count * perBucket ..< samples.count {
            tail = max(tail, abs(samples[i]))
        }
        peaks.append(tail)
    }
    return peaks
}

/// One peak per millisecond of audio, so zooming in keeps revealing detail.
func peakEnvelope(_ samples: [Float], rate: Double) -> [Float] {
    let perBucket = max(Int(rate) / 1000, 1)
    var peaks = bucketMax(samples, perBucket: perBucket)
    var loudest: Float = 0
    vDSP_maxv(peaks, 1, &loudest, vDSP_Length(peaks.count))
    if loudest > 0 {
        var scale = 1 / loudest
        vDSP_vsmul(peaks, 1, &scale, &peaks, 1, vDSP_Length(peaks.count))
    }
    return peaks
}

/// Splits the signal with one-pole filters and returns a per-millisecond
/// envelope per band. The split frequencies are chosen for the low 4410 Hz
/// analysis rate (Nyquist ~2205), so the top band starts well below it.
func bandEnvelope(_ samples: [Float], rate: Double) -> BandEnvelope {
    let lowPassed = lowpass(samples, rate: rate, cutoff: 200)
    let midLowPassed = lowpass(samples, rate: rate, cutoff: 700)
    let midHighPassed = lowpass(samples, rate: rate, cutoff: 1400)
    let count = samples.count
    // each band is the difference between consecutive low-passed signals
    var midLowSignal = [Float](repeating: 0, count: count)
    var midHighSignal = [Float](repeating: 0, count: count)
    var highSignal = [Float](repeating: 0, count: count)
    vDSP_vsub(lowPassed, 1, midLowPassed, 1, &midLowSignal, 1, vDSP_Length(count))
    vDSP_vsub(midLowPassed, 1, midHighPassed, 1, &midHighSignal, 1, vDSP_Length(count))
    vDSP_vsub(midHighPassed, 1, samples, 1, &highSignal, 1, vDSP_Length(count))
    let perBucket = max(Int(rate) / 1000, 1)
    var low = bucketMax(lowPassed, perBucket: perBucket)
    var midLow = bucketMax(midLowSignal, perBucket: perBucket)
    var midHigh = bucketMax(midHighSignal, perBucket: perBucket)
    var high = bucketMax(highSignal, perBucket: perBucket)
    // each band is normalized by its own typical level, so color shows the
    // spectral tilt of the moment — without this, low frequencies dominate
    // every column because music simply carries more bass energy
    func normalize(_ band: inout [Float]) {
        var rms: Float = 0
        vDSP_rmsqv(band, 1, &rms, vDSP_Length(band.count))
        var scale = 1 / max(rms, 0.01)
        vDSP_vsmul(band, 1, &scale, &band, 1, vDSP_Length(band.count))
    }
    normalize(&low)
    normalize(&midLow)
    normalize(&midHigh)
    normalize(&high)
    return BandEnvelope(low: low, midLow: midLow, midHigh: midHigh, high: high)
}

/// Flat binary dump of an envelope + its four bands, so a track only gets
/// decoded for the waveform once — after that loads read this file.
func writeEnvelopeCache(_ url: URL, peaks: [Float], bands: BandEnvelope) {
    var data = Data()
    var count = UInt32(peaks.count)
    data.append(Data(bytes: &count, count: 4))
    for array in [peaks, bands.low, bands.midLow, bands.midHigh, bands.high] {
        array.withUnsafeBytes { data.append(contentsOf: $0) }
    }
    try? data.write(to: url)
}

func readEnvelopeCache(_ url: URL) -> (peaks: [Float], bands: BandEnvelope)? {
    guard let data = try? Data(contentsOf: url), data.count >= 4 else { return nil }
    let n = data.withUnsafeBytes { $0.load(as: UInt32.self) }
    let bytes = Int(n) * 4
    guard n > 0, data.count == 4 + bytes * 5 else { return nil }
    func floats(_ band: Int) -> [Float] {
        data.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(
                start: raw.baseAddress!.advanced(by: 4 + band * bytes)
                    .assumingMemoryBound(to: Float.self),
                count: Int(n)
            ))
        }
    }
    return (floats(0), BandEnvelope(low: floats(1), midLow: floats(2),
                                   midHigh: floats(3), high: floats(4)))
}

private func lowpass(_ samples: [Float], rate: Double, cutoff: Double) -> [Float] {
    let rc = 1 / (2 * Double.pi * cutoff)
    let a = Float((1 / rate) / (rc + 1 / rate))
    var out = [Float](repeating: 0, count: samples.count)
    var prev: Float = 0
    for i in samples.indices {
        prev += a * (samples[i] - prev)
        out[i] = prev
    }
    return out
}
