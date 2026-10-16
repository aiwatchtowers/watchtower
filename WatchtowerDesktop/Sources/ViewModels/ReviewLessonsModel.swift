import Foundation
import GRDB
import Observation
import WatchtowerCore

/// Find repeats (board #328, spec §13): the workbench's proposed house rules
/// mined from its sent comments. Go proposes, accepts (appending the rule to
/// `.watchtower/review.md`) and dismisses through `workbench review lessons …`;
/// this model reads the proposed rows after each call.
@MainActor
@Observable
final class ReviewLessonsModel {
    private(set) var lessons: [ReviewLesson] = []
    /// A Find repeats call runs (it can take minutes: one LLM call).
    private(set) var finding = false
    /// An Accept or Dismiss runs: the rows' buttons wait for it.
    private(set) var deciding = false
    /// The last refusal or failure; cleared by the next action.
    private(set) var lastError: String?

    private let projectID: Int64
    private let cli: WorkbenchCLI
    private let db: DatabasePool

    init(projectID: Int64, cli: WorkbenchCLI, db: DatabasePool) {
        self.projectID = projectID
        self.cli = cli
        self.db = db
    }

    func load() throws {
        let project = projectID
        lessons = try db.read { try ReviewQueries.proposedLessons($0, projectID: project) }
    }

    func findRepeats() async {
        guard !finding, !deciding else { return }
        finding = true
        defer { finding = false }
        await perform(.propose)
    }

    func accept(_ id: Int64) async {
        await decide(.accept(id))
    }

    func dismiss(_ id: Int64) async {
        await decide(.dismiss(id))
    }

    // MARK: - Private

    /// One decision at a time: a second click while one runs does nothing.
    private func decide(_ action: WorkbenchCLI.LessonAction) async {
        guard !deciding, !finding else { return }
        deciding = true
        defer { deciding = false }
        await perform(action)
    }

    /// Runs one lessons command, then re-reads the proposals whatever it answered.
    private func perform(_ action: WorkbenchCLI.LessonAction) async {
        lastError = nil
        do {
            let env = try await cli.reviewLessons(projectID: projectID, action: action)
            if !env.ok { lastError = env.error ?? "The review command failed." }
        } catch {
            lastError = error.localizedDescription
        }
        do {
            try load()
        } catch {
            lastError = lastError ?? error.localizedDescription
        }
    }
}
