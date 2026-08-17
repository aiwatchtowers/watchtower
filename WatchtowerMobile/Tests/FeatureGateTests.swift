import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// The feature-visibility satellite's phone half (App/FeatureGate.swift):
/// the ONE surface → feature-id lookup, its fail-open defaults, and the
/// desktop-mirroring navigation fallback. Exercises the pure static cores —
/// the replica observation itself is the same ReplicaObserver bridge every
/// tab already uses (covered by ReplicaWiringTests).
final class FeatureGateTests: XCTestCase {

    private func visibility(disabling ids: [String]) -> FeatureVisibility {
        FeatureVisibility(states: ids.map { FeatureState(id: $0, enabled: false) })
    }

    // MARK: - Degenerate: empty replica

    /// No feature_state rows (older desktop, or first launch before the
    /// first hydrate): every surface is visible.
    func testEmptyReplicaEverythingVisible() {
        let all = FeatureVisibility.allVisible
        for tab in [RootTabView.Tab.today, .chat, .inbox, .tasks, .tracks, .settings] {
            XCTAssertTrue(FeatureGate.isVisible(.tab(tab), visibility: all), "\(tab) must be visible")
        }
        XCTAssertTrue(FeatureGate.isVisible(.todayBriefing, visibility: all))
        XCTAssertTrue(FeatureGate.isVisible(.todayDayPlan, visibility: all))
    }

    // MARK: - Mapping

    func testEachSurfaceHidesOnItsOwnFeatureID() {
        XCTAssertFalse(FeatureGate.isVisible(.tab(.tasks), visibility: visibility(disabling: ["targets"])))
        XCTAssertFalse(FeatureGate.isVisible(.tab(.tracks), visibility: visibility(disabling: ["tracks"])))
        XCTAssertFalse(FeatureGate.isVisible(.tab(.inbox), visibility: visibility(disabling: ["secretary-inbox"])))
        XCTAssertFalse(FeatureGate.isVisible(.tab(.chat), visibility: visibility(disabling: ["chat"])))
        XCTAssertFalse(FeatureGate.isVisible(.todayBriefing, visibility: visibility(disabling: ["briefing"])))
        XCTAssertFalse(FeatureGate.isVisible(.todayDayPlan, visibility: visibility(disabling: ["day-plan"])))
    }

    func testDisablingOneFeatureLeavesTheOthersVisible() {
        let vis = visibility(disabling: ["targets"])
        XCTAssertTrue(FeatureGate.isVisible(.tab(.tracks), visibility: vis))
        XCTAssertTrue(FeatureGate.isVisible(.tab(.inbox), visibility: vis))
        XCTAssertTrue(FeatureGate.isVisible(.tab(.chat), visibility: vis))
        XCTAssertTrue(FeatureGate.isVisible(.todayBriefing, visibility: vis))
        XCTAssertTrue(FeatureGate.isVisible(.todayDayPlan, visibility: vis))
    }

    /// Unknown ids in the slice (a future desktop feature the phone does not
    /// map) are ignored — nothing hides.
    func testUnknownFeatureIDsAreIgnored() {
        let vis = visibility(disabling: ["stream-digests", "some-future-feature"])
        for tab in [RootTabView.Tab.chat, .inbox, .tasks, .tracks] {
            XCTAssertTrue(FeatureGate.isVisible(.tab(tab), visibility: vis), "\(tab) must be visible")
        }
        XCTAssertTrue(FeatureGate.isVisible(.todayBriefing, visibility: vis))
        XCTAssertTrue(FeatureGate.isVisible(.todayDayPlan, visibility: vis))
    }

    /// Today and Settings are never hideable — even a slice disabling every
    /// registry feature leaves them standing.
    func testTodayAndSettingsAreNeverHideable() {
        let vis = visibility(disabling: [
            "targets", "tracks", "secretary-inbox", "chat", "briefing", "day-plan",
            "dashboard", "feed", "memory", "next-step"
        ])
        XCTAssertTrue(FeatureGate.isVisible(.tab(.today), visibility: vis))
        XCTAssertTrue(FeatureGate.isVisible(.tab(.settings), visibility: vis))
    }

    // MARK: - Navigation fallback (mirrors the desktop)

    func testHiddenSelectionFallsBackToToday() {
        let vis = visibility(disabling: ["targets"])
        XCTAssertEqual(FeatureGate.resolvedSelection(.tasks, visibility: vis), .today)
    }

    func testVisibleSelectionIsKept() {
        let vis = visibility(disabling: ["targets"])
        XCTAssertEqual(FeatureGate.resolvedSelection(.tracks, visibility: vis), .tracks)
        XCTAssertEqual(FeatureGate.resolvedSelection(.settings, visibility: vis), .settings)
        XCTAssertEqual(FeatureGate.resolvedSelection(.today, visibility: vis), .today)
    }

    /// Re-enabling on the desktop restores the tab; the selection fallback
    /// is one-way (nothing jumps the user back automatically).
    func testReenabledFeatureIsVisibleAgain() {
        XCTAssertTrue(FeatureGate.isVisible(.tab(.tasks), visibility: .allVisible))
        XCTAssertEqual(FeatureGate.resolvedSelection(.tasks, visibility: .allVisible), .tasks)
    }
}
