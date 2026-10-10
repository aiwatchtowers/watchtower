# Work on It for a group — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start (or reopen) a Claude Code session on a group target from the side panel, the Kanban lane header, the List row and the context menu, with a group-specific first prompt that the workbench skill knows how to work.

**Architecture:** The Desktop picks the first prompt when it creates a target session: `Work on group #<id> …` when the target has sub-targets, `Work on target #<id> …` otherwise. Session lookup stays an exact `target_id` match. The skill pack gains "Working a target" and "Working a group" sections. No Go code or schema changes: `internal/sessionreport` already walks the session target's subtree (pinned by `TestBuild_NowNextAndNestedParent`, a session on group 257 → progress 1/7).

**Tech Stack:** SwiftUI + GRDB (WatchtowerDesktop, `WatchtowerCore`), Go embed (skill pack).

**Spec:** `docs/superpowers/specs/2026-10-08-workbench-group-work-on-design.md` (approved 2026-10-08, ask #130, both recommended decisions).

## Global Constraints

- The first prompt is a fixed string naming only the number and the skill; the target's text never reaches argv or the prompt; it travels in `WATCHTOWER_FIRST_PROMPT` as today.
- Group prompt, exact: `Work on group #<id> using the <skill> skill.` where `<skill>` is `WorkbenchVocabulary.skillName` (`watchtower-workbench`, or legacy `watchtower-project`).
- A group's session gets its own row even when sub-tasks have sessions; lookup stays `TerminalSessionPolicy.sessionForTarget` (exact match). (Spec decision 1.)
- Button labels in a group are the task's: **Work on It** / **Open Its Session**. (Spec decision 2.)
- UI strings English only. Board/ask text Russian; repo text English.
- Inner loop only: `make test-swift FILTER=…`, `go test ./internal/devpack`, `make lint-diff`. No full suites per task.

## Review Focus

1. A target that had a task session and later gained sub-targets: Work on It reopens that session, no new row, no new prompt — test in Task 1.
2. A phone start (`startForTarget`, `prompt: nil`) on a group gets the group prompt, with `planFirstSuffix` appended when asked — test in Task 1.
3. Sub-targets that sit in another workbench (should not happen, but `parent_id` does not enforce it) must not turn a target into a group — the child check filters by `project_id` — test in Task 1.
4. The lane-header button's click must not also select or enter the lane (header has tap + double-tap gestures) — manual check in Task 2's hand-back notes.
5. Legacy vocabulary folder gets `watchtower-project` in the group prompt — test in Task 1.

---

### Task 1: Group first prompt and its choice at session creation

Depends on: none.

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/TerminalLaunch.swift:88-90`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TargetQueries.swift` (new `hasChildren`)
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Sessions.swift` (`startTarget`, `TargetSessions`, `readTargetSessions`)
- Test: `WatchtowerDesktop/Tests/Core/TerminalLaunchTests.swift`, `WatchtowerDesktop/Tests/WorkbenchesViewModelSessionsTests.swift`
- Docs: `docs/features/workbench.md` (the Work on it paragraph in the long bullet at :7)

**Interfaces:**
- Produces: `TerminalLaunch.workOnGroupPrompt(targetID: Int64, vocabulary: WorkbenchVocabulary) -> String`;
  `TerminalLaunch.workOnPrompt(targetID: Int64, isGroup: Bool, vocabulary: WorkbenchVocabulary) -> String`;
  `TargetQueries.hasChildren(_ db: Database, id: Int64, workbenchID: Int64) throws -> Bool`.

- [ ] **Step 1: Failing Core tests** — extend `testPromptsNameTheFoldersSkill` and `testFixedPromptsHoldNoQuote`:

```swift
XCTAssertEqual(TerminalLaunch.workOnGroupPrompt(targetID: 7, vocabulary: .current),
               "Work on group #7 using the watchtower-workbench skill.")
XCTAssertEqual(TerminalLaunch.workOnGroupPrompt(targetID: 7, vocabulary: .legacy),
               "Work on group #7 using the watchtower-project skill.")
XCTAssertEqual(TerminalLaunch.workOnPrompt(targetID: 7, isGroup: true, vocabulary: .current),
               TerminalLaunch.workOnGroupPrompt(targetID: 7, vocabulary: .current))
XCTAssertEqual(TerminalLaunch.workOnPrompt(targetID: 7, isGroup: false, vocabulary: .current),
               TerminalLaunch.workOnTargetPrompt(targetID: 7, vocabulary: .current))
```

and add `TerminalLaunch.workOnGroupPrompt(targetID: 7, vocabulary: vocabulary)` to the control-character loop and the no-quote loop.

- [ ] **Step 2:** `make test-swift FILTER=TerminalLaunchTests` → FAIL (no such member).

- [ ] **Step 3: Implement** in `TerminalLaunch.swift` next to `workOnTargetPrompt`:

```swift
/// "Work on it" on a target with sub-targets (spec 2026-10-08): the skill's
/// "Working a group" section keys on this wording.
package static func workOnGroupPrompt(targetID: Int64, vocabulary: WorkbenchVocabulary) -> String {
    "Work on group #\(targetID) using the \(vocabulary.skillName) skill."
}

package static func workOnPrompt(targetID: Int64, isGroup: Bool, vocabulary: WorkbenchVocabulary) -> String {
    isGroup ? workOnGroupPrompt(targetID: targetID, vocabulary: vocabulary)
        : workOnTargetPrompt(targetID: targetID, vocabulary: vocabulary)
}
```

- [ ] **Step 4:** `make test-swift FILTER=TerminalLaunchTests` → PASS.

- [ ] **Step 5: Failing VM tests** in `WorkbenchesViewModelSessionsTests` (MARK: Work on it), using the existing helpers (`workbenchWithFolder`, `rows`, `launches`, `makeVM`, `insertSession`):

```swift
func testWorkOnAGroupStartsItsOwnSessionWithTheGroupPrompt() async throws {
    let p = try await workbenchWithFolder()
    let (group, child) = try await pool.write { db -> (Int64, Int64) in
        let g = try TestDatabase.insertWorkbenchTarget(db, projectID: p, text: "Group")
        let c = try TestDatabase.insertWorkbenchTarget(db, projectID: p, text: "Leaf", parentID: g)
        return (g, c)
    }
    // A sub-task's own session does not stand in for the group's (spec decision 1).
    _ = try await insertSession(.init(projectID: p, kind: .claude, title: "Leaf", targetID: child,
                                      folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()))
    let vm = makeVM()
    await vm.reload()

    await vm.workOn(targetID: group, targetText: "Group")
    await vm.workOn(targetID: group, targetText: "Group")

    let mine = try await rows(p).filter { $0.targetID == group }
    XCTAssertEqual(mine.count, 1, "the second call reopens the group's session")
    XCTAssertEqual(mine.first?.title, "Group")
    XCTAssertEqual(launches.count, 1)
    XCTAssertEqual(launches.first?.environment.last,
                   "WATCHTOWER_FIRST_PROMPT=\(TerminalLaunch.workOnGroupPrompt(targetID: group, vocabulary: .current))")
}

func testATaskSessionStaysWhenTheTargetLaterBecomesAGroup() async throws {
    let p = try await workbenchWithFolder()
    let target = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: p, text: "Ship it") }
    let vm = makeVM()
    await vm.reload()
    await vm.workOn(targetID: target, targetText: "Ship it")
    _ = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: p, text: "Leaf", parentID: target) }

    await vm.workOn(targetID: target, targetText: "Ship it")

    XCTAssertEqual(try await rows(p).filter { $0.targetID == target }.count, 1)
    XCTAssertEqual(launches.count, 1)
    XCTAssertEqual(launches.first?.environment.last,
                   "WATCHTOWER_FIRST_PROMPT=\(TerminalLaunch.workOnTargetPrompt(targetID: target, vocabulary: .current))")
}

