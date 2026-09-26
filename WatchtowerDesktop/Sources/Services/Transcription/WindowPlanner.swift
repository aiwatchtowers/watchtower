import Foundation

/// Single source of truth for window boundaries, shared by WindowedTranscriber
/// (batch) and StreamingTranscriber (live) so both cut identical windows on
/// identical samples — the live↔batch invariant pinned by
/// StreamingTranscriberTests.testMatchesBatchOnSameSamples.
///
/// A window's nominal end is `start + windowSamples`. With snapping enabled
/// (toleranceSamples > 0) the actual cut is the centre of the quietest 20 ms
/// frame (10 ms hop, earliest wins ties) within ±tolerance of the nominal end,
/// so boundaries land in speech pauses instead of mid-word. The last window
/// (nominal end reaching the total count) is never snapped: it is truncated to
/// the real end — the legacy rule verbatim.
struct WindowPlanner {
    let windowSamples: Int
    let overlapSamples: Int
    /// Configured snap tolerance capped at a quarter window, so degenerate
    /// configs (tiny test windows) keep making progress.
    let toleranceSamples: Int

    static let frameSamples = 320 // 20 ms @ 16 kHz
    static let hopSamples = 160   // 10 ms @ 16 kHz

    init(config: TranscriptionConfig) {
        let rate = Double(TranscriptionConfig.sampleRate)
        let window = max(1, Int(config.windowSec * rate))
        windowSamples = window
        overlapSamples = Int(config.overlapSec * rate)
        toleranceSamples = min(max(0, Int(config.boundarySnapSec * rate)), window / 4)
    }

    /// A window reaching the end of the samples is the last one: a further
    /// start would lie inside this window's overlap and only duplicate audio.
    func isLastWindow(start: Int, total: Int) -> Bool {
        start + windowSamples >= total
    }

    /// Samples that must exist before the cut for the window at `start` is
    /// decidable without seeing the stream end: the full snap zone (or, with
    /// snapping off, one sample past the nominal end to prove non-last).
    func decidableCount(start: Int) -> Int {
        start + windowSamples + max(toleranceSamples, 1)
    }

    /// The window starting at `start` given `total` samples so far; `isFinal`
    /// means `total` is the stream's true end. Returns nil while the window is
    /// not yet decidable (or `start` is past the end). `sample` is indexed by
    /// absolute sample position.
    func nextRange(start: Int, total: Int, isFinal: Bool, sample: (Int) -> Float) -> Range<Int>? {
        guard start < total else { return nil }
        if isLastWindow(start: start, total: total) {
            return isFinal ? start..<total : nil
        }
        if !isFinal && total < decidableCount(start: start) { return nil }
        return start..<cut(nominalEnd: start + windowSamples, total: total, sample: sample)
    }

    /// Start of the window following `range` (meaningless for a last window).
    func nextStart(after range: Range<Int>) -> Int {
        max(range.lowerBound + 1, range.upperBound - overlapSamples)
    }

    /// All windows of a fully-known recording (the batch path).
    func planWindows(total: Int, sample: (Int) -> Float) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while let range = nextRange(start: start, total: total, isFinal: true, sample: sample) {
            ranges.append(range)
            if isLastWindow(start: range.lowerBound, total: total) { break }
            start = nextStart(after: range)
        }
        return ranges
    }

    private func cut(nominalEnd: Int, total: Int, sample: (Int) -> Float) -> Int {
        guard toleranceSamples > 0 else { return min(nominalEnd, total) }
        let lo = nominalEnd - toleranceSamples
        let hi = min(nominalEnd + toleranceSamples, total)
        var bestStart = -1
        var bestEnergy = Float.greatestFiniteMagnitude
        var frame = lo
        while frame + Self.frameSamples <= hi {
            var energy: Float = 0
            for i in frame..<(frame + Self.frameSamples) {
                let v = sample(i)
                energy += v * v
            }
            if energy < bestEnergy { // strict <: the earliest quietest frame wins
                bestEnergy = energy
                bestStart = frame
            }
            frame += Self.hopSamples
        }
        guard bestStart >= 0 else { return min(nominalEnd, total) } // zone < one frame
        return bestStart + Self.frameSamples / 2
    }
}
