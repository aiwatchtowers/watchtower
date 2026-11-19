import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerInterface
import WatchtowerTestSupport

/// Mockup §8 "Ideas: busy, refused, didn't confirm" (#1170 Task 12): three
/// ideas' verdict bars as the idea pane draws them, each with its press
/// through the tower under it (`TowerRowState`) — Approve waiting for its
/// answer, Approve refused with Go's sentence and Retry, and an outcome the
/// tower could not confirm.
extension DesignShotFixtures {
    private static var ideaRowsPoolPath: String?

    static func ideasRowStates() -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            ideaRowsPoolPath = path
            let ideas = try pool.write { db -> [Idea] in
                for title in ["Share the release checklist with acme", "Move standup to 10:00", "Draft a note to colleague A"] {
                    try TestDatabase.insertIdea(db, title: title, status: "proposed")
                }
                return try Idea.fetchAll(db, sql: "SELECT * FROM ideas ORDER BY id")
            }
            let states: [TowerActionState] = [
                .busy, .refused("Couldn't approve it: this idea changed — look again."), .unknown
            ]
            return AnyView(
                VStack(alignment: .leading, spacing: Spacing.page) {
                    ForEach(Array(zip(ideas, states)), id: \.0.id) { idea, state in
                        VStack(alignment: .leading, spacing: Spacing.regular) {
                            Text(idea.title).font(.headline)
                            IdeaActionBar(idea: idea, allIdeas: ideas, actions: IdeaActions(), openRow: .constant(nil),
                                          isWriting: state == .busy)
                            TowerRowState(state: state, busyLabel: TowerPressText.approving) {}
                        }
                    }
                }
                .padding(16)
                .detailBackground())
        } catch {
            return failure(error)
        }
    }

    static func cleanUpIdeaRows() {
        if let ideaRowsPoolPath { TestDatabase.cleanup(path: ideaRowsPoolPath) }
        ideaRowsPoolPath = nil
    }
}
