import XCTest
@testable import WatchtowerCore

/// `WorkchatOutgoing.matches`: a line the Workchat sent turns into the feed's
/// owner entry with the same text, whitespace collapsed, dated at or after
/// the send (#711).
final class WorkchatOutgoingTests: XCTestCase {
    private let sentAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(_ text: String) -> WorkchatOutgoing {
        WorkchatOutgoing(id: UUID(), text: text, sentAt: sentAt, state: .sent)
    }

    private func owner(_ text: String, after seconds: TimeInterval = 2, kind: String = "owner") -> SessionFeedEntry {
        SessionFeedEntry(id: UUID().uuidString, kind: kind, at: sentAt.addingTimeInterval(seconds), text: text)
    }

    func testMatchesCollapsedWhitespace() {
        let sent = line("Fix the  test\nand  run it ")

        XCTAssertTrue(WorkchatOutgoing.matches(owner("Fix the test and run it"), line: sent))
        XCTAssertTrue(WorkchatOutgoing.matches(owner("Fix the test and run it", after: 0), line: sent), "at the send itself")
        XCTAssertFalse(WorkchatOutgoing.matches(owner("Fix the test"), line: sent))
        XCTAssertFalse(WorkchatOutgoing.matches(owner("Fix the test and run it", kind: "agent"), line: sent),
                       "only an owner entry")
    }

    /// The parser renders `<command-name>/compact</command-name>
    /// <command-args>keep the plan</command-args>` as "/compact keep the plan".
    func testMatchesSlashCommand() {
        XCTAssertTrue(WorkchatOutgoing.matches(owner("/compact keep the plan"), line: line("/compact   keep the plan")))
        XCTAssertTrue(WorkchatOutgoing.matches(owner("/clear"), line: line(" /clear ")))
    }

    func testIgnoresEntryBeforeSend() {
        let sent = line("Ship it")

        XCTAssertFalse(WorkchatOutgoing.matches(owner("Ship it", after: -1), line: sent), "an older identical line")
        var undated = owner("Ship it")
        undated.at = nil
        XCTAssertFalse(WorkchatOutgoing.matches(undated, line: sent), "no time, no match")
    }
}