func testAChildInAnotherWorkbenchDoesNotMakeAGroup() async throws {
    let p = try await workbenchWithFolder()
    let other = try await workbenchWithFolder("other")
    let target = try await pool.write { db -> Int64 in
        let t = try TestDatabase.insertWorkbenchTarget(db, projectID: p, text: "Ship it")
        _ = try TestDatabase.insertWorkbenchTarget(db, projectID: other, text: "Stray", parentID: t)
        return t
    }
    let vm = makeVM()
    await vm.reload()
    await vm.workOn(targetID: target, targetText: "Ship it")
    XCTAssertEqual(launches.first?.environment.last,
                   "WATCHTOWER_FIRST_PROMPT=\(TerminalLaunch.workOnTargetPrompt(targetID: target, vocabulary: .current))")
}

func testAPhoneStartOnAGroupGetsTheGroupPromptAndThePlanFirstSuffix() async throws {
    let p = try await workbenchWithFolder()
    let group = try await pool.write { db -> Int64 in
        let g = try TestDatabase.insertWorkbenchTarget(db, projectID: p, text: "Group")
        _ = try TestDatabase.insertWorkbenchTarget(db, projectID: p, text: "Leaf", parentID: g)
        return g
    }
    let vm = makeVM()
    await vm.reload()
    try await vm.startForTarget(targetID: group, prompt: nil, mode: .openExisting, placement: .background, planFirst: true)
    let expected = "\(TerminalLaunch.workOnGroupPrompt(targetID: group, vocabulary: .current)) \(TerminalLaunch.planFirstSuffix)"
    XCTAssertEqual(launches.first?.environment.last, "WATCHTOWER_FIRST_PROMPT=\(expected)")
}
```

Adjust only the call shapes to the real helper signatures (e.g. `insertSession`'s `NewSession` fields, `TargetStartMode` case names, how the existing legacy-vocabulary test sets up a second workbench and the `acme` path); keep every assertion. Add one legacy-vocabulary group assertion by copying the setup of `testWorkOnNamesTheLegacySkillOnceTheStatusSaysSo` with a child under the target and asserting `workOnGroupPrompt(..., vocabulary: .legacy)`.

- [ ] **Step 6:** `make test-swift FILTER=WorkbenchesViewModelSessionsTests` → the new tests FAIL (task prompt sent).

- [ ] **Step 7: Implement.** `TargetQueries`:

```swift
/// Whether a workbench target has sub-targets on the same workbench (a group).
package static func hasChildren(_ db: Database, id: Int64, workbenchID: Int64) throws -> Bool {
    try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM targets WHERE parent_id = ? AND project_id = ?)",
                      arguments: [id, workbenchID]) ?? false
}
```

`WorkbenchesViewModel+Sessions.swift`: widen the tuple and the read, then use it for the prompt:

```swift
typealias TargetSessions = (project: Workbench, targetText: String, isGroup: Bool, rows: [TerminalSession])
// readTargetSessions:
let isGroup = try TargetQueries.hasChildren(db, id: targetID, workbenchID: projectID)
return (project, target.text, isGroup, rows.filter { $0.projectID == projectID })
// startTarget:
let brief = given.flatMap { $0.isEmpty ? nil : $0 } ?? TerminalLaunch.workOnPrompt(
    targetID: targetID, isGroup: found.isGroup, vocabulary: vocabulary(projectID: found.project.id)
)
```

Update the `workOn` doc comment: "…started with the fixed work-on prompt (the group prompt for a target with sub-targets)".

- [ ] **Step 8:** `make test-swift FILTER='WorkbenchesViewModelSessionsTests|TerminalLaunchTests'` → PASS. `make lint-diff` clean.

- [ ] **Step 9: Docs.** In `docs/features/workbench.md`'s Work on it paragraph add: a target with sub-targets on the same workbench starts with `Work on group #<id> using the watchtower-workbench skill.` (`TerminalLaunch.workOnPrompt`, chosen at creation; a reopened session keeps its conversation), the group's session is its own row (exact `target_id` match, sub-task sessions are not reused), the session report already rolls up the subtree.

