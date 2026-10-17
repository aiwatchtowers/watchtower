import Foundation

/// The window gate's decisions (board #554, spec D2), pure so the rules are
/// pinned without a model. Speech ranges are what a speech detector returned
/// for one window: sorted, non-overlapping, already padded.
package enum SpeechGate {
    /// A window with less detected speech than this is silent: it is never
    /// decoded (L1). Below a short word, so a lone cough or click does not
    /// open the window to Whisper.
    package static let minWindowSpeechSec = 0.3
    /// A decoded segment is kept when it overlaps speech by at least this
    /// long… (L2)
    package static let minOverlapSec = 0.2
    /// …or by at least this share of its own duration. Whisper's segment
    /// timestamps drift (after a pause the first segment often starts several
    /// seconds before the speech does), so the rule is generous: losing real
    /// speech is the worse error.
    package static let minOverlapFraction = 0.3

    package static func isSilent(_ speech: [Range<Int>], sampleRate: Int) -> Bool {
        let total = speech.reduce(0) { $0 + $1.count }
        return Double(total) / Double(sampleRate) < minWindowSpeechSec
    }

    /// L5 (spec D5): the samples with everything outside `speech` set to
    /// exactly 0, for engines that decode the whole recording at once.
    package static func muted(_ samples: [Float], keeping speech: [Range<Int>]) -> [Float] {
        [Float](unsafeUninitializedCapacity: samples.count) { buffer, count in
            writeMuted(samples, keeping: speech, into: buffer)
            count = samples.count
        }
    }

    /// `muted`, written straight into `destination` (at least
    /// `samples.count` long), so an engine that copies the samples into its
    /// own buffer anyway mutes them on the way instead of holding one more
    /// copy of the recording (board #564).
    package static func writeMuted(
        _ samples: [Float],
        keeping speech: [Range<Int>],
        into destination: UnsafeMutableBufferPointer<Float>
    ) {
        precondition(destination.count >= samples.count)
        guard let base = destination.baseAddress else { return }
        base.initialize(repeating: 0, count: samples.count)
        samples.withUnsafeBufferPointer { source in
            for range in speech {
                let kept = range.clamped(to: 0..<samples.count)
                guard !kept.isEmpty, let from = source.baseAddress else { continue }
                (base + kept.lowerBound).update(from: from + kept.lowerBound, count: kept.count)
            }
        }
    }

    /// Sorted ranges with overlapping or touching neighbours joined.
    package static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        ranges.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { result, range in
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
    }

    /// Whether a segment (seconds from the window start) is kept against the
    /// window's speech ranges (sample offsets). A zero-length segment is kept
    /// only when its start lies inside a range.
    package static func keepsSegment(startSec: Double, endSec: Double, speech: [Range<Int>], sampleRate: Int) -> Bool {
        let rate = Double(sampleRate)
        let ranges = speech.map { (Double($0.lowerBound) / rate, Double($0.upperBound) / rate) }
        let duration = endSec - startSec
        guard duration > 0 else {
            return ranges.contains { startSec >= $0.0 && startSec <= $0.1 }
        }
        let overlap = ranges.reduce(0.0) { sum, range in
            sum + max(0, min(endSec, range.1) - max(startSec, range.0))
        }
        return overlap >= minOverlapSec || overlap >= minOverlapFraction * duration
    }
}

/// The detector used when the voice-activity model cannot load or fails on a
/// window (spec D1): 20 ms frames whose RMS clears a level are speech, with
/// the same minimum-speech, gap-merging and padding rules as the model's
/// segmentation. Stateless: the same samples always give the same ranges.
///
/// The level is adaptive: `floorDBFS`, or `marginDB` above the window's
/// quietest tenth of frames, whichever is higher. A fixed floor alone would
/// call steady −45 dBFS room tone or −40 dBFS mains hum speech; speech rises
/// well above the noise it sits in, steady noise does not rise above itself.
///
/// Tuned on the bench corpus (`testSpeechDetectorsOnCorpus`, 2026-10-12;
/// the setup is described at `SileroSpeechDetector.defaultThreshold`): half
/// the FLEURS utterances are recorded at −60 to −66 dBFS RMS (peaks −47 to
/// −54), so the spec's −50 dBFS floor skipped 14 speech-bearing windows;
/// −60 and below skipped none, −70 covers 88 % of the utterance spans against
/// 83 % at −60. Margin 10 dB opened 0 filler-only windows, 8 dB opened one
/// (pink noise at −45 dBFS) and 6 dB eighteen.
package struct EnergySpeechDetector: Sendable {
    package static let frameSamples = 320 // 20 ms at 16 kHz

    package var sampleRate = 16_000
    package var floorDBFS = -70.0
    package var marginDB = 10.0
    package var minSpeechSec = 0.25
    package var minSilenceSec = 0.5
    package var paddingSec = 0.3

    package init() {}

    package func speechRanges(in samples: [Float]) -> [Range<Int>] {
        let levels = frameLevels(samples)
        guard !levels.isEmpty else { return [] }
        let quiet = levels.sorted()[levels.count / 10]
        let threshold = quiet.isFinite ? max(floorDBFS, quiet + marginDB) : floorDBFS
        let frame = Self.frameSamples

        // Runs of loud frames, as sample ranges.
        var runs: [Range<Int>] = []
        for (index, level) in levels.enumerated() where level > threshold {
            let range = (index * frame)..<min((index + 1) * frame, samples.count)
            if let last = runs.last, last.upperBound == range.lowerBound {
                runs[runs.count - 1] = last.lowerBound..<range.upperBound
            } else {
                runs.append(range)
            }
        }
        // Bridge short gaps, drop short bursts, pad and clamp.
        let minSilence = sampleCount(minSilenceSec)
        var merged: [Range<Int>] = []
        for run in runs {
            if let last = merged.last, run.lowerBound - last.upperBound < minSilence {
                merged[merged.count - 1] = last.lowerBound..<run.upperBound
            } else {
                merged.append(run)
            }
        }
        let padding = sampleCount(paddingSec)
        return SpeechGate.merged(merged
            .filter { $0.count >= sampleCount(minSpeechSec) }
            .map { max(0, $0.lowerBound - padding)..<min(samples.count, $0.upperBound + padding) })
    }

    /// RMS level of each 20 ms frame in dBFS (−∞ for digital silence).
    private func frameLevels(_ samples: [Float]) -> [Double] {
        stride(from: 0, to: samples.count, by: Self.frameSamples).map { start in
            let end = min(start + Self.frameSamples, samples.count)
            var sum = 0.0
            for index in start..<end { sum += Double(samples[index]) * Double(samples[index]) }
            return 10 * log10(sum / Double(end - start))
        }
    }

    private func sampleCount(_ seconds: Double) -> Int {
        Int((seconds * Double(sampleRate)).rounded())
    }
}
