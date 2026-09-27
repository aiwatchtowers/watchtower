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

    func testSourceChipsDedupe() throws {
        let src = ChatSource(kind: "jira", title: "P-1", url: "https://x/P-1", ref: "P-1")
        let view = SourceChipsView(sources: [src, src])
        XCTAssertEqual(try view.inspect().findAll(ViewType.Button.self).count, 1)
    }
}