- [ ] **Step 10: Commit** `feat(desktop): group first prompt for Work on it (#472)`.

### Task 2: Work on It in the group panel, the lane header and the context menu

Depends on: Task 1 (only for a meaningful manual run; the code compiles without it).

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkOnTargetButton.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchTargetPanel.swift:110-122`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchBoardKanbanView.swift` (`WorkbenchBoardKanbanLaneView.summary`)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchBoardCardView.swift:244+` (`WorkbenchTargetMenu`)
- Docs: `docs/superpowers/specs/2026-10-06-workbench-board-hierarchy-design.md`, `docs/app-guide.md` (:290 Work on it, :302 Entering a group), `docs/features/workbench.md` (:31 hierarchy bullet)

**Interfaces:**
- Consumes: `WorkbenchesViewModel.workOn(targetID:targetText:projectID:)` (unchanged signature).
- Produces: `WorkOnTargetButton.hasSession(_ target: Target, in vm: WorkbenchesViewModel?) -> Bool` (static, replaces the private instance method).

- [ ] **Step 1: Share the session check.** In `WorkOnTargetButton` make the check static so the menu can label itself:

```swift
static func hasSession(_ target: Target, in vm: WorkbenchesViewModel?) -> Bool {
    guard let vm, let projectID = target.workbenchID else { return false }
    return TerminalSessionPolicy.sessionForTarget(Int64(target.id), in: vm.terminalSessions[projectID] ?? []) != nil
}
```

and call `Self.hasSession(target, in: vm)` in `body`. Update the help strings to "…for this target" → keep as is (a group is a target).

- [ ] **Step 2: Panel.** Replace the `switch mode` in the header:

```swift
WorkOnTargetButton(target: target, compact: false, isVisible: true)
    .fixedSize()
