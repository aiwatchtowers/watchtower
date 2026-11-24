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

    func testMatchesIgnoresImageMarkersAndPaths() {
        let sent = WorkchatOutgoing(
            id: UUID(), text: "look\n/x/1.png", sentAt: sentAt, state: .sent,
            typedText: "look", attachmentPaths: ["/x/1.png"]
        )

        XCTAssertTrue(WorkchatOutgoing.matches(owner("look [Image #1]"), line: sent))
        XCTAssertTrue(WorkchatOutgoing.matches(owner("look [image]"), line: sent))
        XCTAssertTrue(WorkchatOutgoing.matches(owner("look /x/1.png"), line: sent))
        XCTAssertFalse(WorkchatOutgoing.matches(owner("look elsewhere [Image #1]"), line: sent))
    }

    func testMatchesQuotedPathWithSpace() {
        let sent = WorkchatOutgoing(
            id: UUID(), text: "see\n\"/x/a b.png\"", sentAt: sentAt, state: .sent,
            typedText: "see", attachmentPaths: ["/x/a b.png"]
        )

        XCTAssertTrue(WorkchatOutgoing.matches(owner("see \"/x/a b.png\""), line: sent))
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

    /// Fix round 1: a line sent together with the prompt's text matches the one
    /// owner entry that records both, ending in the line; another line does not.
    func testALineSentTogetherMatchesTheEntryEndingInIt() {
        var sent = line("Run the  linter")
        XCTAssertFalse(WorkchatOutgoing.matches(owner("fix the Run the linter"), line: sent))
        sent.sentTogether = true
        XCTAssertTrue(WorkchatOutgoing.matches(owner("fix the Run the linter"), line: sent))
        XCTAssertTrue(WorkchatOutgoing.matches(owner("fix theRun the linter"), line: sent))
        XCTAssertTrue(WorkchatOutgoing.matches(owner("Run the linter"), line: sent), "alone, if the text was gone")
        XCTAssertFalse(WorkchatOutgoing.matches(owner("Run the linter later"), line: sent))
    }

    /// Spec §6.3: a queued line's caption says why it waits; the hold reason
    /// counts only while it is queued.
    func testHoldCaptionsSayWhyTheLineWaits() {
        func caption(_ reason: WorkchatOutgoing.HoldReason, working: Bool = false, holds: Bool = false) -> String? {
            WorkchatOutgoing.caption(state: .queued, working: working, holdsUntilIdle: holds, holdReason: reason)
        }
        XCTAssertEqual(caption(.needsApproval), "Waiting: answer the permission prompt in the terminal")
        XCTAssertEqual(caption(.agentBusy), "Queued · sends in a moment")
        XCTAssertEqual(caption(.agentBusy, working: true), "Queued · sends in a moment", "an agent that takes the line")
        XCTAssertEqual(caption(.agentBusy, working: true, holds: true), "Queued · sends when the agent stops")
        XCTAssertEqual(caption(.promptHasText), "Waiting: the terminal prompt holds text")
        XCTAssertEqual(caption(.promptHasText, working: true), "Waiting: the terminal prompt holds text")
        XCTAssertEqual(WorkchatOutgoing.caption(state: .typed, working: false, holdsUntilIdle: false,
                                                holdReason: .promptHasText),
                       "Typed into the terminal, not sent: press Return there ·", "only a queued line")
        XCTAssertEqual(WorkchatOutgoing.sendTogether, "Send together")
        XCTAssertEqual(WorkchatOutgoing.cancel, "Cancel")
    }

    /// Each state's caption under the line (#2065 moved them out of the view):
    /// nil where the bubble shows the send time.
    func testCaptionStrings() {
        for working in [true, false] {
            for holds in [true, false] {
                let label = "working=\(working) holds=\(holds)"
                func caption(_ state: WorkchatOutgoing.State, busy: Bool = false) -> String? {
                    WorkchatOutgoing.caption(state: state, working: working, holdsUntilIdle: holds, sentWhileBusy: busy)
                }
                XCTAssertEqual(caption(.sending), "Sending…", label)
                XCTAssertEqual(caption(.queued),
                               holds ? "Queued · sends when the agent stops ·" : "Queued · sends in a moment ·", label)
                XCTAssertEqual(caption(.typed), "Typed into the terminal, not sent: press Return there ·", label)
                XCTAssertEqual(caption(.copied),
                               "Copied to the clipboard: the terminal does not accept pasted text ·", label)
                XCTAssertEqual(caption(.notSent), "Not sent: the session ended", label)
                XCTAssertNil(caption(.sent), label)
                XCTAssertEqual(caption(.sent, busy: true),
                               working ? "Queued · the agent reads it at its next step" : nil, label)
            }
        }
    }

    /// #2065 §6: the transcript records the expanded text, so the echo is matched on `text`, not on the tokenized
    /// draft in `typedText`.
    func testEchoMatchesExpandedText() {
        let sent = WorkchatOutgoing(
            id: UUID(), text: "a x y", sentAt: sentAt, state: .sent, typedText: "a [Pasted text #1 +2 lines]"
        )

        XCTAssertTrue(WorkchatOutgoing.matches(owner("a x\ny"), line: sent))
        XCTAssertFalse(WorkchatOutgoing.matches(owner("a [Pasted text #1 +2 lines]"), line: sent))
    }

    /// An image token goes as its saved path, inside the text; Claude Code records it as "[Image #N]".
    func testEchoWithImageTokenMatchesClaudeImageMarker() {
        let sent = WorkchatOutgoing(
            id: UUID(), text: "fix \"/x/p 1.png\" now", sentAt: sentAt, state: .sent,
            typedText: "fix [Image #1] now", attachmentPaths: ["/x/p 1.png"]
        )

        XCTAssertTrue(WorkchatOutgoing.matches(owner("fix [Image #1] now"), line: sent))
        XCTAssertTrue(WorkchatOutgoing.matches(owner("fix \"/x/p 1.png\" now"), line: sent))
        XCTAssertFalse(WorkchatOutgoing.matches(owner("fix [Image #1] later"), line: sent))
    }

    /// A path with a quote or a backslash goes escaped inside its quotes; the echo of it still matches.
    func testEchoWithEscapedPathMatches() {
        let path = #"/x/say "hi".png"#
        let sent = WorkchatOutgoing(
            id: UUID(), text: "see " + WorkchatOutgoing.quoted(path), sentAt: sentAt, state: .sent,
            typedText: "see [Image #1]", attachmentPaths: [path]
        )

        XCTAssertTrue(WorkchatOutgoing.matches(owner("see [Image #1]"), line: sent))
    }
}
