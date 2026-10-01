import Foundation

/// Removes Whisper's known hallucinations from one decoded segment's text.
/// Fed near-silence (room tone, a system-audio tap gone quiet), Whisper
/// writes the YouTube-subtitle boilerplate it was trained on — «Субтитры
/// сделал DimaTorzok», «Продолжение следует...», "Thanks for watching!" —
/// often in a loop that fills a whole window. Mechanical and conservative:
/// only the credit forms and whole-sentence sign-offs go, never a sentence
/// that merely mentions subtitles; three or more identical sentences in a
/// row collapse to one. Text with nothing to remove is returned unchanged.
package enum WhisperHallucinationFilter {
    /// Credit lines, removed wherever they appear (they often run straight
    /// into real speech with no punctuation between).
    private static let creditPatterns: [NSRegularExpression] = [
        #"(?:субтитры|субтитри)\s+(?:сделал|сделала|создавал|создавала|делал|делала|подготовил|подготовила|подогнал"#
            + #"|зробив|створив|підготував)\s+\S+[.!?…]*"#,
        #"спасибо за субтитры(?:\s+[\p{L}.]+){0,2}[.!?…]*"#,
        #"редактор субтитров\s+\S+(?:\s+корректор\s+\S+)?[.!?…]*"#,
        #"subtitles by(?:\s+the)?\s+\S+(?:\s+community)?[.!?…]*"#,
        // The ellipsis form is the hallucination; spoken "продолжение
        // следует в понедельник." is not touched.
        #"(?:продолжение следует|продовження буде|to be continued)(?:\.{2,}|…)"#
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) } // swiftlint:disable:this force_try

    /// Sign-offs dropped only when they are the WHOLE sentence (normalized).
    private static let wholeSentences: Set<String> = [
        "продолжение следует", "спасибо за просмотр", "дякую за перегляд", "продовження буде",
        "thanks for watching", "thank you for watching", "please subscribe"
    ]

    private static let sentencePattern = try! NSRegularExpression(pattern: #"[^.!?…]*[.!?…]+|[^.!?…]+$"#) // swiftlint:disable:this force_try

    /// Repeats of one sentence at or above this run length are a decoding
    /// loop, not speech.
    private static let loopRun = 3

    package static func clean(_ text: String) -> String {
        var stripped = text
        for pattern in creditPatterns {
            stripped = pattern.stringByReplacingMatches(
                in: stripped, range: NSRange(stripped.startIndex..., in: stripped), withTemplate: "")
        }

        let sentences = sentencePattern
            .matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped))
            .compactMap { Range($0.range, in: stripped).map { stripped[$0].trimmingCharacters(in: .whitespacesAndNewlines) } }
            .filter { !$0.isEmpty }
        var kept: [String] = []
        var index = 0
        while index < sentences.count {
            let key = normalized(sentences[index])
            var end = index + 1
            while end < sentences.count, normalized(sentences[end]) == key { end += 1 }
            let run = sentences[index..<end]
            if !wholeSentences.contains(key) {
                kept += run.count >= loopRun && !key.isEmpty ? [sentences[index]] : Array(run)
            }
            index = end
        }

        // Punctuation alone ("...") is not speech.
        if kept.allSatisfy({ normalized($0).isEmpty }) { return "" }
        if stripped == text, kept.count == sentences.count {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A removal can leave a double space where a credit sat mid-sentence.
        return kept.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Lowercased letters and digits, single-spaced — punctuation and case
    /// never make two copies of a hallucination differ.
    private static func normalized(_ sentence: String) -> String {
        String(sentence.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }
}
