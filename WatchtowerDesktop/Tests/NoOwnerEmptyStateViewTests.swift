import XCTest
import SwiftUI
import ViewInspector
import WatchtowerCore
@testable import WatchtowerDesktop

/// OWNER-02 on the Desktop: with no owner identity, Day Plan and Briefings
/// show `NoOwnerEmptyState` and offer no Generate. `DayPlanView` and
/// `BriefingsListView` read `@Environment(AppState.self)`, which ViewInspector
/// cannot populate (see `TrayMenuViewTests`), so these tests drive the
/// environment-free pieces those screens render.
@MainActor
final class NoOwnerEmptyStateViewTests: XCTestCase {
    private static let known = Owner(
        id: "1:U1", source: .slack, slackUserID: "1:U1", email: "", jiraAccountID: "", displayName: "Me"
    )
    private static let message = "Connect Slack, Google or Jira so Watchtower knows who you are"

    // MARK: - NoOwnerEmptyState

    func testOwner02EmptyStateTextAndOpenConnections() throws {
        var opened = false
        let view = NoOwnerEmptyState { opened = true }

        XCTAssertNoThrow(try view.inspect().find(text: Self.message))
        try view.inspect().find(button: "Open Connections").tap()
        XCTAssertTrue(opened)
    }

    // MARK: - Briefings

    func testOwner02BriefingsUnknownOwnerShowsEmptyStateAndNoGenerate() throws {
        let view = makeBriefingsEmpty(owner: .unknown)

        XCTAssertNoThrow(try view.inspect().find(text: Self.message))
        XCTAssertNoThrow(try view.inspect().find(button: "Open Connections"))
        XCTAssertThrowsError(try view.inspect().find(text: "Generate Briefing"))
    }

    func testBriefingsKnownOwnerOffersGenerate() throws {
        var generated = false
        let view = makeBriefingsEmpty(owner: Self.known) { generated = true }

        XCTAssertThrowsError(try view.inspect().find(text: Self.message))
        let label = try view.inspect().find(text: "Generate Briefing")
        try label.find(ViewType.Button.self, relation: .parent).tap()
        XCTAssertTrue(generated)
    }

    // MARK: - Day Plan

    func testOwner02DayPlanUnknownOwnerOffersNoGenerate() throws {
        for hasPlan in [false, true] {
            let footer = makeDayPlanFooter(owner: .unknown, hasPlan: hasPlan)
            XCTAssertThrowsError(try footer.inspect().find(button: "Generate today's plan"))
            XCTAssertThrowsError(try footer.inspect().find(button: "Regenerate with feedback…"))
            XCTAssertThrowsError(try footer.inspect().find(button: "Reset plan"))
        }
    }

    func testDayPlanKnownOwnerOffersGenerateOrRegenerate() throws {
        var generated = false
        let empty = makeDayPlanFooter(owner: Self.known, hasPlan: false) { generated = true }
        try empty.inspect().find(button: "Generate today's plan").tap()
        XCTAssertTrue(generated)

        let planned = makeDayPlanFooter(owner: Self.known, hasPlan: true)
        XCTAssertNoThrow(try planned.inspect().find(button: "Regenerate with feedback…"))
        XCTAssertNoThrow(try planned.inspect().find(button: "Reset plan"))
    }

    /// The empty state replaces the plan body only when there is no plan to
    /// show: an existing plan stays readable.
    func testOwner02DayPlanShowsEmptyStateOnlyWithoutOwnerAndPlan() {
        XCTAssertTrue(DayPlanView.showsNoOwnerState(owner: .unknown, hasPlan: false))
        XCTAssertFalse(DayPlanView.showsNoOwnerState(owner: .unknown, hasPlan: true))
        XCTAssertFalse(DayPlanView.showsNoOwnerState(owner: Self.known, hasPlan: false))
        XCTAssertFalse(DayPlanView.showsNoOwnerState(owner: Self.known, hasPlan: true))
    }

    // MARK: - Helpers

    private func makeBriefingsEmpty(owner: Owner, onGenerate: @escaping () -> Void = {}) -> BriefingsEmptyState {
        BriefingsEmptyState(
            owner: owner, processing: false, isGenerating: false, generateError: nil,
            onGenerate: onGenerate
        ) {}
    }

    private func makeDayPlanFooter(
        owner: Owner, hasPlan: Bool, onGenerate: @escaping () -> Void = {}
    ) -> DayPlanFooterBar {
        DayPlanFooterBar(
            owner: owner, hasPlan: hasPlan, isGenerating: false,
            onGenerate: onGenerate, onRegenerate: {}, onReset: {}
        )
    }
}
