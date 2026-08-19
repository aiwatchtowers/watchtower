import XCTest
import GRDB
@testable import WatchtowerCore

/// Row models are handed to SwiftUI views as stored inputs — `TargetDetailView`
/// takes a `Target`, `DayPlanItemRow` a `DayPlanItem`. SwiftUI decides whether to
/// re-evaluate a view's `body` by comparing those inputs with the type's own
/// `==`, so an `==` that reports two different revisions of the same row as equal
/// freezes the open screen: the write lands in SQLite, the reload re-reads it,
/// and the user still sees the old value until the view is rebuilt from scratch.
///
/// Equality on these models must therefore be value equality, never identity.
/// `Identifiable`/`ForEach` already carry identity through `id`.
final class ModelValueEqualityTests: XCTestCase {

    // MARK: - Target

    private func makeTarget(
        status: String = "todo",
        progress: Double = 0.0,
        subItems: String = "[]"
    ) -> Target {
        Target(row: Row([
            "id": 7,
            "text": "Ship the feature",
            "status": status,
            "progress": progress,
            "sub_items": subItems,
            "created_at": "2026-08-18T09:00:00Z",
            "updated_at": "2026-08-18T09:00:00Z"
        ]))
    }

    func testTargetsDifferingInStatusAreNotEqual() {
        XCTAssertNotEqual(makeTarget(status: "todo"), makeTarget(status: "in_progress"))
    }

    func testTargetsDifferingInProgressAreNotEqual() {
        XCTAssertNotEqual(makeTarget(progress: 0.0), makeTarget(progress: 0.5))
    }

    /// The checklist is `sub_items` on the target's own row: ticking a box never
    /// changes the id, so identity equality hid the whole checklist — and the
    /// progress ring derived from it — behind a view SwiftUI refused to redraw.
    func testTargetsDifferingInSubItemsAreNotEqual() {
        XCTAssertNotEqual(
            makeTarget(subItems: #"[{"text":"Draft","done":false}]"#),
            makeTarget(subItems: #"[{"text":"Draft","done":true}]"#)
        )
    }

    func testIdenticalTargetsAreEqual() {
        XCTAssertEqual(makeTarget(), makeTarget())
    }

    // MARK: - TargetLink

    private func makeLink(relation: String) -> TargetLink {
        TargetLink(row: Row([
            "id": 3,
            "source_target_id": 7,
            "target_target_id": 8,
            "external_ref": "",
            "relation": relation,
            "created_by": "user",
            "created_at": "2026-08-18T09:00:00Z"
        ]))
    }

    func testTargetLinksDifferingInRelationAreNotEqual() {
        XCTAssertNotEqual(makeLink(relation: "related"), makeLink(relation: "blocks"))
    }

    // MARK: - Day plan

    func testDayPlanItemsDifferingInStatusAreNotEqual() {
        let stamp = Date(timeIntervalSince1970: 1_755_000_000)
        let pending = DayPlanItem.stub(status: .pending, createdAt: stamp, updatedAt: stamp)
        let done = DayPlanItem.stub(status: .done, createdAt: stamp, updatedAt: stamp)
        XCTAssertNotEqual(pending, done)
    }

    func testIdenticalDayPlanItemsAreEqual() {
        let stamp = Date(timeIntervalSince1970: 1_755_000_000)
        XCTAssertEqual(
            DayPlanItem.stub(createdAt: stamp, updatedAt: stamp),
            DayPlanItem.stub(createdAt: stamp, updatedAt: stamp)
        )
    }

    func testDayPlansDifferingInConflictSummaryAreNotEqual() {
        let stamp = Date(timeIntervalSince1970: 1_755_000_000)
        let quiet = DayPlan.stub(
            conflictSummary: nil, generatedAt: stamp, createdAt: stamp, updatedAt: stamp
        )
        let noisy = DayPlan.stub(
            conflictSummary: "Two meetings overlap", generatedAt: stamp,
            createdAt: stamp, updatedAt: stamp
        )
        XCTAssertNotEqual(quiet, noisy)
    }
}
