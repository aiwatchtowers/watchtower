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
    }

    // A meeting can talk ABOUT subtitles; only the credit forms go.
    func testKeepsSpeechThatMerelyMentionsSubtitles() {
        let text = "Нужно добавить субтитры к видео. Продолжение следует в понедельник."
        XCTAssertEqual(clean(text), text)
        XCTAssertEqual(clean("Thanks for watching the demo with us, any questions?"),
                       "Thanks for watching the demo with us, any questions?")
    }

    // A decoding loop repeats one sentence over and over; three or more in a
    // row collapse to one. Two in a row is ordinary speech ("Да. Да.").
    func testCollapsesARepeatedSentenceLoop() {
        XCTAssertEqual(clean("Спасибо. Спасибо. Спасибо. Спасибо."), "Спасибо.")
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
