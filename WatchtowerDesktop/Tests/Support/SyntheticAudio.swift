import Foundation

/// Generated non-speech for the transcription hallucination bench (board #554,
/// spec D6): the repo holds no recordings, so every filler stretch is built in
/// code — 16 kHz mono Float32, deterministic for a given seed.
package enum SyntheticAudio {
    package static let sampleRate = 16_000

    /// Digital silence: exact zeros.
    package static func zeros(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: count(seconds))
    }

    /// Gaussian white noise scaled to `dBFS` RMS.
    package static func whiteNoise(seconds: Double, dBFS: Double, seed: UInt64) -> [Float] {
        var rng = SeededGenerator(seed: seed)
        return scaled((0..<count(seconds)).map { _ in rng.nextGaussian() }, toDBFS: dBFS)
    }

    /// Pink (1/f) noise scaled to `dBFS` RMS — room tone shape. Paul Kellet's
    /// economy filter over Gaussian white noise.
    package static func pinkNoise(seconds: Double, dBFS: Double, seed: UInt64) -> [Float] {
        var rng = SeededGenerator(seed: seed)
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        let raw = (0..<count(seconds)).map { _ -> Float in
            let white = rng.nextGaussian()
            b0 = 0.99765 * b0 + white * 0.0990460
            b1 = 0.96300 * b1 + white * 0.2965164
            b2 = 0.57000 * b2 + white * 1.0526913
            return b0 + b1 + b2 + white * 0.1848
        }
        return scaled(raw, toDBFS: dBFS)
    }

    /// Mains hum: `fundamental` Hz plus three harmonics at falling levels,
    /// scaled to `dBFS` RMS.
    package static func hum(seconds: Double, dBFS: Double, fundamental: Double = 50) -> [Float] {
        let levels: [Double] = [1, 0.5, 0.3, 0.2]
        let raw = (0..<count(seconds)).map { index -> Float in
            let time = Double(index) / Double(sampleRate)
            let value = levels.enumerated().reduce(0.0) { sum, harmonic in
                sum + harmonic.element * sin(2 * .pi * fundamental * Double(harmonic.offset + 1) * time)
            }
            return Float(value)
        }
        return scaled(raw, toDBFS: dBFS)
    }

    /// The "system audio went quiet" tail: white noise whose level slides
    /// linearly in dB from `fromDBFS` to `toDBFS` over `fadeSec`, then holds
    /// at `toDBFS` (dither) for the rest of `seconds`.
    package static func fadeToDither(
        seconds: Double,
        fromDBFS: Double = -45,
        toDBFS: Double = -90,
        fadeSec: Double = 3,
        seed: UInt64
    ) -> [Float] {
        let unit = whiteNoise(seconds: seconds, dBFS: 0, seed: seed)
        let fadeCount = Double(count(fadeSec))
        return unit.enumerated().map { index, sample in
            let progress = min(Double(index) / fadeCount, 1)
            let level = fromDBFS + (toDBFS - fromDBFS) * progress
            return sample * Float(pow(10, level / 20))
        }
    }

    /// RMS level in dBFS (−∞ for silence).
    package static func dBFS(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -.infinity }
        let meanSquare = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return 10 * log10(meanSquare)
    }

    /// One stretch of a composed clip.
    package enum Piece {
        case speech([Float], reference: String)
        case filler([Float])
    }

    package struct TimelineEntry: Equatable {
        package enum Kind: String, Equatable { case speech, filler }

        package let kind: Kind
        /// Sample offsets in the composed clip.
        package let range: Range<Int>
        /// The transcript of a speech piece; nil for filler.
        package let reference: String?

        package var startSec: Double { Double(range.lowerBound) / Double(SyntheticAudio.sampleRate) }
        package var endSec: Double { Double(range.upperBound) / Double(SyntheticAudio.sampleRate) }
    }

    package struct Composition {
        package let samples: [Float]
        package let timeline: [TimelineEntry]

        /// Filler stretches in seconds, the shape `TranscriptBenchMetrics.wordsInFiller` takes.
        package var fillerSeconds: [ClosedRange<Double>] {
            timeline.filter { $0.kind == .filler }.map { $0.startSec...$0.endSec }
        }

        /// The speech references in order, space-joined.
        package var reference: String {
            timeline.compactMap(\.reference).joined(separator: " ")
        }
    }

    /// Concatenates the pieces and records where each one landed.
    package static func compose(_ pieces: [Piece]) -> Composition {
        var samples: [Float] = []
        var timeline: [TimelineEntry] = []
        for piece in pieces {
            let start = samples.count
            switch piece {
            case let .speech(audio, reference):
                samples += audio
                timeline.append(TimelineEntry(kind: .speech, range: start..<samples.count, reference: reference))
            case let .filler(audio):
                samples += audio
                timeline.append(TimelineEntry(kind: .filler, range: start..<samples.count, reference: nil))
            }
        }
        return Composition(samples: samples, timeline: timeline)
    }

    private static func count(_ seconds: Double) -> Int {
        Int((seconds * Double(sampleRate)).rounded())
    }

    private static func scaled(_ samples: [Float], toDBFS target: Double) -> [Float] {
        let current = dBFS(samples)
        guard current.isFinite else { return samples }
        let gain = Float(pow(10, (target - current) / 20))
        return samples.map { $0 * gain }
    }
}

/// SplitMix64: a tiny deterministic generator, so a seed always gives the
/// same filler on every machine and run.
package struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    package init(seed: UInt64) { state = seed }

    package mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Standard normal sample (Box–Muller).
    mutating func nextGaussian() -> Float {
        let u1 = Double.random(in: Double.ulpOfOne..<1, using: &self)
        let u2 = Double.random(in: 0..<1, using: &self)
        return Float((-2 * log(u1)).squareRoot() * cos(2 * .pi * u2))
    }
}
