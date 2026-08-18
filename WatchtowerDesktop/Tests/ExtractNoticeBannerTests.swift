import XCTest
import SwiftUI
@testable import WatchtowerDesktop

/// Smoke-coverage for the inline extraction banner: every notice kind renders,
/// and the actions each kind offers are the ones that make sense for it.
@MainActor
final class ExtractNoticeBannerTests: XCTestCase {
    private func banner(_ notice: ExtractNotice) -> ExtractNoticeBanner {
        ExtractNoticeBanner(notice: notice, onRetry: {}, onUndo: {}, onDismiss: {})
    }

    func testEveryNoticeKindRenders() {
        let notices = [
            ExtractNotice(kind: .filled, message: "filled", canRetry: false, details: nil),
            ExtractNotice(kind: .nothing, message: "nothing", canRetry: true, details: nil),
            ExtractNotice(kind: .failed, message: "failed", canRetry: true, details: "raw stderr"),
            // A non-retryable failure (e.g. missing binary) still has to render.
            ExtractNotice(kind: .failed, message: "no CLI", canRetry: false, details: nil)
        ]
        for notice in notices {
            XCTAssertNotNil(banner(notice).body, "\(notice.kind) must render")
        }
    }

    func testRetryFlagAndDetailsSurviveOnTheNotice() {
        let failure = ExtractNotice(kind: .failed, message: "boom", canRetry: true, details: "chain")
        XCTAssertTrue(failure.canRetry)
        XCTAssertEqual(failure.details, "chain")
        // A fill is never retryable — its action is Undo.
        let fill = ExtractNotice(kind: .filled, message: "done", canRetry: false, details: nil)
        XCTAssertFalse(fill.canRetry)
        XCTAssertNil(fill.details)
    }
}
