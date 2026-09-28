import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
final class StepsBlockViewTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func step(_ id: String, _ name: String, _ state: StepState, end: TimeInterval? = 2) -> ChatStepDisplay {
        ChatStepDisplay(id: id, name: name, argsJSON: #"{"key":"P-1"}"#, state: state, summary: "sum", sources: [],
                        startedAt: t0, endedAt: end.map { t0.addingTimeInterval($0) })
    }

    func testFinishedBlockShowsHeaderAndLabels() throws {
        let view = StepsBlockView(steps: [step("a", "get_jira_issue", .succeeded), step("b", "search_knowledge", .failed)],
                                  isRunning: false)
        XCTAssertNoThrow(try view.inspect().find(text: "Worked for 2s · 2 steps"))
        XCTAssertNoThrow(try view.inspect().find(text: "Opened P-1"))
    }

    func testEmptyStepsRenderNothing() throws {
        let view = StepsBlockView(steps: [], isRunning: false)
        XCTAssertThrowsError(try view.inspect().find(ViewType.DisclosureGroup.self))
    }

    private func sources(_ count: Int) -> [ChatSource] {
        (1...count).map {
            ChatSource(kind: "slack", title: "#payments — m\($0)", url: "https://acme.slack.com/archives/C1/p\($0)",
                       ref: "s\($0)", group: "#payments")
        }
    }

    /// Ten sources are one single-line button, not ten chips; duplicates count once.
    func testSourcesRowIsOneLineWithCountAndTopGroups() throws {
        var opened = 0
        let view = SourcesSummaryRow(sources: sources(10) + sources(2)) { opened += 1 }
        XCTAssertEqual(try view.inspect().findAll(ViewType.Button.self).count, 1)
        XCTAssertNoThrow(try view.inspect().find(text: "10 sources"))
        XCTAssertNoThrow(try view.inspect().find(text: "#payments ×10"))
        XCTAssertEqual(try view.inspect().find(ViewType.HStack.self).lineLimit(), 1)
        XCTAssertEqual(SourcesSummaryRow.accessibilityLabel(ChatSourceGrouping.summary(sources(10))),
                       "10 sources, mostly #payments ×10. Show sources")
        try view.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(opened, 1)
    }

    func testSourcesRowRendersNothingWithoutSources() throws {
        let view = SourcesSummaryRow(sources: []) {}
        XCTAssertThrowsError(try view.inspect().find(ViewType.Button.self))
    }

    private func finishedStep(_ sources: [ChatSource]) -> ChatStepDisplay {
        ChatStepDisplay(id: "a", name: "search_knowledge", argsJSON: "{}", state: .succeeded, summary: "s",
                        sources: sources, startedAt: t0, endedAt: t0.addingTimeInterval(1))
    }

    /// While the turn streams the sources row stays hidden; it appears once finished.
    func testSourcesRowHiddenWhileStreaming() throws {
        let streaming = AssistantMessageBody(text: "Partial", steps: [finishedStep(sources(3))], isRunning: true)
        XCTAssertThrowsError(try streaming.inspect().find(SourcesSummaryRow.self))
        let done = AssistantMessageBody(text: "Answer", steps: [finishedStep(sources(3))], isRunning: false)
        XCTAssertNoThrow(try done.inspect().find(SourcesSummaryRow.self))
        XCTAssertNoThrow(try done.inspect().find(text: "3 sources"))
    }

    func testSourcesPanelGroupsItemsAndDisablesLinklessOnes() throws {
        let jira = ChatSource(kind: "jira", title: "PAY-1: A", url: nil, ref: "jira:PAY-1", group: "PAY",
                              snippet: "In Progress", date: "2026-05-10")
        let panel = ChatSourcesPanelView(selection: ChatSourcesSelection(messageID: 1, sources: sources(2) + [jira])) {}
        XCTAssertNoThrow(try panel.inspect().find(text: "#payments"))
        XCTAssertNoThrow(try panel.inspect().find(text: "PAY"))
        XCTAssertNoThrow(try panel.inspect().find(text: "m1"), "the group prefix is dropped from item titles")
        XCTAssertNoThrow(try panel.inspect().find(text: "In Progress"))
        let rows = try panel.inspect().findAll(SourceItemRow.self)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(try rows[2].find(ViewType.Button.self).isDisabled(), "no URL and no Jira site = not clickable")
        XCTAssertFalse(try rows[0].find(ViewType.Button.self).isDisabled())
    }
}
