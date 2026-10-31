import Accelerate
import Foundation

/// Ermittelt Tempo (BPM) und Tonart aus Audiodaten – mono, 11 025 Hz, wie sie `AudioDecoder` liefert.
///
/// Tempo: Einsatzstärke (spektraler Fluss) → Autokorrelation → Kammfilter über 60–200 BPM mit einer
/// Vorliebe für Club-Tempi um 125 BPM (gegen Halb-/Doppel-Fehler).
/// Tonart: Chromagramm (Energie je Halbton) → Vergleich mit Dur- und Moll-Profilen (Krumhansl/Temperley).
enum AudioAnalyzer {
    static let sampleRate = 11_025.0

    struct Result: Equatable, Sendable {
        var bpm: Double?
        var key: MusicalKey?
    }

    static func analyze(_ samples: [Float], sampleRate: Double = sampleRate) -> Result {
        // Fürs Tempo reicht die Mitte des Titels (ohne Intro/Outro), höchstens zwei Minuten.
        let count = samples.count
        let window = min(count, Int(sampleRate * 120))
        let start = max(0, (count - window) / 2)
        let middle = Array(samples[start..<(start + window)])
        return Result(bpm: tempo(middle, sampleRate: sampleRate), key: key(samples, sampleRate: sampleRate))
    }

    // MARK: - Tempo

    static func tempo(_ samples: [Float], sampleRate: Double = sampleRate) -> Double? {
        let frameSize = 1024
        let hop = 64
        guard samples.count > frameSize * 16 else { return nil }
        let envelope = onsetEnvelope(samples, frameSize: frameSize, hop: hop)
        return estimateTempo(envelope: envelope, frameRate: sampleRate / Double(hop))
    }

    /// Wie stark sich das Spektrum von Fenster zu Fenster aufhellt – Spitzen an Schlägen.
    static func onsetEnvelope(_ samples: [Float], frameSize: Int, hop: Int) -> [Float] {
        let spectra = Spectrogram(frameSize: frameSize)
        let bins = frameSize / 2
        var previous = [Float](repeating: 0, count: bins)
        var envelope: [Float] = []
        envelope.reserveCapacity(samples.count / hop)

        spectra.forEachFrame(of: samples, hop: hop) { magnitudes in
            var compressed = [Float](repeating: 0, count: bins)
            var one: Float = 1
            // log(1 + |X|) – laute und leise Passagen werden vergleichbar.
            vDSP_vsadd(magnitudes, 1, &one, &compressed, 1, vDSP_Length(bins))
            var count = Int32(bins)
            vvlogf(&compressed, compressed, &count)
            var flux: Float = 0
            for bin in 1..<bins {
                let rise = compressed[bin] - previous[bin]
                if rise > 0 { flux += rise }
            }
            envelope.append(flux)
            previous = compressed
        }

        // Gleitenden Mittelwert abziehen (≈ 0,4 s) und nur Anstiege behalten.
        let radius = 35
        var result = [Float](repeating: 0, count: envelope.count)
        var running: Float = 0
        var prefix = [Float](repeating: 0, count: envelope.count + 1)
        for (index, value) in envelope.enumerated() {
            running += value
            prefix[index + 1] = running
        }
        for index in envelope.indices {
            let low = max(0, index - radius)
            let high = min(envelope.count, index + radius + 1)
            let mean = (prefix[high] - prefix[low]) / Float(high - low)
            result[index] = max(0, envelope[index] - mean)
        }
        return result
    }

