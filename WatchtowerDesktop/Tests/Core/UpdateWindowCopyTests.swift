import XCTest
@testable import WatchtowerCore

/// Pins every string of the Software Update window and of Settings → System
/// → Update, including the required-update copy (#2096).
final class UpdateWindowCopyTests: XCTestCase {
    private typealias Copy = UpdateWindowCopy

    func testTitleFollowsWhatTheWindowShows() {
        XCTAssertEqual(Copy.title(offered: "0.31.0", installed: nil, required: false),
                       "Watchtower 0.31.0 is available")
        XCTAssertEqual(Copy.title(offered: "0.31.0", installed: nil, required: true),
                       "Update required: Watchtower 0.31.0")
        XCTAssertEqual(Copy.title(offered: nil, installed: "0.30.0", required: false),
                       "What's New in Watchtower 0.30.0")
        XCTAssertEqual(Copy.title(offered: nil, installed: nil, required: false), "Watchtower is up to date")
    }

    func testSubtitleNamesTheRunningVersion() {
        XCTAssertEqual(Copy.subtitle(running: "0.29.2", showingInstalled: false), "You have 0.29.2.")
        XCTAssertEqual(Copy.subtitle(running: "0.30.0", showingInstalled: true), "Watchtower was updated.")
    }

    /// One sentence: that the update is required and why.
    func testRequiredReasonIsOneSentenceNamingTheMinimum() {
        let reason = Copy.requiredReason(minimum: "0.30.0")
        XCTAssertEqual(
            reason,
            "Versions older than 0.30.0 stop working with the services Watchtower connects to, "
                + "so this update cannot be postponed."
        )
        XCTAssertEqual(reason.filter { $0 == "." }.count, 3, "two in the version, one at the end")
    }

    func testSettingsLabelSaysRequired() {
        XCTAssertEqual(Copy.settingsOffer(version: "0.31.0", required: false), "Version 0.31.0 available")
        XCTAssertEqual(Copy.settingsOffer(version: "0.31.0", required: true), "Version 0.31.0 required")
    }

    func testFixedLabels() {
        XCTAssertEqual(Copy.noNotes, "No release notes for this version.")
        XCTAssertEqual(Copy.later, "Later")
        XCTAssertEqual(Copy.updateNow, "Update Now")
        XCTAssertEqual(Copy.downloading, "Downloading...")
        XCTAssertEqual(Copy.readyToInstall, "Ready to install")
        XCTAssertEqual(Copy.installAndRestart, "Install & Restart")
        XCTAssertEqual(Copy.installing, "Installing update...")
        XCTAssertEqual(Copy.restarting, "Restarting Watchtower...")
        XCTAssertEqual(Copy.restartRequired, "Update installed — restart Watchtower to finish")
        XCTAssertEqual(Copy.restartNow, "Restart Now")
        XCTAssertEqual(Copy.errorTitle, "Update error")
        XCTAssertEqual(Copy.close, "Close")
        XCTAssertEqual(Copy.retry, "Retry")
        XCTAssertEqual(Copy.checkAgain, "Check Again")
        XCTAssertEqual(Copy.quit, "Quit Watchtower")
    }
}
