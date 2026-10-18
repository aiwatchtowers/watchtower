import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class BlockerCardViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeEntry(
        issueKey: String = "PROJ-100",
        trackerName: String = "Jira",
        issueURL: URL? = nil,
        summary: String = "Login broken",
        status: String = "Blocked",
        assigneeName: String = "Alice",
        blockedDays: Int = 5,
        blockerType: String = "blocked",
        blockingChain: [String] = [],
        chainURLs: [String: URL] = [:],
        downstreamCount: Int = 0,
        whoToPing: [BlockerMapViewModel.PingTarget] = [],
        slackContext: String = "",
        urgency: BlockerMapViewModel.BlockerUrgency = .red
    ) -> BlockerMapViewModel.BlockerEntry {
        BlockerMapViewModel.BlockerEntry(
            issueKey: issueKey,
            trackerName: trackerName,
            issueURL: issueURL,
            summary: summary,
            status: status,
            assigneeName: assigneeName,
            blockedDays: blockedDays,
            blockerType: blockerType,
            blockingChain: blockingChain,
            chainURLs: chainURLs,
            downstreamCount: downstreamCount,
            whoToPing: whoToPing,
            slackContext: slackContext,
            urgency: urgency
        )
    }

    private func makeTarget(
        slackUserID: String = "U1",
        displayName: String = "Alice",
        reason: String = "assignee"
    ) -> BlockerMapViewModel.PingTarget {
        BlockerMapViewModel.PingTarget(
            slackUserID: slackUserID,
            displayName: displayName,
            reason: reason
        )
    }

    // MARK: - Tests

    /// A Linear card links to the issue's own page from the tracker view.
    func testLinearCardLinksToItsIssuePage() throws {
        let url = try XCTUnwrap(URL(string: "https://linear.app/acme/issue/ENG-7"))
        let view = BlockerCardView(entry: makeEntry(issueKey: "ENG-7", trackerName: "Linear", issueURL: url))
        let link = try view.inspect().find(ViewType.Link.self)
        XCTAssertEqual(try link.url(), url)
    }

    /// Without a link of its own, a Linear card never borrows a Jira one.
    func testLinearCardWithoutURLHasNoLink() throws {
        let view = BlockerCardView(entry: makeEntry(issueKey: "ENG-7", trackerName: "Linear"))
        XCTAssertThrowsError(try view.inspect().find(ViewType.Link.self))
        XCTAssertNoThrow(try view.inspect().find(text: "ENG-7"))
    }

    /// Issue key, status и summary рендерятся.
    func testCoreFieldsRendered() throws {
        let view = BlockerCardView(entry: makeEntry(
            issueKey: "PROJ-42",
            summary: "Login fails",
            status: "Blocked"
        ))
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "PROJ-42"))
        XCTAssertNoThrow(try inspected.find(text: "Blocked"))
        XCTAssertNoThrow(try inspected.find(text: "Login fails"))
    }

    /// daysLabel: "<N>d blocked" для типа "blocked".
    func testDaysLabelBlocked() throws {
        let view = BlockerCardView(entry: makeEntry(blockedDays: 7, blockerType: "blocked"))
        XCTAssertNoThrow(try view.inspect().find(text: "7d blocked"))
    }

    /// daysLabel: "<N>d stale" для любого другого типа.
    func testDaysLabelStale() throws {
        let view = BlockerCardView(entry: makeEntry(blockedDays: 12, blockerType: "stale"))
        XCTAssertNoThrow(try view.inspect().find(text: "12d stale"))
    }

    /// Empty assigneeName → Label про assignee не строится.
    func testAssigneeHiddenWhenEmpty() throws {
        let view = BlockerCardView(entry: makeEntry(assigneeName: ""))
        // Имя «Alice» отсутствует, остальное (status, key) — да.
        XCTAssertThrowsError(try view.inspect().find(text: "Alice"))
    }

    /// Assignee показывается, когда задан.
    func testAssigneeShownWhenSet() throws {
        let view = BlockerCardView(entry: makeEntry(assigneeName: "Bob Builder"))
        XCTAssertNoThrow(try view.inspect().find(text: "Bob Builder"))
    }

    /// downstreamCount=0 → метка не строится.
    func testDownstreamHiddenWhenZero() throws {
        let view = BlockerCardView(entry: makeEntry(downstreamCount: 0))
        XCTAssertThrowsError(try view.inspect().find(text: "Blocks 0 issues"))
    }

    /// downstreamCount=1 → "Blocks 1 issue" (singular).
    func testDownstreamSingular() throws {
        let view = BlockerCardView(entry: makeEntry(downstreamCount: 1))
        XCTAssertNoThrow(try view.inspect().find(text: "Blocks 1 issue"))
    }

    /// downstreamCount>1 → plural форма.
    func testDownstreamPlural() throws {
        let view = BlockerCardView(entry: makeEntry(downstreamCount: 4))
        XCTAssertNoThrow(try view.inspect().find(text: "Blocks 4 issues"))
    }

    /// whoToPing непустой → блок «Who to ping:» + имя + (reason).
    func testWhoToPingRendered() throws {
        let view = BlockerCardView(entry: makeEntry(
            whoToPing: [makeTarget(displayName: "Carol", reason: "expert")]
        ))
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Who to ping:"))
        XCTAssertNoThrow(try inspected.find(text: "Carol"))
        XCTAssertNoThrow(try inspected.find(text: "(expert)"))
    }

    /// slackContext непустой → текст рендерится.
    func testSlackContextShownWhenSet() throws {
        let view = BlockerCardView(entry: makeEntry(slackContext: "user mentioned in #ops"))
        XCTAssertNoThrow(try view.inspect().find(text: "user mentioned in #ops"))
    }

    /// blockingChain длиной >1 → "(root cause)" hint.
    func testRootCauseHintWhenChainHasMultipleEntries() throws {
        let view = BlockerCardView(entry: makeEntry(
            blockingChain: ["PROJ-1", "PROJ-2"]
        ))
        XCTAssertNoThrow(try view.inspect().find(text: "(root cause)"))
    }

    /// blockingChain длиной 1 — root cause hint не появляется.
    func testRootCauseHintHiddenForSingleChain() throws {
        let view = BlockerCardView(entry: makeEntry(blockingChain: ["PROJ-1"]))
        XCTAssertThrowsError(try view.inspect().find(text: "(root cause)"))
    }
}
