import Foundation

/// The words a speaker says inside one playback clip. Utterances are merge
/// units (often a minute or more of one speaker), so showing every
/// overlapping utterance whole made all of a card's clips read the same.
/// Utterances carry no word timestamps, so each word is placed at its
/// proportional position within its utterance and kept when that position
/// falls inside the clip — an approximation, marked with "…" wherever the
/// cut lands mid-utterance. Pure.
package enum ClipTranscript {
    package static func text(for clip: ClipSpan, speaker: String, utterances: [TranscriptUtterance]) -> String {
        utterances
            .filter { !$0.deleted && $0.speaker == speaker && $0.startSec < clip.end && $0.endSec > clip.start }
            .compactMap { slice($0, clip) }
            .joined(separator: " ")
    }

    private static func slice(_ utterance: TranscriptUtterance, _ clip: ClipSpan) -> String? {
        let words = utterance.text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let duration = utterance.endSec - utterance.startSec
        guard duration > 0 else { return words.joined(separator: " ") }
        let kept = words.indices.filter { index in
            let at = utterance.startSec + (Double(index) + 0.5) / Double(words.count) * duration
            return at >= clip.start && at <= clip.end
        }
        guard let first = kept.first, let last = kept.last else { return nil }
        let body = words[first...last].joined(separator: " ")
        return (first > 0 ? "…" : "") + body + (last < words.count - 1 ? "…" : "")
    }
}
