import Foundation

/// Scores one transcript against a known audio timeline for the
/// hallucination bench (`TranscriptionHallucinationBenchTests`, board #554):
/// how many words an engine wrote over stretches that hold no speech, and how
/// far its speech text is from the reference. Pure, so the counting rules are
/// unit-tested without any engine.
package enum TranscriptBenchMetrics {
    /// One timestamped piece of a transcript (absolute seconds).
    package struct Segment: Equatable, Sendable {
        package let text: String
        package let startSec: Double
        package let endSec: Double

        package init(text: String, startSec: Double, endSec: Double) {
            self.text = text
            self.startSec = startSec
            self.endSec = endSec
        }
    }

    /// Timestamp drift allowed at a filler edge: a segment whose midpoint
    /// lies within this distance of a filler boundary is not counted, so a
    /// real word whose timestamp slid past the end of speech is not scored
    /// as a hallucination.
    package static let fillerToleranceSec = 0.5

    /// Lowercased words with punctuation dropped; «ё» folds to «е» since
    /// references and engines disagree on it freely.
    package static func words(_ text: String) -> [String] {
        let folded = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        return String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .map(String.init)
    }

    /// Word error rate: word-level edit distance over the reference length.
    /// An empty reference scores 0 for an empty hypothesis and 1 otherwise.
    package static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = words(reference)
        let hyp = words(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        return Double(alignment(ref, hyp).distance) / Double(ref.count)
    }

    /// Hypothesis words the alignment against the reference can only explain
    /// as insertions — the words-over-filler count for an engine that returns
    /// text without timestamps.
    package static func insertedWords(reference: String, hypothesis: String) -> Int {
        alignment(words(reference), words(hypothesis)).insertions
    }

    /// Reference words the alignment can only explain as deletions — real
    /// speech the transcript lost.
    package static func deletedWords(reference: String, hypothesis: String) -> Int {
        alignment(words(reference), words(hypothesis)).deletions
    }

    /// Words of the segments whose midpoint lies in a filler range shrunk by
    /// `toleranceSec` at both ends. A segment's words all count together —
    /// engines time segments, not words.
    package static func wordsInFiller(
        segments: [Segment],
        fillers: [ClosedRange<Double>],
        toleranceSec: Double = fillerToleranceSec
    ) -> Int {
        segments.reduce(0) { total, segment in
            let mid = (segment.startSec + segment.endSec) / 2
            let inFiller = fillers.contains {
                mid >= $0.lowerBound + toleranceSec && mid <= $0.upperBound - toleranceSec
            }
            return inFiller ? total + words(segment.text).count : total
        }
    }

    /// Levenshtein over words, tracking how many edits on one cheapest path
    /// are insertions and deletions (ties prefer substitution, then deletion).
    private static func alignment(_ ref: [String], _ hyp: [String]) -> (distance: Int, insertions: Int, deletions: Int) {
        typealias Cell = (distance: Int, insertions: Int, deletions: Int)
        // Row over hypothesis positions: the cell for ref[0..<i] vs hyp[0..<j].
        var previous: [Cell] = (0...hyp.count).map { ($0, $0, 0) }
        for (i, refWord) in ref.enumerated() {
            var current: [Cell] = [(i + 1, 0, i + 1)]
            for (j, hypWord) in hyp.enumerated() {
                let diagonal = previous[j]
                var best: Cell = (diagonal.distance + (refWord == hypWord ? 0 : 1), diagonal.insertions, diagonal.deletions)
                let up = previous[j + 1]
                if up.distance + 1 < best.distance {
                    best = (up.distance + 1, up.insertions, up.deletions + 1)
                }
                let left = current[j]
                if left.distance + 1 < best.distance {
                    best = (left.distance + 1, left.insertions + 1, left.deletions)
                }
                current.append(best)
            }
            previous = current
        }
        return previous[hyp.count]
    }
}
