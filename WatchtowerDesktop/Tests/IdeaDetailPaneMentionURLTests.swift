import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore

/// `IdeaDetailPane.mentionURL` deeplink-building tests — split out of
/// `IdeaQueriesTests` (which moved to WatchtowerCoreTests) because
/// `IdeaDetailPane` is a SwiftUI view and can't live in the Core-only test target.
final class IdeaDetailPaneMentionURLTests: XCTestCase {
    // MARK: - Slack deeplink

    /// `channels.id`/`messages.channel_id` carry the Slack multi-account
    /// namespace ("<accountID>:") since migration 00048, but slack.com/archives
    /// wants the bare id — a namespaced one 404s.
    func testMentionURLStripsSlackAccountNamespace() throws {
        let url = slackMentionURL(ref: "3:C08ABCDEF|1723456789.001200")

        XCTAssertEqual(url, "https://slack.com/archives/C08ABCDEF/p1723456789001200")
    }

    /// A pre-migration bare channel id still has to work, and a ref whose
    /// prefix is not an account number must not be truncated.
    func testMentionURLLeavesNonNamespacedChannelIDsAlone() throws {
        XCTAssertEqual(slackMentionURL(ref: "C08ABCDEF|1723456789.001200"),
                       "https://slack.com/archives/C08ABCDEF/p1723456789001200")
        XCTAssertEqual(slackMentionURL(ref: "weird:C08ABCDEF|1723456789.001200"),
                       "https://slack.com/archives/weird:C08ABCDEF/p1723456789001200")
    }

    /// Builds a slack mention through a GRDB `Row` — `IdeaMention` is a
    /// database record with only `init(row:)`.
    private func slackMentionURL(ref: String) -> String? {
        let mention = IdeaMention(row: [
            "id": 1, "idea_id": 1, "source": "slack", "ref": ref,
            "quote": "", "author": "", "said_at": "", "created_at": ""
        ])
        return IdeaDetailPane.mentionURL(mention, jiraSiteURL: nil)?.absoluteString
    }
}
