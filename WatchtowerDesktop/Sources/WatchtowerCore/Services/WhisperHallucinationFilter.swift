import Foundation

/// Removes Whisper's known hallucinations from one decoded segment's text.
/// Fed near-silence (room tone, a system-audio tap gone quiet), Whisper
/// writes the YouTube-subtitle boilerplate it was trained on — «Субтитры
/// сделал DimaTorzok», «Продолжение следует...», "Thanks for watching!" —
/// often in a loop that fills a whole window. Mechanical and conservative:
/// - credit lines go only in their credit shape: as a whole sentence, or
///   mid-segment when they carry a Latin-script nickname or a known credit
///   tail (a sentence like "we need subtitles by Friday" stays);
/// - the ellipsis sign-off «Продолжение следует...» goes anywhere;
/// - a few sign-offs go when they are the whole sentence — including a
///   spoken one ("Thanks for watching." after a demo), the accepted price;
/// - four or more identical sentences in a row collapse to one.
/// Text with nothing to remove comes back unchanged (trimmed).
package enum WhisperHallucinationFilter {
    /// Removed wherever they appear — they often run straight into real
    /// speech with no punctuation between.
    private static let inlinePatterns: [NSRegularExpression] = [
        // The credit Whisper writes most often, runs into real speech of
        // any case on real recordings — removed wherever it appears.
        #"(?:субтитры|субтитри)\s+\p{L}+\s+dimatorzok\b[.!?…]*"#,
        #"(?-i:С)(?:убтитры|убтитри)\s+(?:сделал|сделала|создавал|создавала|делал|делала|подготовил|подготовила|подогнал"#
            // Only Whisper's capitalised credit form, and only when nothing
            // continues the clause after the nickname (end of text or a
            // capitalised run-on sentence): "Субтитры делал DeepL, качество
            // так себе" and "…что субтитры делал Whisper." are speech.
            + #"|зробив|створив|підготував)\s+\p{Latin}[\p{Latin}\d_.-]*+[.!?…]*+(?=\s*(?:(?-i:\p{Lu})|$))"#,
        #"редактор субтитров\s+\S+\s+корректор\s+\S+[.!?…]*"#,
        #"subtitles by(?:\s+the)?\s+amara\.org(?:\s+community)?[.!?…]*"#,
        // The ellipsis form is the hallucination; spoken "продолжение
        // следует в понедельник." is not touched.
        #"(?:продолжение следует|продовження буде|to be continued)(?:\.{2,}|…)"#
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) } // swiftlint:disable:this force_try

    /// Credit lines dropped only when they are the whole sentence.
    private static let sentencePatterns: [NSRegularExpression] = [
        #"^(?:субтитры|субтитри)\s+(?:сделал|сделала|создавал|создавала|делал|делала|подготовил|подготовила|подогнал"#
            + #"|зробив|створив|підготував)\s+\S+(?:\s+\S+)?[.!?…]*$"#,
        #"^спасибо за субтитры(?:\s+\S+){0,2}[.!?…]*$"#
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) } // swiftlint:disable:this force_try

    /// Sign-offs dropped only when they are the whole sentence (normalized).
    private static let wholeSentences: Set<String> = [
        "продолжение следует", "спасибо за просмотр", "дякую за перегляд", "продовження буде",
        "thanks for watching", "thank you for watching", "please subscribe"
    ]

    /// A sentence ends at terminal punctuation followed by whitespace or the
    /// end — never inside "3.5" or "example.com".
    private static let sentenceBoundary = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"\S.*?(?:[.!?…]+(?=\s|$)|$)"#, options: [.dotMatchesLineSeparators])

    /// Repeats of one sentence at or above this run length are a decoding
    /// loop, not speech ("Да. Да. Да." stays).
    private static let loopRun = 4

    package static func clean(_ text: String) -> String {
        let stripped = inlinePatterns.reduce(text) { current, pattern in
            pattern.stringByReplacingMatches(in: current, range: NSRange(current.startIndex..., in: current), withTemplate: "")
        }
        let sentences = split(stripped)
        let kept = dropSignOffsAndLoops(sentences)

        // Punctuation alone ("...") is not speech.
        if kept.allSatisfy({ normalized($0).isEmpty }) { return "" }
        // Nothing removed: keep the original spacing and line breaks.
        if stripped == text, kept.count == sentences.count {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A removal can leave a double space where a credit sat mid-sentence.
        return kept.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func split(_ text: String) -> [String] {
        sentenceBoundary
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) } }
            .filter { !$0.isEmpty }
    }

    private static func dropSignOffsAndLoops(_ sentences: [String]) -> [String] {
        var kept: [String] = []
        var index = 0
        while index < sentences.count {
            let key = normalized(sentences[index])
            var end = index + 1
            while end < sentences.count, normalized(sentences[end]) == key { end += 1 }
            if !isSignOff(sentences[index], key: key) {
                if end - index >= loopRun, !key.isEmpty {
                    kept.append(sentences[index])
                } else {
                    kept += sentences[index..<end]
                }
            }
            index = end
        }
        return kept
    }

    private static func isSignOff(_ sentence: String, key: String) -> Bool {
        wholeSentences.contains(key) || sentencePatterns.contains {
            $0.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) != nil
        }
    }

    /// Lowercased letters and digits, single-spaced — punctuation and case
    /// never make two copies of a hallucination differ.
    private static func normalized(_ sentence: String) -> String {
        String(sentence.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }
}
