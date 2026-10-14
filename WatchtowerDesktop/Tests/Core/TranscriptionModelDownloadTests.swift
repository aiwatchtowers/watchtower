import Foundation
import XCTest
@testable import WatchtowerCore

/// When the meeting model downloads ahead of use (#744), and what a download
/// says while it runs or after it fails.
final class TranscriptionModelAutoDownloadTests: XCTestCase {
    private func decide(
        goals: Set<OnboardingGoal> = [.meetings],
        onboardingComplete: Bool = true,
        modelOnDisk: Bool = false,
        firstSyncFinished: Bool = true,
        waited: TimeInterval = 0
    ) -> TranscriptionModelAutoDownload.Decision {
        TranscriptionModelAutoDownload.decide(goals: goals, onboardingComplete: onboardingComplete,
                                              modelOnDisk: modelOnDisk, firstSyncFinished: firstSyncFinished,
                                              waited: waited)
    }

    func testMeetingsGoalDownloadsAheadOfUse() {
        XCTAssertEqual(decide(), .download)
        XCTAssertEqual(decide(goals: [.workCommunication, .meetings]), .download)
    }

    /// The default goals (all but Meetings) and zero goals wait for the
    /// first recording or dictation.
    func testWithoutTheMeetingsGoalNothingDownloads() {
        XCTAssertEqual(decide(goals: [.workCommunication, .tasksAndJira, .development]), .skip)
        XCTAssertEqual(decide(goals: []), .skip)
    }

    func testNothingDownloadsDuringOnboarding() {
        XCTAssertEqual(decide(onboardingComplete: false), .skip)
    }

    func testAModelOnDiskIsNotDownloadedAgain() {
        XCTAssertEqual(decide(modelOnDisk: true), .skip)
        XCTAssertEqual(decide(modelOnDisk: true, firstSyncFinished: false), .skip)
    }

    /// The first sync goes first, but a sync that never finishes does not
    /// hold the download back for good.
    func testWaitsForTheFirstSyncUpToTheCap() {
        XCTAssertEqual(decide(firstSyncFinished: false), .waitForFirstSync)
        XCTAssertEqual(decide(firstSyncFinished: false,
                              waited: TranscriptionModelAutoDownload.firstSyncMaxWait - 1), .waitForFirstSync)
        XCTAssertEqual(decide(firstSyncFinished: false,
                              waited: TranscriptionModelAutoDownload.firstSyncMaxWait), .download)
    }
}

final class ModelDownloadTextTests: XCTestCase {
    private enum WrappingError: Error {
        case networkError(URLError)
    }

    private struct OfflineError: Error, CustomStringConvertible {
        var description: String { "offlineModeError(\"Repository not available locally\")" }
    }

    func testProgressLineCarriesModelPercentSizeAndTimeLeft() {
        XCTAssertEqual(
            ModelDownloadText.progressLine(model: "Large v3 Turbo", sizeBytes: 1_600_000_000, fraction: 0.426,
                                           secondsLeft: 185),
            "Downloading Large v3 Turbo — 42% of about \(ModelDownloadText.size(1_600_000_000)), about 3 min left")
    }

    func testProgressLineWithoutSizeOrEstimateAndOutOfRangeFractions() {
        XCTAssertEqual(ModelDownloadText.progressLine(model: "M", sizeBytes: nil, fraction: 0, secondsLeft: nil),
                       "Downloading M — 0%")
        XCTAssertEqual(ModelDownloadText.progressLine(model: "M", sizeBytes: nil, fraction: 1.7, secondsLeft: nil),
                       "Downloading M — 100%")
        XCTAssertEqual(ModelDownloadText.progressLine(model: "M", sizeBytes: nil, fraction: -1, secondsLeft: nil),
                       "Downloading M — 0%")
    }

    func testTimeLeft() {
        XCTAssertEqual(ModelDownloadText.timeLeft(0), "less than a minute left")
        XCTAssertEqual(ModelDownloadText.timeLeft(59), "less than a minute left")
        XCTAssertEqual(ModelDownloadText.timeLeft(60), "about 1 min left")
        XCTAssertEqual(ModelDownloadText.timeLeft(89 * 60), "about 89 min left")
        XCTAssertEqual(ModelDownloadText.timeLeft(3 * 3600), "about 3 h left")
    }

    func testSecondsLeftFromTheRateSinceTheFirstReport() throws {
        let start = Date()
        // 10% in 20 s → the remaining 50% takes 100 s.
        let left = try XCTUnwrap(ModelDownloadText.secondsLeft(startFraction: 0.4, startedAt: start, fraction: 0.5,
                                                               now: start.addingTimeInterval(20)))
        XCTAssertEqual(left, 100, accuracy: 0.001)
    }

    func testNoEstimateWithoutEnoughToGoOn() {
        let start = Date()
        XCTAssertNil(ModelDownloadText.secondsLeft(startFraction: 0, startedAt: start, fraction: 0.5,
                                                   now: start.addingTimeInterval(1)), "too early")
        XCTAssertNil(ModelDownloadText.secondsLeft(startFraction: 0.3, startedAt: start, fraction: 0.3,
                                                   now: start.addingTimeInterval(60)), "no progress")
        XCTAssertNil(ModelDownloadText.secondsLeft(startFraction: 0, startedAt: start, fraction: 1,
                                                   now: start.addingTimeInterval(60)), "done")
        XCTAssertNil(ModelDownloadText.secondsLeft(startFraction: 0.5, startedAt: start, fraction: 0.4,
                                                   now: start.addingTimeInterval(60)), "progress went back")
    }

    func testNetworkFailuresReadAsADroppedConnection() {
        let cases: [Error] = [
            URLError(.notConnectedToInternet),
            URLError(.timedOut),
            WrappingError.networkError(URLError(.networkConnectionLost)),
            NSError(domain: "Hub", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.cannotFindHost)]),
            OfflineError()
        ]
        for error in cases {
            XCTAssertEqual(ModelDownloadText.failureMessage(for: error, sizeBytes: nil),
                           "The connection dropped. Retry continues the download from where it stopped.",
                           "\(error)")
        }
    }

    func testAFullDiskNamesTheSpaceNeeded() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertEqual(ModelDownloadText.failureMessage(for: error, sizeBytes: 1_600_000_000),
                       "Not enough disk space for the model (about \(ModelDownloadText.size(1_600_000_000))). Free some space, then retry.")
        XCTAssertEqual(ModelDownloadText.failureMessage(for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
                                                        sizeBytes: nil),
                       "Not enough disk space for the model. Free some space, then retry.")
    }

    func testOtherFailuresKeepTheirOwnText() {
        let error = NSError(domain: "Hub", code: 404, userInfo: [NSLocalizedDescriptionKey: "Not found"])
        XCTAssertEqual(ModelDownloadText.failureMessage(for: error, sizeBytes: nil),
                       "Couldn't download the model: Not found")
        XCTAssertFalse(ModelDownloadText.isNetworkFailure(URLError(.badServerResponse)))
    }
}
