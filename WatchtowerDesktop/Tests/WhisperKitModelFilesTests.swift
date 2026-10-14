import Foundation
import XCTest
@testable import WatchtowerDesktop

/// `WhisperKitProvider.modelFilesMissing` on a scratch Hub repo folder: the
/// folder names WhisperKit downloads into, the two weight files that mark a
/// complete variant, and the absent-vs-unreadable split (#744).
final class WhisperKitModelFilesTests: XCTestCase {
    private var repo: URL!

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory
            .appending(path: "WhisperKitModelFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.path)
        try? FileManager.default.removeItem(at: repo)
    }

    private func makeVariant(_ folder: String, weights: [String] = ["AudioEncoder", "TextDecoder"]) throws {
        for part in weights {
            let dir = repo.appending(path: "\(folder)/\(part).mlmodelc/weights")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([0]).write(to: dir.appending(path: "weight.bin"))
        }
    }

    private func missing(_ model: String) -> Bool {
        WhisperKitProvider.modelFilesMissing(model: model, in: repo)
    }

    func testCompleteVariantsArePresent() throws {
        try makeVariant("openai_whisper-large-v3-v20240930")
        try makeVariant("distil-whisper_distil-large-v3")
        try makeVariant("openai_whisper-small")
        XCTAssertFalse(missing("large-v3-v20240930"))
        XCTAssertFalse(missing("distil-large-v3"))
        XCTAssertFalse(missing("small"))
    }

    /// The distil folder ends in "-large-v3" but is not the large-v3 model.
    func testTheDistilFolderDoesNotStandInForLargeV3() throws {
        try makeVariant("distil-whisper_distil-large-v3")
        try makeVariant("openai_whisper-large-v3-v20240930")
        XCTAssertTrue(missing("large-v3"))
    }

    func testAVariantWithAWeightFileMissingIsMissing() throws {
        try makeVariant("openai_whisper-medium", weights: ["AudioEncoder"])
        XCTAssertTrue(missing("medium"))
    }

    func testAnEmptyOrAbsentRepoIsMissing() throws {
        XCTAssertTrue(missing("small"))
        try FileManager.default.removeItem(at: repo)
        XCTAssertTrue(missing("small"))
    }

    /// An unreadable repo (a revoked Documents grant) is "cannot tell", not
    /// "missing" — a recorded model is not downloaded again on that alone.
    func testAnUnreadableRepoIsNotMissing() throws {
        try makeVariant("openai_whisper-small")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: repo.path)
        XCTAssertFalse(missing("small"))
    }
}
