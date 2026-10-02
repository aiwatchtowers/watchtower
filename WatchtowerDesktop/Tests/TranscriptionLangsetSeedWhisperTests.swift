import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The seed AppState writes is filtered by Whisper's real code set, so
/// every code it keeps is one the detector can answer with.
final class TranscriptionLangsetSeedWhisperTests: XCTestCase {
    func testSeedAgainstWhisperCodes() {
        let codes = WhisperKitEngine.languageCodes
        XCTAssertEqual(TranscriptionLangsetSeed.seed(["nb-NO"], supported: codes), "no,en")
        XCTAssertEqual(TranscriptionLangsetSeed.seed(["fil-PH", "jv"], supported: codes), "tl,jw,en")
        XCTAssertEqual(TranscriptionLangsetSeed.seed(["he-IL", "ru-RU", "uk-UA"], supported: codes), "he,ru,uk,en")
        XCTAssertEqual(TranscriptionLangsetSeed.seed(["zh-Hant-TW"], supported: codes), "zh,en")
    }
}
