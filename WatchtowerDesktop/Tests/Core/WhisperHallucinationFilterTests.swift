import XCTest
@testable import WatchtowerCore

final class WhisperHallucinationFilterTests: XCTestCase {
    private func clean(_ text: String) -> String { WhisperHallucinationFilter.clean(text) }

    // The phrases seen on a real recording whose remote audio went silent
    // mid-meeting: Whisper filled the room tone with subtitle credits.
    func testDropsSubtitleCreditsAndContinuationLoops() {
        XCTAssertEqual(clean("Продолжение следует... Продолжение следует... Продолжение следует..."), "")
        XCTAssertEqual(clean("Субтитры сделал DimaTorzok"), "")
        XCTAssertEqual(clean("Спасибо за субтитры Алексею Дубровскому!"), "")
        XCTAssertEqual(clean("Субтитры создавал DimaTorzok. Продолжение следует..."), "")
        XCTAssertEqual(clean("Редактор субтитров А.Семкин Корректор А.Егорова"), "")
    }

    func testDropsKnownCreditsInUkrainianAndEnglish() {
        XCTAssertEqual(clean("Дякую за перегляд!"), "")
        XCTAssertEqual(clean("Thanks for watching!"), "")
        XCTAssertEqual(clean("Thank you for watching."), "")
        XCTAssertEqual(clean("Subtitles by the Amara.org community"), "")
        XCTAssertEqual(clean("Спасибо за просмотр!"), "")
    }

    func testKeepsRealSpeechAroundAHallucination() {
        XCTAssertEqual(clean("Давай созвонимся завтра. Продолжение следует..."), "Давай созвонимся завтра.")
        XCTAssertEqual(clean("Субтитры сделал DimaTorzok Ну что, начнём?"), "Ну что, начнём?")
        XCTAssertEqual(clean("Сейчас запишу Продолжение следует... Да, смотрите"), "Сейчас запишу Да, смотрите")
        // Seen on real recordings: the credit glued into lowercase speech.
        XCTAssertEqual(clean("с конфигами хранится Субтитры сделал DimaTorzok в репо."), "с конфигами хранится в репо.")
    }

    // A meeting can talk ABOUT subtitles; only the credit forms go.
    func testKeepsSpeechThatMerelyMentionsSubtitles() {
        let text = "Нужно добавить субтитры к видео. Продолжение следует в понедельник."
        XCTAssertEqual(clean(text), text)
        XCTAssertEqual(clean("Thanks for watching the demo with us, any questions?"),
                       "Thanks for watching the demo with us, any questions?")
        for speech in [
            "We need subtitles by Friday, okay?",
            "We need subtitles by the end of the week.",
            "Субтитры делал Петя, а озвучку я.",
            "Спасибо за субтитры к видео, Петя, очень помогли.",
            "Редактор субтитров сломался, надо чинить.",
            "Нам нужен редактор субтитров для проекта.",
            "Субтитры делал DeepL, качество так себе.",
            "Субтитры сделал ChatGPT и всё поехало.",
            "Я говорил, что субтитры делал Whisper.",
            "В прошлый раз субтитры сделал ChatGPT.",
            "А субтитры делал DeepL"
        ] {
            XCTAssertEqual(clean(speech), speech)
        }
    }

    // A removal elsewhere in the segment must not touch the text it keeps:
    // decimals, domains and versions survive byte for byte.
    func testRemovalKeepsDecimalsAndDomainsIntact() {
        XCTAssertEqual(clean("Цена 3.5 доллара. Продолжение следует..."), "Цена 3.5 доллара.")
        XCTAssertEqual(clean("Смотри example.com, там всё. Thanks for watching!"), "Смотри example.com, там всё.")
    }

    // Degenerate: a multi-line segment splits into sentences across the
    // line break instead of losing a line.
    func testMultilineSegmentKeepsEveryLine() {
        XCTAssertEqual(clean("Первая строка\nвторая строка. Продолжение следует..."), "Первая строка вторая строка.")
    }

    // A decoding loop repeats one sentence over and over; four or more in a
    // row collapse to one. Up to three is ordinary speech ("Нет. Нет. Нет.").
    func testCollapsesARepeatedSentenceLoop() {
        XCTAssertEqual(clean("Спасибо. Спасибо. Спасибо. Спасибо."), "Спасибо.")
        XCTAssertEqual(clean("Нет. Нет. Нет. Так не пойдёт."), "Нет. Нет. Нет. Так не пойдёт.")
        XCTAssertEqual(clean("Да. Да. Хорошо."), "Да. Да. Хорошо.")
    }

    // Degenerate input: empty, punctuation-only and whitespace stay
    // harmless; ordinary text passes through byte for byte.
    func testDegenerateInput() {
        XCTAssertEqual(clean(""), "")
        XCTAssertEqual(clean("   "), "")
        XCTAssertEqual(clean("..."), "", "punctuation alone is not speech")
        XCTAssertEqual(clean("Hello world"), "Hello world")
    }
}
