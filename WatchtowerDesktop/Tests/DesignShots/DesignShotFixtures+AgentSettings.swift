import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Agent Settings screen (board #1150) under the title row, on a wide
/// window, with the CLI's pinned answers: the methodology envelope and an
/// instructions state with one suggestion.
@MainActor
enum AgentSettingsShotFixtures {
    private static var poolPath: String?
    private static var built: (vm: WorkbenchesViewModel, project: Workbench)?
    /// The screen reads `AppState` (Edit in Settings).
    private static let appState = AppState(workbenchDefaults: AppState.isolatedDefaults)

    static func cleanUp() {
        if let poolPath { TestDatabase.cleanup(path: poolPath) }
        poolPath = nil
        built = nil
    }

    static func screen() -> AnyView {
        do {
            let state = try built ?? build()
            built = state
            return AnyView(VStack(spacing: 0) {
                HStack(spacing: Spacing.regular) {
                    Text(state.project.name).font(.headline)
                    WorkbenchHeaderControls(vm: state.vm, project: state.project, onDelete: {}, onCleanUpOldWorktrees: {})
                }
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.regular)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Stroke.hairlineColor).frame(height: Stroke.hairline)
                }
                AgentSettingsScreen(vm: state.vm, project: state.project)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .detailBackground()
            .environment(appState))
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    private static func build() throws -> (vm: WorkbenchesViewModel, project: Workbench) {
        let (pool, path) = try TestDatabase.createPool()
        poolPath = path
        let project = try pool.write { db in
            let id = try TestDatabase.insertWorkbench(db, name: "acme-app", folder: "/tmp/acme-app")
            return try XCTUnwrap(try Workbench.fetchOne(db, sql: "SELECT * FROM projects WHERE id = ?", arguments: [id]))
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: DesignShotFixtures.defaultsSuite))
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: Runner()), defaults: defaults)
        vm.selectedWorkbenchID = project.id
        // Loaded the app's way, through the fake CLI, before the shot.
        Task { @MainActor [vm] in
            await vm.loadMethodology(projectID: project.id)
            await vm.loadInstructions(projectID: project.id)
        }
        let deadline = Date().addingTimeInterval(5)
        while vm.methodology[project.id] == nil || vm.instructions[project.id] == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(vm.methodology[project.id], "the methodology state loaded")
        XCTAssertNotNil(vm.instructions[project.id], "the instructions state loaded")
        vm.openAgentSettingsScreen(projectID: project.id)
        return (vm, project)
    }

    nonisolated private static func instructions(_ id: Int64) -> String {
        """
        {"ok":true,"limit":1000,"global":{"session":"Reply in the language of the owner.","procedure":""},\
        "workbench":{"id":\(id),"session":"Run make lint-diff before handing a task back.","procedure":""},\
        "suggestions":[{"id":4,"text":"Check the diff before you commit","field":"procedure","workbench_id":\(id),\
        "session_count":3,"workbench_count":1,"first_seen_at":"2026-10-11T08:00:00Z",\
        "last_seen_at":"2026-10-16T09:30:00Z"}]}
        """
    }

    /// The screen's own loads answer with the same pinned states.
    private final class Runner: CLIRunnerProtocol, @unchecked Sendable {
        func run(args: [String]) async throws -> Data {
            if args.first == "instructions" {
                let id = args.firstIndex(of: "--workbench").flatMap { $0 + 1 < args.count ? Int64(args[$0 + 1]) : nil } ?? 1
                return Data(AgentSettingsShotFixtures.instructions(id).utf8)
            }
            return Data(WorkbenchMethodologyFixtures.envelope.utf8)
        }

        func run(args: [String], timeout: TimeInterval) async throws -> Data { try await run(args: args) }
        func run(args: [String], stdin: Data) async throws -> Data { try await run(args: args) }
    }
}