    /// Kammfilter über die Autokorrelation: Für jedes Tempo zählen die Schläge 1–4 Perioden später.
    static func estimateTempo(envelope: [Float], frameRate: Double, range: ClosedRange<Double> = 60...200) -> Double? {
        let count = envelope.count
        let maxLag = Int(ceil(frameRate * 60 / range.lowerBound * 4)) + 2
        guard count > maxLag * 2 else { return nil }

        var autocorrelation = [Float](repeating: 0, count: maxLag + 1)
        envelope.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            for lag in 0...maxLag {
                var sum: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &sum, vDSP_Length(count - lag))
                autocorrelation[lag] = sum / Float(count - lag)
            }
        }
        guard autocorrelation[0] > 0 else { return nil }

        func value(at lag: Double) -> Double {
            let low = Int(lag)
            guard low + 1 <= maxLag else { return 0 }
            let fraction = lag - Double(low)
            return Double(autocorrelation[low]) * (1 - fraction) + Double(autocorrelation[low + 1]) * fraction
        }

        let step = 0.05
        var candidates: [(bpm: Double, score: Double)] = []
        var bpm = range.lowerBound
        while bpm <= range.upperBound {
            let period = frameRate * 60 / bpm
            var comb = 0.0
            for multiple in 1...4 {
                comb += value(at: period * Double(multiple)) / Double(multiple).squareRoot()
            }
            // Vorliebe für Club-Tempi: Lognormal um 125 BPM.
            let octaves = log2(bpm / 125)
            let prior = exp(-0.5 * pow(octaves / 0.7, 2))
            candidates.append((bpm, comb * prior))
            bpm += step
        }

        guard let bestIndex = candidates.indices.max(by: { candidates[$0].score < candidates[$1].score }) else { return nil }
        let scores = candidates.map(\.score)
        let mean = scores.reduce(0, +) / Double(scores.count)
        // Ohne erkennbaren Rhythmus (Ambient, Sprache) lieber kein Tempo als ein falsches.
        guard mean > 0, candidates[bestIndex].score / mean > 1.25 else { return nil }

        var best = candidates[bestIndex].bpm
        if bestIndex > 0, bestIndex < candidates.count - 1 {
            let left = candidates[bestIndex - 1].score
            let center = candidates[bestIndex].score
            let right = candidates[bestIndex + 1].score
            let denominator = left - 2 * center + right
            if denominator != 0 { best += step * 0.5 * (left - right) / denominator }
        }
        return roundedTempo(best)
    }

    /// Club-Titel haben fast immer ganzzahlige Tempi: 123,9 → 124, sonst eine Nachkommastelle.
    static func roundedTempo(_ bpm: Double) -> Double {
        let whole = bpm.rounded()
        if abs(bpm - whole) <= 0.3 { return whole }
        return (bpm * 10).rounded() / 10
    }

    // MARK: - Tonart

    static func key(_ samples: [Float], sampleRate: Double = sampleRate) -> MusicalKey? {
        guard let chroma = chroma(samples, sampleRate: sampleRate) else { return nil }
        return bestKey(for: chroma)
    }

    /// Energie je Halbton (C … B), über den ganzen Ausschnitt gemittelt.
    static func chroma(_ samples: [Float], sampleRate: Double = sampleRate) -> [Double]? {
        let frameSize = 8192
        guard samples.count >= frameSize * 4 else { return nil }
        let spectra = Spectrogram(frameSize: frameSize)
        let binWidth = sampleRate / Double(frameSize)

        // Jedem Frequenzband seinen Halbton und ein Gewicht zuordnen (A1 bis A6).
        var mapping: [(bin: Int, pitch: Int, weight: Float)] = []
        for bin in 1..<(frameSize / 2) {
            let frequency = Double(bin) * binWidth
            guard frequency >= 55, frequency <= 1760 else { continue }
            let midi = 69 + 12 * log2(frequency / 440)
            let nearest = midi.rounded()
            let deviation = abs(midi - nearest)
            let weight = Float(max(0, 1 - 2 * deviation))
            guard weight > 0 else { continue }
            mapping.append((bin, ((Int(nearest) % 12) + 12) % 12, weight))
        }

        var total = [Double](repeating: 0, count: 12)
        var frames = 0
        spectra.forEachFrame(of: samples, hop: frameSize / 2) { magnitudes in
            var frame = [Float](repeating: 0, count: 12)
            for entry in mapping {
                frame[entry.pitch] += magnitudes[entry.bin] * entry.weight
            }
            let sum = frame.reduce(0, +)
            guard sum > 1e-3 else { return }
            for pitch in 0..<12 { total[pitch] += Double(frame[pitch] / sum) }
            frames += 1
        }
        guard frames > 0 else { return nil }
        return total.map { $0 / Double(frames) }
    }

    // Krumhansl-Kessler und Temperley (Kostka-Payne) – beide zusammen sind robuster als eines allein.
    private static let majorProfiles: [[Double]] = [
        [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88],
        [0.748, 0.060, 0.488, 0.082, 0.670, 0.460, 0.096, 0.715, 0.104, 0.366, 0.057, 0.400],
    ]
    private static let minorProfiles: [[Double]] = [
        [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17],
        [0.712, 0.084, 0.474, 0.618, 0.049, 0.460, 0.105, 0.747, 0.404, 0.067, 0.133, 0.330],
    ]

    private static let minorBias = 0.06

    static func bestKey(for chroma: [Double]) -> MusicalKey? {
        guard chroma.count == 12, chroma.contains(where: { $0 > 0 }) else { return nil }
        var best: (key: MusicalKey, score: Double)?
        for tonic in 0..<12 {
            for isMinor in [false, true] {
                let profiles = isMinor ? minorProfiles : majorProfiles
                var score = profiles.reduce(0.0) { sum, profile in
                    let rotated = (0..<12).map { profile[(($0 - tonic) % 12 + 12) % 12] }
                    return sum + correlation(chroma, rotated)
                } / Double(profiles.count)
                // Clubmusik steht meist in Moll – ohne diesen Ausgleich landet sie oft in der Paralleltonart (Dur).
                if isMinor { score += minorBias }
                if score > best?.score ?? -.infinity {
                    best = (MusicalKey(pitchClass: tonic, isMinor: isMinor), score)
                }
            }
        }
        return best.map(\.key)
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let meanA = a.reduce(0, +) / Double(a.count)
        let meanB = b.reduce(0, +) / Double(b.count)
        var numerator = 0.0
        var sumA = 0.0
        var sumB = 0.0
        for index in a.indices {
            let x = a[index] - meanA
            let y = b[index] - meanB
            numerator += x * y
            sumA += x * x
            sumB += y * y
        }
        let denominator = (sumA * sumB).squareRoot()
        return denominator > 0 ? numerator / denominator : 0
    }
}

// MARK: - Spektrum

/// Kurzzeit-Spektren (Hann-Fenster, FFT) – liefert je Fenster die Beträge der Frequenzbänder.
private final class Spectrogram {
    let frameSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]

    init(frameSize: Int) {
        self.frameSize = frameSize
        log2n = vDSP_Length(log2(Double(frameSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func forEachFrame(of samples: [Float], hop: Int, _ body: ([Float]) -> Void) {
        let half = frameSize / 2
        var frame = [Float](repeating: 0, count: frameSize)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var start = 0
        samples.withUnsafeBufferPointer { input in
            guard let base = input.baseAddress else { return }
            while start + frameSize <= samples.count {
                vDSP_vmul(base + start, 1, window, 1, &frame, 1, vDSP_Length(frameSize))
                real.withUnsafeMutableBufferPointer { realPointer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                        var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                        frame.withUnsafeBytes { raw in
                            vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        // Bei zrip steckt die Nyquist-Frequenz in imagp[0] – für uns unwichtig.
                        split.imagp[0] = 0
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                    }
                }
                body(magnitudes)
                start += hop
            }
        }
    }
}
