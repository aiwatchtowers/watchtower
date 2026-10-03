import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

final class WorkbenchCLITests: XCTestCase {
    func testCreatePassesFolderNameAndJSONAndDecodesTheEnvelope() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"id":7,"folder":"/tmp/acme","name":"acme"}"#.utf8))
        let created = try await WorkbenchCLI(runner: runner).create(folder: "/tmp/acme dir", name: "Acme")
        XCTAssertEqual(created, WorkbenchCreated(id: 7, folder: "/tmp/acme", name: "acme"))
        XCTAssertEqual(runner.invocations, [["workbench", "create", "--folder", "/tmp/acme dir", "--json", "--name", "Acme"]])
    }

    func testCreateDecodesAFailedDocumentImport() async throws {
        let json = #"{"id":7,"folder":"/tmp/acme","name":"acme","docs_import_ok":false,"docs_import_error":"permission denied"}"#
        let created = try await WorkbenchCLI(runner: FakeCLIRunner(stdout: Data(json.utf8))).create(folder: "/tmp/acme", name: nil)
        XCTAssertFalse(created.docsImportOK)
        XCTAssertEqual(created.docsImportError, "permission denied")
        XCTAssertEqual(created.importNote,
                       "Importing the folder's documents failed (permission denied) — retry with: watchtower workbench import-docs 7")
    }

    func testCreateDecodesSkippedPathsAndAnOlderEnvelopeMeansNothingFailed() throws {
        let json = #"""
            {"id":7,"folder":"/tmp/acme","name":"acme","docs_import_ok":true,"docs_import_error":"",
             "docs_import":{"imported":["README.md"],"already_attached":[],"dry_run":false,
             "skipped_over_cap":["docs/specs/a.md","docs/specs/b.md"],
             "unreadable":["docs/private: permission denied","docs/x: no such file or directory"]}}
            """#
        let created = try JSONDecoder().decode(WorkbenchCreated.self, from: Data(json.utf8))
        XCTAssertEqual(created.unreadable.count, 2)
        XCTAssertEqual(created.skippedOverCap, 2)
        XCTAssertEqual(created.importNote,
                       "Could not read docs/private: permission denied and 1 more — fix it, then run: "
                       + "watchtower workbench import-docs 7. 2 more document(s) past the import cap — run: "
                       + "watchtower workbench import-docs 7")

        let older = try JSONDecoder().decode(WorkbenchCreated.self, from: Data(#"{"id":1,"folder":"/tmp/a","name":"a"}"#.utf8))
        XCTAssertTrue(older.docsImportOK)
        XCTAssertEqual(older.docsImportError, "")
        XCTAssertNil(older.importNote, "a CLI without the keys reports no failure")
    }

    func testCreateWithoutNameOmitsTheFlag() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"id":1,"folder":"/tmp/a","name":"a"}"#.utf8))
        _ = try await WorkbenchCLI(runner: runner).create(folder: "/tmp/a", name: nil)
        XCTAssertEqual(runner.invocations, [["workbench", "create", "--folder", "/tmp/a", "--json"]])
    }

    func testInstallStatusAndDeleteArguments() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"skill":"unchanged","hook":true,"mcp":false}"#.utf8))
        let cli = WorkbenchCLI(runner: runner)
        try await cli.install(projectID: 3)
        let status = try await cli.status(projectID: 3)
        XCTAssertEqual(runner.invocations, [
            ["integrate", "claude-code", "--workbench", "3"],
            ["integrate", "status", "--workbench", "3", "--json"]
        ])
        XCTAssertEqual(status, WorkbenchInstallStatus(skill: "unchanged", hook: true, mcp: false))
        XCTAssertTrue(status.needsRepair)
    }

    /// PROJ-07: a project installed before the Stop hook existed is offered
    /// Repair; an older CLI without the key has nothing to install.
    func testMissingStopHookNeedsRepair() throws {
        let missing = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(
            #"{"skill":"unchanged","hook":true,"stop_hook":false,"mcp":true}"#.utf8))
        XCTAssertFalse(missing.stopHook)
        XCTAssertTrue(missing.needsRepair)
        let older = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(
            #"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        XCTAssertTrue(older.stopHook)
        XCTAssertFalse(older.needsRepair)
    }

    /// Board #312: a workbench installed before the session-state hooks is
    /// offered Repair; an older CLI without the key has nothing to install.
    func testMissingStateHooksNeedRepair() throws {
        let missing = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(
            #"{"skill":"unchanged","hook":true,"stop_hook":true,"state_hooks":false,"mcp":true}"#.utf8))
        XCTAssertFalse(missing.stateHooks)
        XCTAssertTrue(missing.needsRepair)
        let present = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(
            #"{"skill":"unchanged","hook":true,"stop_hook":true,"state_hooks":true,"mcp":true}"#.utf8))
        XCTAssertFalse(present.needsRepair)
        let older = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(
            #"{"skill":"unchanged","hook":true,"stop_hook":true,"mcp":true}"#.utf8))
        XCTAssertTrue(older.stateHooks)
        XCTAssertFalse(older.needsRepair)
    }

    /// Owner asks (spec 2026-10-03 §6): a workbench missing either ask guard
    /// hook is offered Repair; an older CLI without the keys has nothing to
    /// install.
    func testMissingAskGuardHooksNeedRepair() throws {
        let base = #""skill":"unchanged","hook":true,"stop_hook":true,"state_hooks":true,"mcp":true"#
        for (keys, guarded, blocked) in [
            (#""ask_guard":false,"ask_tool_block":true"#, false, true),
            (#""ask_guard":true,"ask_tool_block":false"#, true, false)
        ] {
            let missing = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data("{\(base),\(keys)}".utf8))
            XCTAssertEqual(missing.askGuard, guarded, keys)
            XCTAssertEqual(missing.askToolBlock, blocked, keys)
            XCTAssertTrue(missing.needsRepair, keys)
        }
        let present = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(
            "{\(base),\"ask_guard\":true,\"ask_tool_block\":true}".utf8))
        XCTAssertFalse(present.needsRepair)
        let older = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data("{\(base)}".utf8))
        XCTAssertTrue(older.askGuard)
        XCTAssertTrue(older.askToolBlock)
        XCTAssertFalse(older.needsRepair)
    }

    func testCheckDriftRunsOfflineAndDecodesTheReport() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"project_id":4,"git":true,"base":"main","findings":[]}"#.utf8))
        let report = try await WorkbenchCLI(runner: runner).checkDrift(projectID: 4)
        XCTAssertEqual(runner.invocations, [["workbench", "check", "--workbench", "4", "--json", "--no-network"]])
        XCTAssertTrue(report.findings.isEmpty)
    }

    func testDeletePassesJSONAndDecodesBothEnvelopeShapes() async throws {
        let clean = FakeCLIRunner(stdout: Data(#"{"id":3,"deleted":true,"removal_ok":true,"removal_error":""}"#.utf8))
        let ok = try await WorkbenchCLI(runner: clean).delete(projectID: 3)
        XCTAssertEqual(clean.invocations, [["workbench", "delete", "3", "--json"]])
        XCTAssertEqual(ok, WorkbenchDeleted(id: 3, deleted: true, removalOK: true, removalError: ""))

        let partial = FakeCLIRunner(
            stdout: Data(#"{"id":3,"deleted":true,"removal_ok":false,"removal_error":"hook: permission denied"}"#.utf8)
        )
        let warned = try await WorkbenchCLI(runner: partial).delete(projectID: 3)
        XCTAssertEqual(warned, WorkbenchDeleted(id: 3, deleted: true, removalOK: false, removalError: "hook: permission denied"))

        let images = FakeCLIRunner(stdout: Data(
            #"{"id":3,"deleted":true,"removal_ok":true,"removal_error":"","files_ok":false,"files_error":"permission denied"}"#.utf8
        ))
        let imageWarned = try await WorkbenchCLI(runner: images).delete(projectID: 3)
        XCTAssertFalse(imageWarned.filesOK)
        XCTAssertEqual(imageWarned.filesError, "permission denied")
        XCTAssertEqual(imageWarned.cleanupWarning, "The workbench was deleted, but removing its stored images failed: permission denied")
        XCTAssertTrue(ok.filesOK, "an envelope without files_* keys decodes as clean")
        XCTAssertNil(ok.cleanupWarning)
        XCTAssertEqual(
            WorkbenchDeleted(id: 3, deleted: true, removalOK: false, removalError: "a", filesOK: false, filesError: "b").cleanupWarning,
            "The workbench was deleted, but cleaning its folder failed: a; removing its stored images failed: b"
        )
    }

    func testAttachDocumentEndsFlagsBeforeThePathAndDecodesTheEnvelope() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"document_id":9,"rel_path":"docs/-x.md","created":true}"#.utf8))
        let cli = WorkbenchCLI(runner: runner)
        let attached = try await cli.attachDocument(projectID: 3, path: "/tmp/acme/docs/-x.md", kind: "spec", targetID: 5)
        XCTAssertEqual(attached, WorkbenchDocumentAttached(documentID: 9, relPath: "docs/-x.md", created: true))
        _ = try await cli.attachDocument(projectID: 3, path: "/tmp/acme/a.md", kind: "doc", targetID: nil)
        XCTAssertEqual(runner.invocations, [
            ["workbench", "attach-doc", "--kind", "spec", "--json", "--target", "5", "--", "3", "/tmp/acme/docs/-x.md"],
            ["workbench", "attach-doc", "--kind", "doc", "--json", "--", "3", "/tmp/acme/a.md"]
        ])
    }

    func testNeedsRepairOnlyWhenSomethingIsMissing() {
        XCTAssertFalse(WorkbenchInstallStatus(skill: "unchanged", hook: true, mcp: true).needsRepair)
        XCTAssertFalse(WorkbenchInstallStatus(skill: "drifted", hook: true, mcp: true).needsRepair)
        XCTAssertTrue(WorkbenchInstallStatus(skill: "missing", hook: true, mcp: true).needsRepair)
        XCTAssertTrue(WorkbenchInstallStatus(skill: "unchanged", hook: false, mcp: true).needsRepair)
    }

    func testSkillUpdatedNeedsRepairAndClaudeFoundDecodes() throws {
        XCTAssertTrue(WorkbenchInstallStatus(skill: "updated", hook: true, mcp: true).needsRepair)
        let json = Data(#"{"skill":"unchanged","hook":true,"mcp":false,"claude_found":false}"#.utf8)
        let status = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: json)
        XCTAssertEqual(status, WorkbenchInstallStatus(skill: "unchanged", hook: true, mcp: false, claudeFound: false))
        let legacy = try JSONDecoder().decode(
            WorkbenchInstallStatus.self, from: Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8)
        )
        XCTAssertTrue(legacy.claudeFound, "an older CLI without the key could check the registration")
    }

    /// `integrate status` on a folder set up before the Workbench rename
    /// (spec 2026-10-02 §5.4): its old hooks and registration count as
    /// present, only the new skill reads `missing`. That is no Repair — the
    /// icon nudges toward Re-run Setup instead (A10) — and the prompts name
    /// the old skill (§5.3). An older CLI's JSON has no legacy keys.
    func testLegacyFolderStatus() throws {
        let legacy = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(#"""
            {"project_id":1,"folder":"/tmp/acme","skill":"missing","skill_path":"","hook":true,"stop_hook":true,
             "mcp":true,"claude_found":true,"legacy":true,"legacy_skill":"unchanged"}
            """#.utf8))
        XCTAssertTrue(legacy.legacy)
        XCTAssertEqual(legacy.legacySkill, "unchanged")
        XCTAssertFalse(legacy.needsRepair, "a working legacy folder is not offered Repair")
        XCTAssertEqual(legacy.legacyNotice, "Set up by an older Watchtower — Re-run Setup to update")
        XCTAssertEqual(legacy.vocabulary, .legacy)
        XCTAssertEqual(legacy.skillDisplay, "watchtower-project (older setup)")

        let older = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(
            #"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        XCTAssertFalse(older.legacy)
        XCTAssertEqual(older.legacySkill, "")
        XCTAssertNil(older.legacyNotice)
        XCTAssertEqual(older.vocabulary, .current)
        XCTAssertEqual(older.skillDisplay, "unchanged")

        // A resync whose `mcp add` failed: the new skill is in, only the old
        // registration serves it. The skill names tools the session lacks,
        // so Repair (which re-runs the add) is offered.
        let mixed = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(#"""
            {"skill":"unchanged","hook":true,"stop_hook":true,"mcp":true,"claude_found":true,
             "legacy":true,"legacy_skill":"","current_mcp":false}
            """#.utf8))
        XCTAssertEqual(mixed.currentMCP, false)
        XCTAssertEqual(mixed.vocabulary, .current)
        XCTAssertEqual(mixed.legacyNotice, "Set up by an older Watchtower — Re-run Setup to update")
        XCTAssertTrue(mixed.needsRepair)
        XCTAssertFalse(WorkbenchInstallStatus(skill: "unchanged", hook: true, mcp: true, currentMCP: true).needsRepair)
        XCTAssertFalse(WorkbenchInstallStatus(skill: "unchanged", hook: true, mcp: false, claudeFound: false,
                                              currentMCP: false).needsRepair,
                       "without claude the registration is not repairable from here")
    }

    /// An older CLI sends no `current_mcp`: the decision falls back to `mcp`.
    func testStatusWithoutCurrentMCPKeepsTheOldRule() throws {
        let older = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(
            #"{"skill":"unchanged","hook":true,"mcp":true,"legacy":true,"legacy_skill":""}"#.utf8))
        XCTAssertEqual(older.currentMCP, older.mcp)
        XCTAssertFalse(older.needsRepair)
    }

    /// A legacy folder still needs Repair for what is actually broken, and
    /// when it has no skill at all there is nothing for the agent to read.
    func testLegacyFolderStillRepairsWhatIsBroken() {
        XCTAssertTrue(WorkbenchInstallStatus(skill: "missing", hook: false, mcp: true, legacy: true, legacySkill: "unchanged").needsRepair)
        XCTAssertTrue(WorkbenchInstallStatus(skill: "missing", hook: true, mcp: true, legacy: true).needsRepair,
                      "no skill in either vocabulary")
        XCTAssertTrue(WorkbenchInstallStatus(skill: "missing", hook: true, mcp: true, legacySkill: "drifted").needsRepair,
                      "not legacy: the new skill is simply missing")
    }

    /// Without `claude` the MCP registration is unknown and not repairable:
    /// Repair must not loop on `mcp=false`, but still repairs the rest.
    func testClaudeNotFoundDoesNotAskForRepairOfMCP() {
        XCTAssertFalse(WorkbenchInstallStatus(skill: "unchanged", hook: true, mcp: false, claudeFound: false).needsRepair)
        XCTAssertTrue(WorkbenchInstallStatus(skill: "unchanged", hook: false, mcp: false, claudeFound: false).needsRepair)
        XCTAssertTrue(WorkbenchInstallStatus(skill: "missing", hook: true, mcp: false, claudeFound: false).needsRepair)
    }

    /// Shared fixture with Go `TestProjectMCPCommand_MatchesTheDesktopFixture`
    /// (`internal/devpack/workbench_test.go`): same inputs, same text.
    func testManualMCPCommandMatchesTheGoTwin() {
        XCTAssertEqual(
            WorkbenchInstallStatus.manualMCPCommand(
                projectID: 7, folder: "/tmp/acme project", cliPath: "/tmp/acme bin/it's/watchtower"
            ),
            #"cd '/tmp/acme project' && claude mcp add --scope local watchtower-workbench -- '/tmp/acme bin/it'\''s/watchtower' mcp --workbench 7"#
        )
        XCTAssertEqual(
            WorkbenchInstallStatus.manualMCPCommand(projectID: 3, folder: "/tmp/acme", cliPath: "/usr/local/bin/watchtower"),
            "cd /tmp/acme && claude mcp add --scope local watchtower-workbench -- /usr/local/bin/watchtower mcp --workbench 3",
            "shell-safe paths stay bare, as Go leaves them"
        )
    }

    func testMalformedCreateOutputThrows() async {
        let runner = FakeCLIRunner(stdout: Data("created project 7".utf8))
        do {
            _ = try await WorkbenchCLI(runner: runner).create(folder: "/tmp/a", name: nil)
            XCTFail("expected a decode error")
        } catch {}
    }

    func testRunnerErrorPropagates() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "folder is already bound to a project"))
        do {
            try await WorkbenchCLI(runner: runner).install(projectID: 1)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already bound"))
        }
    }

    // MARK: - workbench git (#233)

    func testGitStatusAndBranchesArguments() async throws {
        let runner = ScriptedCLIRunner(results: [
            .success(Data(#"{"workbench_id":3,"git":true,"branch":"main"}"#.utf8)),
            .success(Data(#"{"workbench_id":3,"git":true,"current":"main","branches":[{"name":"main","current":true}]}"#.utf8))
        ])
        let cli = WorkbenchCLI(runner: runner)
        let status = try await cli.gitStatus(projectID: 3)
        let branches = try await cli.gitBranches(projectID: 3)
        XCTAssertEqual(runner.invocations, [
            ["workbench", "git", "status", "--workbench", "3", "--json"],
            ["workbench", "git", "branches", "--workbench", "3", "--json"]
        ])
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(branches.branches.map(\.name), ["main"])
    }

    func testGitSwitchPassesFlagsOnlyWhenSet() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"switched":true,"branch":"-odd name"}"#.utf8))
        let cli = WorkbenchCLI(runner: runner)
        _ = try await cli.gitSwitch(projectID: 3, branch: "-odd name", stash: false, agentRunning: false, confirmAgent: false)
        _ = try await cli.gitSwitch(projectID: 3, branch: "feature/x", stash: true, agentRunning: false, confirmAgent: false)
        _ = try await cli.gitSwitch(projectID: 3, branch: "feature/x", stash: false, agentRunning: true, confirmAgent: false)
        _ = try await cli.gitSwitch(projectID: 3, branch: "feature/x", stash: true, agentRunning: true, confirmAgent: true)
        let base = ["workbench", "git", "switch", "--workbench", "3", "--branch"]
        XCTAssertEqual(runner.invocations, [
            base + ["-odd name", "--json"],
            base + ["feature/x", "--stash", "--json"],
            base + ["feature/x", "--agent-running", "--json"],
            base + ["feature/x", "--stash", "--agent-running", "--confirm-agent", "--json"]
        ], "the branch is one argv element of its own, right after --branch")
    }

    func testGitCreateBranchArguments() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"switched":true,"created":true,"branch":"new/one"}"#.utf8))
        let result = try await WorkbenchCLI(runner: runner).gitCreateBranch(projectID: 5, name: "new/one")
        XCTAssertEqual(runner.invocations, [["workbench", "git", "create", "--workbench", "5", "--name", "new/one", "--json"]])
        XCTAssertTrue(result.created)
    }
}
