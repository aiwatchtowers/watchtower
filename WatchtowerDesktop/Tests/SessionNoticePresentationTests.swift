import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// U7 (plan Task G7, S10): codex reports no idle prompt, so Settings →
/// Notifications says so under Workbench notifications. The line comes from
/// the capability rows, never from a kind check.
@MainActor
final class SessionNoticePresentationTests: XCTestCase {
    func testIdleNoticeDisclosedAsUnavailableForCodex() throws {
        XCTAssertEqual(AgentSessionCaps.idleNoticeCaption(), "Idle notices are not available for Codex sessions.")

        let caption = NotificationSettings.workbenchCaption(idleCaption: AgentSessionCaps.idleNoticeCaption())
        XCTAssertEqual(
            caption,
            "Agent questions and asks, finished targets, proposals.\nIdle notices are not available for Codex sessions."
        )
        XCTAssertNoThrow(try NotificationSettings().inspect().find(text: "Workbench notifications"))
        XCTAssertNoThrow(try NotificationSettings().inspect().find(text: caption))

        // Every kind with an idle signal: the line is gone.
        let allIdle = AgentSessionCaps.idleNoticeCaption { _ in
            AgentSessionCaps(
                midturnInput: true, phoneInput: true, permissionWait: true, idleSignal: true, elicitation: true
            )
        }
        XCTAssertNil(allIdle)
        XCTAssertEqual(
            NotificationSettings.workbenchCaption(idleCaption: allIdle),
            "Agent questions and asks, finished targets, proposals."
        )
    }
}
