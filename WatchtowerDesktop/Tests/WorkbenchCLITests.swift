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

    /// The current envelope also carries the folder's index keys; an older
    /// CLI's document-import keys are ignored.
    func testCreateDecodesTheCurrentAndAnOlderEnvelope() throws {
        let current = #"{"id":7,"folder":"/tmp/acme","name":"acme","index_ok":true,"index_error":"","indexed":3,"index_skipped":false}"#
        XCTAssertEqual(try JSONDecoder().decode(WorkbenchCreated.self, from: Data(current.utf8)),
                       WorkbenchCreated(id: 7, folder: "/tmp/acme", name: "acme"))
        let older = #"{"id":7,"folder":"/tmp/acme","name":"acme","docs_import_ok":false,"docs_import_error":"permission denied"}"#
        XCTAssertEqual(try JSONDecoder().decode(WorkbenchCreated.self, from: Data(older.utf8)),
                       WorkbenchCreated(id: 7, folder: "/tmp/acme", name: "acme"))
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

    /// Board #535: a folder set up before the cleanup permission is offered
    /// Repair (the Claude Code part); an older CLI without the key has
    /// nothing to install.
    func testMissingCleanupPermissionNeedsRepair() throws {
        let base = #""skill":"unchanged","hook":true,"stop_hook":true,"state_hooks":true,"mcp":true"#
        let missing = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(
            "{\(base),\"cleanup_permission\":false}".utf8))
        XCTAssertFalse(missing.cleanupPermission)
        XCTAssertTrue(missing.claudeNeedsRepair)
        XCTAssertTrue(missing.repairHelp.contains("cleanup permission missing"), missing.repairHelp)
        let present = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(
            "{\(base),\"cleanup_permission\":true}".utf8))
        XCTAssertFalse(present.needsRepair)
        XCTAssertTrue(present.repairHelp.contains("cleanup permission on"), present.repairHelp)
        let older = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data("{\(base)}".utf8))
        XCTAssertTrue(older.cleanupPermission)
        XCTAssertFalse(older.needsRepair)
    }

    func testCheckDriftRunsOfflineAndDecodesTheReport() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"project_id":4,"git":true,"base":"main","findings":[]}"#.utf8))
        let report = try await WorkbenchCLI(runner: runner).checkDrift(projectID: 4)
        XCTAssertEqual(runner.invocations, [["workbench", "check", "--workbench", "4", "--json", "--no-network"]])
        XCTAssertTrue(report.findings.isEmpty)
    }

    /// Owner asks v2 Part 5.3: the stored stamp goes back verbatim as `--at`.
    func testEscalateQuestionPassesTheStampVerbatimAndDecodesTheEnvelope() async {
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"outcome":"filed","ask_id":9,"level":"quick"}"#.utf8))
        let result = await WorkbenchCLI(runner: runner).escalateQuestion(
            projectID: 4, sessionID: 12, at: "2026-10-10T12:00:00.123Z", reason: .left
        )
        XCTAssertEqual(runner.invocations, [[
            "workbench", "escalate-question", "--workbench", "4", "--session", "12",
            "--at", "2026-10-10T12:00:00.123Z", "--reason", "left"
        ]])
        XCTAssertEqual(result.verdict, .filed(askID: 9))
    }

    /// A non-zero exit or unparsable stdout is the Desktop's own failure
    /// envelope, not retried.
    func testEscalateQuestionFailuresBecomeTheDesktopsEnvelope() async {
        let failing = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 2, stderr: "boom"))
        let failed = await WorkbenchCLI(runner: failing).escalateQuestion(projectID: 1, sessionID: 2, at: "x", reason: .timeout)
        XCTAssertEqual(failed.errorCode, .internal)
        guard case .failed = failed.verdict else { return XCTFail("a non-zero exit is not retried") }

        let prose = FakeCLIRunner(stdout: Data("Error: unknown command".utf8))
        let unreadable = await WorkbenchCLI(runner: prose).escalateQuestion(projectID: 1, sessionID: 2, at: "x", reason: .away)
        XCTAssertEqual(unreadable.errorCode, .internal)
        guard case .failed = unreadable.verdict else { return XCTFail("unparsable stdout is not retried") }
    }

    /// A binary that could not be started ran nothing: retried.
    func testEscalateQuestionLaunchFailureIsRetried() async {
        struct NoExecBit: LocalizedError { var errorDescription: String? { "no exec bit" } }
        let runner = FakeCLIRunner(error: CLIRunnerError.launchFailed(underlying: NoExecBit()))
        let result = await WorkbenchCLI(runner: runner).escalateQuestion(projectID: 1, sessionID: 2, at: "x", reason: .left)
        XCTAssertEqual(result.errorCode, .launchFailed)
        XCTAssertEqual(result.verdict, .transient("launch failed: no exec bit"))
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

    /// A removal refused through a link leaving the folder: the delete still
    /// completes, and the warning names the file and what to remove by hand
    /// instead of the raw error (PROJ-02's exception, ask #118).
    func testDeleteWarningNamesTheFileLinkedOutside() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"""
        {"id":3,"deleted":true,"removal_ok":false,"removal_error":"",\#
        "removal_hints":["Watchtower's hooks stay in /tmp/a/settings.json — remove the entries marked watchtower by hand"],\#
        "files_ok":true,"files_error":""}
        """#.utf8))
        let result = try await WorkbenchCLI(runner: runner).delete(projectID: 3)
        XCTAssertEqual(result.removalHints,
                       ["Watchtower's hooks stay in /tmp/a/settings.json — remove the entries marked watchtower by hand"])
        XCTAssertEqual(
            result.cleanupWarning,
            "The workbench was deleted, but Watchtower could not clean a file linked outside its folder. "
                + "Watchtower's hooks stay in /tmp/a/settings.json — remove the entries marked watchtower by hand."
        )
    }

    /// Hints never hide another cleanup failure: Go's removal_error carries
    /// whatever the hints do not name, and the warning shows both.
    func testDeleteWarningKeepsAnUnrelatedFailureBesideTheHints() {
        let deleted = WorkbenchDeleted(
            id: 3, deleted: true, removalOK: false, removalError: "unregistering the MCP server failed",
            removalHints: ["Watchtower's hooks stay in /tmp/a/settings.json — remove the entries marked watchtower by hand"],
            filesOK: true, filesError: ""
        )
        XCTAssertEqual(
            deleted.cleanupWarning,
            "The workbench was deleted, but Watchtower could not clean a file linked outside its folder. "
                + "Watchtower's hooks stay in /tmp/a/settings.json — remove the entries marked watchtower by hand.; "
                + "cleaning its folder failed: unregistering the MCP server failed"
        )
    }

    /// `kept_worktrees` (board #229): worktrees with work in them that the
    /// delete left on disk; an envelope without the key keeps none.
    func testDeleteDecodesKeptWorktrees() async throws {
        let runner = FakeCLIRunner(stdout: Data(
            #"{"id":3,"deleted":true,"removal_ok":true,"removal_error":"","kept_worktrees":["/tmp/a/wt1","/tmp/a/wt2"]}"#.utf8
        ))
        let result = try await WorkbenchCLI(runner: runner).delete(projectID: 3)
        XCTAssertEqual(result.keptWorktrees, ["/tmp/a/wt1", "/tmp/a/wt2"])
        XCTAssertEqual(result.keptWorktreesNotice, "Kept 2 worktrees with work in them: /tmp/a/wt1, /tmp/a/wt2")
        XCTAssertEqual(
            WorkbenchDeleted(id: 3, deleted: true, removalOK: true, removalError: "", keptWorktrees: ["/tmp/a/wt1"])
                .keptWorktreesNotice,
            "Kept 1 worktree with work in it: /tmp/a/wt1"
        )
        let bare = try JSONDecoder().decode(
            WorkbenchDeleted.self, from: Data(#"{"id":3,"deleted":true,"removal_ok":true,"removal_error":""}"#.utf8)
        )
        XCTAssertEqual(bare.keptWorktrees, [])
        XCTAssertNil(bare.keptWorktreesNotice)
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
    /// present, only the new skill reads `missing`. The CLI no longer serves
    /// the old `project …` commands those hooks call, so the folder needs
    /// Repair (which runs the migrating resync). An older CLI's JSON has no
    /// legacy keys.
    func testLegacyFolderStatus() throws {
        let legacy = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(#"""
            {"project_id":1,"folder":"/tmp/acme","skill":"missing","skill_path":"","hook":true,"stop_hook":true,
             "mcp":true,"claude_found":true,"legacy":true,"legacy_skill":"unchanged"}
            """#.utf8))
        XCTAssertTrue(legacy.legacy)
        XCTAssertEqual(legacy.legacySkill, "unchanged")
        XCTAssertTrue(legacy.needsRepair, "a legacy folder's hooks call commands that are gone")
        XCTAssertTrue(legacy.claudeNeedsRepair)
        XCTAssertTrue(legacy.repairHelp.contains("Skill missing"), legacy.repairHelp)
        XCTAssertTrue(legacy.repairHelp.contains("Set up under the old Projects name — Repair install migrates it"),
                      legacy.repairHelp)

        let older = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(
            #"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        XCTAssertFalse(older.legacy)
        XCTAssertEqual(older.legacySkill, "")
        XCTAssertFalse(older.needsRepair)
        XCTAssertFalse(older.repairHelp.contains("old Projects name"), older.repairHelp)

        // A resync whose `mcp add` failed: the new skill is in, only the old
        // registration serves it. The skill names tools the session lacks,
        // so Repair (which re-runs the add) is offered.
        let mixed = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(#"""
            {"skill":"unchanged","hook":true,"stop_hook":true,"mcp":true,"claude_found":true,
             "legacy":true,"legacy_skill":"","current_mcp":false}
            """#.utf8))
        XCTAssertEqual(mixed.currentMCP, false)
        XCTAssertTrue(mixed.needsRepair)
        XCTAssertFalse(WorkbenchInstallStatus(skill: "unchanged", hook: true, mcp: true, currentMCP: true).needsRepair)
        XCTAssertFalse(WorkbenchInstallStatus(skill: "unchanged", hook: true, mcp: false, claudeFound: false,
                                              currentMCP: false).needsRepair,
                       "without claude the registration is not repairable from here")
    }

    /// An older CLI sends no `current_mcp`: the decision falls back to `mcp`.
    func testStatusWithoutCurrentMCPKeepsTheOldRule() throws {
        let older = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(
            #"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        XCTAssertEqual(older.currentMCP, older.mcp)
        XCTAssertFalse(older.needsRepair)
        let unregistered = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(
            #"{"skill":"unchanged","hook":true,"mcp":false}"#.utf8))
        XCTAssertEqual(unregistered.currentMCP, unregistered.mcp)
        XCTAssertTrue(unregistered.needsRepair)
    }

    /// Every legacy folder needs Repair, whatever else it has — including
    /// one whose new skill is already in (the migration left old hooks or
    /// the old registration). A folder that is not legacy and lacks the new
    /// skill needs it too.
    func testLegacyFolderStillRepairsWhatIsBroken() {
        XCTAssertTrue(WorkbenchInstallStatus(skill: "missing", hook: false, mcp: true, legacy: true, legacySkill: "unchanged").needsRepair)
        XCTAssertTrue(WorkbenchInstallStatus(skill: "missing", hook: true, mcp: true, legacy: true).needsRepair,
                      "no skill in either vocabulary")
        XCTAssertTrue(WorkbenchInstallStatus(skill: "unchanged", hook: true, mcp: true, legacy: true).needsRepair,
                      "old hooks or registration left behind")
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

    // MARK: - workbench worktree

    func testWorktreeCreateEnsureForgetArgumentsAndDecoding() async throws {
        let runner = ScriptedCLIRunner(results: [
            .success(Data(#"{"workbench_id":3,"created":true,"path":"/tmp/acme/wt","cwd":"/tmp/acme/wt/app","branch":"wt/a","base":"abc"}"#.utf8)),
            .success(Data(#"{"workbench_id":3,"created":false,"path":"/tmp/acme/wt","branch":"wt/a","refused":"unborn"}"#.utf8)),
            .success(Data(#"{"workbench_id":3,"forgot":true}"#.utf8))
        ])
        let cli = WorkbenchCLI(runner: runner)
        let created = try await cli.worktreeCreate(projectID: 3, name: "a")
        let ensured = try await cli.worktreeEnsure(projectID: 3, path: "/tmp/acme/wt", branch: "wt/a")
        let forgot = try await cli.worktreeForget(projectID: 3, path: "/tmp/acme/wt")
        XCTAssertEqual(runner.invocations, [
            ["workbench", "worktree", "create", "--workbench", "3", "--name", "a", "--json"],
            ["workbench", "worktree", "ensure", "--workbench", "3", "--path", "/tmp/acme/wt", "--branch", "wt/a", "--json"],
            ["workbench", "worktree", "forget", "--workbench", "3", "--path", "/tmp/acme/wt", "--json"]
        ])
        XCTAssertTrue(created.created)
        XCTAssertEqual(created.cwd, "/tmp/acme/wt/app")
        XCTAssertEqual(ensured.refused, "unborn")
        XCTAssertTrue(forgot.forgot)
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

    /// Board #565: `--folder` only when asked about a session's folder; the
    /// main folder's argv is unchanged.
    func testGitStatusPassesFolderOnlyForAWorktree() async throws {
        let worktree = "/tmp/acme/.claude/worktrees/mobile-a"
        let envelope = #"""
            {"git":true,"branch":"feature/x","folder_requested":"\#(worktree)","folder_scope":"worktree",
             "folder_root":"\#(worktree)","worktree_name":"mobile-a"}
            """#
        let runner = FakeCLIRunner(stdout: Data(envelope.utf8))
        let cli = WorkbenchCLI(runner: runner)
        _ = try await cli.gitStatus(projectID: 3)
        let status = try await cli.gitStatus(projectID: 3, folder: worktree)
        XCTAssertEqual(runner.invocations, [
            ["workbench", "git", "status", "--workbench", "3", "--json"],
            ["workbench", "git", "status", "--workbench", "3", "--folder", worktree, "--json"]
        ])
        XCTAssertEqual(status.folderScope, .worktree)
        XCTAssertEqual(status.worktreeName, "mobile-a")
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

    // MARK: - Codex part (board #399)

    private func status(_ codex: String?) throws -> WorkbenchInstallStatus {
        let codexKey = codex.map { #","codex":\#($0)"# } ?? ""
        let json = #"{"skill":"unchanged","hook":true,"mcp":true,"claude_found":true"# + codexKey + "}"
        return try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data(json.utf8))
    }

    /// A CLI older than Codex support sends no `codex` key: the status still
    /// decodes, nothing about Codex needs repair, and Codex reads as absent.
    func testInstallStatusDecodesWithoutCodexKey() throws {
        let older = try status(nil)
        XCTAssertNil(older.codex)
        XCTAssertFalse(older.needsRepair)
        XCTAssertFalse(older.codexNeedsRepair)
        XCTAssertTrue(older.agentFound(.claude))
        XCTAssertFalse(older.agentFound(.codex), "no codex part, no codex launch-args")
        XCTAssertFalse(older.repairHelp.contains("Codex"))

        let current = try status(#"{"found":true,"skill":true,"hooks_trusted":true,"imported_duplicates":false}"#)
        XCTAssertEqual(current.codex, .init(found: true, skill: true, hooksTrusted: true))
        XCTAssertTrue(current.agentFound(.codex))
        XCTAssertFalse(current.needsRepair)
        XCTAssertTrue(current.repairHelp.contains("Codex: skill on · hooks trusted"), current.repairHelp)
    }

    func testNeedsRepairWhenCodexUntrustedOrSkillMissing() throws {
        let untrusted = try status(#"{"found":true,"skill":true,"hooks_trusted":false,"imported_duplicates":false}"#)
        XCTAssertTrue(untrusted.needsRepair)
        XCTAssertTrue(untrusted.codexNeedsRepair)
        XCTAssertFalse(untrusted.claudeNeedsRepair, "the Claude Code part is whole")
        XCTAssertTrue(untrusted.repairHelp.contains("hooks not trusted"))

        XCTAssertEqual(untrusted.codex?.state, .broken)

        // Never set up: a neutral "Set up Codex", not Repair (controller ruling).
        let noSkill = try status(#"{"found":true,"skill":false,"hooks_trusted":false,"imported_duplicates":true}"#)
        XCTAssertEqual(noSkill.codex?.state, .notSetUp)
        XCTAssertFalse(noSkill.needsRepair, "no orange icon for a part never set up")
        XCTAssertFalse(noSkill.codexNeedsRepair)
        XCTAssertTrue(noSkill.codexNeedsSetup)
        XCTAssertTrue(noSkill.repairHelp.contains("Codex: not set up"), noSkill.repairHelp)

        let duplicates = try status(#"{"found":true,"skill":true,"hooks_trusted":true,"imported_duplicates":true}"#)
        XCTAssertTrue(duplicates.codexNeedsRepair)
        XCTAssertTrue(duplicates.repairHelp.contains("imported duplicate hooks"))

        // Without codex nothing is offered, whatever the rest says.
        let missing = try status(#"{"found":false,"skill":false,"hooks_trusted":null,"imported_duplicates":true}"#)
        XCTAssertFalse(missing.needsRepair)
        XCTAssertFalse(missing.codexNeedsSetup)
        XCTAssertEqual(missing.codex?.state, .absent)
        XCTAssertFalse(missing.agentFound(.codex))
        XCTAssertFalse(missing.repairHelp.contains("Codex"), "D5: quiet without codex")
    }

    /// Spec §4.5: `hooks_trusted: null` (codex could not be asked) shows no
    /// Repair; only a log line.
    func testNoRepairWhenTrustUnknown() throws {
        let unknown = try status(#"{"found":true,"skill":true,"hooks_trusted":null,"imported_duplicates":false}"#)
        XCTAssertNil(unknown.codex?.hooksTrusted)
        XCTAssertFalse(unknown.needsRepair)
        XCTAssertTrue(unknown.repairHelp.contains("trust unknown"))
    }

    /// An outdated skill copy is set up and broken (Repair), never the
    /// neutral "not set up"; an older CLI without `skill_state` keeps its
    /// reading.
    func testOutdatedCodexSkillIsRepair() throws {
        let outdated = try status(#"{"found":true,"skill":true,"skill_state":"updated","hooks_trusted":true,"imported_duplicates":false}"#)
        XCTAssertEqual(outdated.codex?.state, .broken)
        XCTAssertTrue(outdated.codexNeedsRepair)
        XCTAssertFalse(outdated.codexNeedsSetup)
        XCTAssertTrue(outdated.repairHelp.contains("Codex: skill outdated"), outdated.repairHelp)

        let edited = try status(#"{"found":true,"skill":true,"skill_state":"drifted","hooks_trusted":true,"imported_duplicates":false}"#)
        XCTAssertEqual(edited.codex?.state, .ready, "an owner-edited copy is theirs")

        let older = try status(#"{"found":true,"skill":true,"hooks_trusted":true,"imported_duplicates":false}"#)
        XCTAssertNil(older.codex?.skillState)
        XCTAssertEqual(older.codex?.state, .ready)
    }

    /// The CLI's `trust_error` reaches the tooltip — also when the config
    /// did not load and codex reads as not found — and an older CLI without
    /// the key decodes as nil.
    func testTrustErrorShowsInTheHelp() throws {
        let failed = try status(#"{"found":true,"skill":true,"hooks_trusted":null,"imported_duplicates":false,"#
            + #""trust_error":"codex hook trust unavailable: no answer within 10s"}"#)
        XCTAssertEqual(failed.codex?.trustError, "codex hook trust unavailable: no answer within 10s")
        XCTAssertFalse(failed.needsRepair)
        XCTAssertTrue(failed.repairHelp.contains("Codex trust check failed: codex hook trust unavailable"), failed.repairHelp)

        let unresolved = try status(#"{"found":false,"skill":true,"hooks_trusted":null,"imported_duplicates":false,"#
            + #""trust_error":"could not resolve the codex binary: loading config: bad"}"#)
        XCTAssertEqual(unresolved.codex?.state, .absent)
        XCTAssertTrue(unresolved.repairHelp.contains("loading config: bad"), unresolved.repairHelp)

        let older = try status(#"{"found":true,"skill":true,"hooks_trusted":true,"imported_duplicates":false}"#)
        XCTAssertNil(older.codex?.trustError)
        XCTAssertFalse(older.repairHelp.contains("trust check failed"))
    }

    /// The header's Codex control: only for a part never set up; neutral,
    /// orange only after a failed setup; nothing for absent, whole or broken
    /// parts (broken is Repair's orange icon).
    func testCodexNotSetUpIsANeutralNoticeUntilASetupFails() throws {
        let notSetUp = try status(#"{"found":true,"skill":false,"hooks_trusted":null,"imported_duplicates":false}"#)
        let neutral = try XCTUnwrap(notSetUp.codexSetupNotice(failure: nil))
        XCTAssertEqual(neutral.title, "Codex: not set up")
        XCTAssertFalse(neutral.isWarning)
        XCTAssertTrue(neutral.help.contains("Set up Codex"))

        let failed = try XCTUnwrap(notSetUp.codexSetupNotice(failure: "Setting up Codex failed: timed out"))
        XCTAssertEqual(failed.title, "Codex setup failed")
        XCTAssertTrue(failed.isWarning)
        XCTAssertTrue(failed.help.hasPrefix("Setting up Codex failed: timed out"))

        for codex in [nil, #"{"found":false,"skill":false,"hooks_trusted":null,"imported_duplicates":false}"#,
                      #"{"found":true,"skill":true,"hooks_trusted":true,"imported_duplicates":false}"#,
                      #"{"found":true,"skill":true,"hooks_trusted":false,"imported_duplicates":false}"#] {
            XCTAssertNil(try status(codex).codexSetupNotice(failure: "x"), codex ?? "no codex key")
        }
    }

    func testInstallCodexArguments() async throws {
        let runner = FakeCLIRunner()
        try await WorkbenchCLI(runner: runner).installCodex(projectID: 7)
        XCTAssertEqual(runner.invocations, [["integrate", "codex", "--workbench", "7"]])
    }

    private func resynced(_ codex: String?) throws -> WorkbenchResynced {
        let codexKey = codex.map { #","codex":\#($0)"# } ?? ""
        let json = #"{"integration_ok":true,"integration_error":"","skill":"unchanged","hooks_added":false,"excluded":[],"#
            + #""mcp_registered":true,"mcp_command":"","suggestions":[],"suggestions_error":""\#(codexKey)}"#
        return try JSONDecoder().decode(WorkbenchResynced.self, from: Data(json.utf8))
    }

    /// Re-run Setup's Codex lines; a failed Codex step is its own problem
    /// line and leaves the Claude Code part's lines alone.
    func testResyncSummaryReportsTheCodexPart() throws {
        XCTAssertEqual(try resynced(nil).summaryLines.map(\.text), ["Everything was already up to date."])

        let installed = try resynced(
            #"{"ok":true,"error":"","found":true,"skill":"installed","hooks_trusted":true,"duplicates_removed":true}"#
        )
        XCTAssertEqual(installed.summaryLines, [
            .init(text: "Installed the watchtower-workbench skill for Codex", problem: false),
            .init(text: "Removed the Watchtower hooks Codex had imported into .codex", problem: false)
        ])

        let failed = try resynced(
            #"{"ok":false,"error":"codex app-server timed out","found":true,"skill":"unchanged","hooks_trusted":null,"#
                + #""duplicates_removed":false}"#
        )
        XCTAssertEqual(failed.summaryLines, [.init(text: "Setting up Codex failed: codex app-server timed out", problem: true)])
        XCTAssertTrue(failed.integrationOK, "the Claude Code part did not fail")

        let untrusted = try resynced(
            #"{"ok":true,"error":"","found":true,"skill":"unchanged","hooks_trusted":false,"duplicates_removed":false}"#
        )
        XCTAssertEqual(untrusted.summaryLines.map(\.problem), [true])
    }

    func testMethodologyCallsPassTheFlagsAndJSON() async throws {
        let runner = FakeCLIRunner(stdout: Data(WorkbenchMethodologyFixtures.envelope.utf8))
        let cli = WorkbenchCLI(runner: runner)
        let read = try await cli.methodology(projectID: 7)
        _ = try await cli.setMethodology(projectID: 7, key: .askGuard, choice: "soft")
        _ = try await cli.setMethodology(projectID: 7, key: .preset, choice: WorkbenchMethodologyKey.fromFile)
        _ = try await cli.createWorkflowFile(projectID: 7)
        XCTAssertEqual(read.effective.askGuard, "soft")
        XCTAssertEqual(runner.invocations, [
            ["workbench", "methodology", "7", "--json"],
            ["workbench", "methodology", "7", "--ask-guard=soft", "--json"],
            ["workbench", "methodology", "7", "--preset=file", "--json"],
            ["workbench", "methodology", "7", "--create-file", "--json"]
        ])
    }
}
