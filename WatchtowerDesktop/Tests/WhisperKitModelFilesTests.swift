import Foundation
import XCTest
@testable import WatchtowerDesktop

/// `WhisperKitProvider.modelFilesMissing` on a scratch Hub repo folder: the
/// folder names WhisperKit downloads into, the weight files that mark a
/// complete variant, and the absent-vs-unreadable split (#744); and
/// `completeModelFolder`, which lets a load skip the Hub when the variant is
/// already on disk.
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

    private func makeVariant(_ folder: String, weights: [String] = WhisperKitProvider.weightParts) throws {
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
        try makeVariant("openai_whisper-small", weights: ["AudioEncoder", "TextDecoder"])
        XCTAssertTrue(missing("small"))
    }

    func testCompleteModelFolderReturnsTheVariantsOwnFolder() throws {
        try makeVariant("distil-whisper_distil-large-v3")
        try makeVariant("openai_whisper-large-v3")
        let folder = try WhisperKitProvider.completeModelFolder(model: "large-v3", in: repo)
        XCTAssertEqual(folder?.lastPathComponent, "openai_whisper-large-v3")
        let distil = try WhisperKitProvider.completeModelFolder(model: "distil-large-v3", in: repo)
        XCTAssertEqual(distil?.lastPathComponent, "distil-whisper_distil-large-v3")
    }

    func testCompleteModelFolderIsNilForAnIncompleteVariant() throws {
        try makeVariant("openai_whisper-medium", weights: ["AudioEncoder", "TextDecoder"])
        XCTAssertNil(try WhisperKitProvider.completeModelFolder(model: "medium", in: repo))
    }

    func testTheWeightPartsAreTheThreeCoreMLModels() {
        XCTAssertEqual(WhisperKitProvider.weightParts, ["AudioEncoder", "MelSpectrogram", "TextDecoder"])
    }

    /// The first matching folder in sorted order is incomplete; the complete
    /// one after it is still found.
    func testCompleteModelFolderSkipsAnIncompleteFirstCandidate() throws {
        try makeVariant("aaa_medium", weights: ["AudioEncoder"])
        try makeVariant("openai_whisper-medium")
        let folder = try WhisperKitProvider.completeModelFolder(model: "medium", in: repo)
        XCTAssertEqual(folder?.lastPathComponent, "openai_whisper-medium")
    }

    func testCompleteModelFolderThrowsForAnAbsentRepo() throws {
        try FileManager.default.removeItem(at: repo)
        XCTAssertThrowsError(try WhisperKitProvider.completeModelFolder(model: "small", in: repo))
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

/// `WhisperKitEngine.openPreferringLocal`: the load path that skips the Hub
/// for a model on disk and repairs it through one download when it does not
/// open.
final class WhisperKitOpenPreferringLocalTests: XCTestCase {
    private let local = URL(filePath: "/models/local")
    private let downloaded = URL(filePath: "/models/downloaded")
    private struct OpenFailed: Error {}
    private struct DownloadFailed: Error {}

    func testAModelOnDiskOpensWithoutTheHub() async throws {
        var downloads = 0
        let opened = try await WhisperKitEngine.openPreferringLocal(
            modelName: "small", localFolder: local,
            download: { downloads += 1; return self.downloaded },
            open: { $0 }
        )
        XCTAssertEqual(opened, local)
        XCTAssertEqual(downloads, 0)
    }

    func testNoModelOnDiskDownloadsThenOpens() async throws {
        var downloads = 0
        let opened = try await WhisperKitEngine.openPreferringLocal(
            modelName: "small", localFolder: nil,
            download: { downloads += 1; return self.downloaded },
            open: { $0 }
        )
        XCTAssertEqual(opened, downloaded)
        XCTAssertEqual(downloads, 1)
    }

    /// A partly downloaded folder that does not open is repaired by one
    /// download and opened again.
    func testAModelOnDiskThatFailsToOpenIsRepairedByOneDownload() async throws {
        var downloads = 0
        var opens: [URL] = []
        let opened = try await WhisperKitEngine.openPreferringLocal(
            modelName: "small", localFolder: local,
            download: { downloads += 1; return self.downloaded },
            open: { folder in
                opens.append(folder)
                if folder == self.local { throw OpenFailed() }
                return folder
            }
        )
        XCTAssertEqual(opened, downloaded)
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(opens, [local, downloaded])
    }

    func testTheRepairDownloadsFailureComesOut() async {
        do {
            _ = try await WhisperKitEngine.openPreferringLocal(
                modelName: "small", localFolder: local,
                download: { throw DownloadFailed() },
                open: { (_: URL) -> URL in throw OpenFailed() }
            )
            XCTFail("expected the download's error")
        } catch {
            XCTAssertTrue(error is DownloadFailed, "got \(error)")
        }
    }

    func testCancellationIsNotTurnedIntoADownload() async {
        var downloads = 0
        do {
            _ = try await WhisperKitEngine.openPreferringLocal(
                modelName: "small", localFolder: local,
                download: { downloads += 1; return self.downloaded },
                open: { (_: URL) -> URL in throw CancellationError() }
            )
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(downloads, 0)
    }
}