if mode == .group {
    Button { onOpenGroup(target.id) } label: {
        Label("Open group", systemImage: "arrow.down.right.square")
    }
    .buttonStyle(.bordered)
    .fixedSize()
    .disabled(vm.scopeNode?.target.id == target.id)
    .help("Show only this group on the board")
}
```

If the header row then overflows the minimum panel width, drop the Open group label to icon-only (`Image` + `.accessibilityLabel("Open group")`) rather than truncating Work on It.

- [ ] **Step 3: Lane header.** In `WorkbenchBoardKanbanLaneView.summary`, after the status chip and before `Spacer`, for a lane with a root that has children:

```swift
if let root = lane.root, !root.children.isEmpty {
    WorkOnTargetButton(target: root.target, compact: true, isVisible: true)
}
```

The button sits inside `content`, which carries `.onTapGesture` and a simultaneous double-tap. Verify a click on the button starts the session without selecting/entering the lane; if the gestures still fire, move the button out of `content` into `header`'s `HStack` after `summary` instead (then it is outside the gesture area). Note in the hand-back which placement was used and how it was checked (`make app-dev`, one click and one double-click on the button).

- [ ] **Step 4: Context menu.** `WorkbenchTargetMenu` gains `@Environment(AppState.self) private var appState` and a first item for every target:

```swift
let sessions = appState.workbenchesViewModel
let existing = WorkOnTargetButton.hasSession(target, in: sessions)
Button(existing ? "Open Its Session" : "Work on It") {
    Task { await sessions?.workOn(targetID: Int64(target.id), targetText: target.text, projectID: target.workbenchID) }
}
.disabled(sessions == nil)
Divider()
```

Then the existing Open Group item and the rest. Update the type's doc comment to list Work on It first. Check every `WorkbenchTargetMenu` call site renders inside a view tree that has `AppState` in the environment (the board views already read it via `WorkOnTargetButton`).

- [ ] **Step 5: Build.** `make test-swift FILTER='WorkbenchBoard'` (compiles the target and runs the board tests) → PASS; `make lint-diff` clean.

- [ ] **Step 6: Docs.**
  - Hierarchy spec: under **Decisions**, add "**Amended 2026-10-08 (board #472, spec `2026-10-08-workbench-group-work-on-design.md`):** a group's panel shows **Work on It** as the primary button with **Open group** beside it; Work on It is also on a group lane header and in every target's context menu." and edit the two "Open group replaces Work on It" sentences (≈:43-44 and :140) to say "Work on It, with Open group beside it".
  - `docs/app-guide.md`: Work on it (:290) — works on a group too (panel, lane header, list row, right-click); the agent works the group's sub-tasks in board order or by the plan its description names, skipping blocked and already-running ones. Entering a group (:302) — Open group sits next to Work on It in the panel.
  - `docs/features/workbench.md` hierarchy bullet (:31): group panel = Work on It + Open group; lane header has the compact Work on It; `WorkbenchTargetMenu` starts with Work on It.

- [ ] **Step 7: Commit** `feat(desktop): Work on It for groups in the panel, lane header and menu (#472)`.

### Task 3: Skill — "Working a target" and "Working a group"

Depends on: none (pairs with Task 1's prompt wording, fixed in Global Constraints).

**Files:**
- Modify: `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` (new sections after "Features, specs and plans", before "Asking the owner")
- Test: `internal/devpack/workbench_skill_tools_test.go` (new test)

**Interfaces:**
- Consumes: the prompt wordings `Work on target #<id>` / `Work on group #<id>` (Global Constraints).

- [ ] **Step 1: Failing test:**

```go
// Spec 2026-10-08: the Desktop starts a group's session with "Work on group
// #<id>"; the skill must say what that means, and keep the task wording.
func TestWorkbenchSkill_ExplainsBothWorkOnPrompts(t *testing.T) {
	_, body := devpack.WorkbenchSkill()
	content := string(body)
	for _, want := range []string{
		"## Working a target", "`Work on target #<id>`",
		"## Working a group", "`Work on group #<id>`",
	} {
		if !strings.Contains(content, want) {
			t.Errorf("the skill must contain %q", want)
		}
	}
}
```

- [ ] **Step 2:** `go test ./internal/devpack -run TestWorkbenchSkill` → FAIL.

- [ ] **Step 3: Write the sections** (English, the skill's voice, short):

```markdown
## Working a target

The first prompt `Work on target #<id>` hands you one target. Call `get_target` and `list_comments` with its id, set it `in_progress` with its `branch` in one `update_target`, and work it under the rules above (feature, spec, plan). If it turns out to have sub-targets, work it as a group (below).

## Working a group

The first prompt `Work on group #<id>` hands you a target with sub-targets.

1. Read the subtree: `workbench_board`, then `get_target` and `list_comments` on the group. The group's intent is the brief.
2. If the intent names a plan, run that plan as "Running a plan" says, in the order its dependencies allow.
3. Otherwise take the open leaves in board order — priority, then status, then id. Leaves that do not depend on each other may run in parallel only where the folder's own rules allow parallel work.
4. Skip a leaf that is `blocked`, waits on an open ask, or was already `in_progress` or `in_review` when you started — another session is on it.
5. Set the leaves' statuses, never the group's: it follows its children.
6. When the group's work is done or handed to the owner, call `finish_session` once with `target_id` = the group and a summary of the whole group.
```

- [ ] **Step 4:** `go test ./internal/devpack` → PASS (including `TestWorkbenchSkill_NamesOnlyCurrentToolsAndServer`: the new sections name only existing tools). `make lint-diff` clean.

- [ ] **Step 5: Commit** `feat(devpack): skill sections for Work on target / Work on group (#472)`.

---

## After the tasks (controller)

Gate once: `make test`, `make test-swift`, `make lint-all`; then `local-review` / `debate-review` on the branch, PR, merge on green. The skill's new digest is picked up by the next `integrate`/install (DEV-04 `planFor`); confirm with `watchtower integrate status` in this folder after merge.
