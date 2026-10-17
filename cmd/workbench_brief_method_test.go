package cmd

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/workbenchcheck"
	"watchtower/internal/workbenchmethod"
)

func methodFile(body string) workbenchmethod.File {
	return workbenchmethod.File{Present: true, Body: body, BodyChars: utf8.RuneCountInString(body)}
}

// Spec 2026-10-15 §6: the folder rules after the board rules, inline, and
// the Checks line naming each check that is not at its default.
func TestRenderSessionBrief_GoldenFolderRules(t *testing.T) {
	f := methodFile("Plans live in docs/plans/.")
	f.FinishCheck = workbenchmethod.FinishOff
	e := workbenchmethod.Combine(db.WorkbenchMethodology{AskGuard: workbenchmethod.AskGuardSoft}, f)
	board := []db.BoardNode{briefNode(3, "in_progress", "active feature")}

	out := renderSessionBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), briefRules,
		briefMethodSection(e, ""), "", "")

	assert.Equal(t, briefGoldenFolderRules, out)
}

const briefGoldenFolderRules = `Watchtower workbench #7 "acme" — /tmp/acme
Targets: 1 in progress, 0 in review, 0 blocked, 0 todo, 0 done. New comments for you: 0.
Board language: follow the session language (write targets, intents and comments in the language the owner uses with you).
Open targets:
- #3 [in_progress, medium, 0%] active feature
New comments for you: none.
Board rules: set a target in_progress (update_target) before you work on it, in_review when its review starts and done once the review passes; a short clarification may be asked in plain text while the owner is in the session; anything else that waits on the owner (a decision, a check, a review) is an ask_owner call — several decisions in one ask — never a comment, and you keep working; comments are for blockers and done summaries.
Folder rules (.watchtower/workflow.md — the owner's rules for this folder; they win over the watchtower-flow preset):
Plans live in docs/plans/.
Checks: ask guard soft (personal), finish check off (folder file).`

func TestBriefMethodSection_Lines(t *testing.T) {
	long := strings.Repeat("r", briefFolderRulesInline+1)
	cut := methodFile(long)
	cut.Truncated = true
	for _, tc := range []struct {
		name string
		e    workbenchmethod.Effective
		want string
	}{
		{"no file, defaults", workbenchmethod.Defaults(), ""},
		{"an empty body", workbenchmethod.Combine(db.WorkbenchMethodology{}, workbenchmethod.File{Present: true}), ""},
		{"a long body", workbenchmethod.Combine(db.WorkbenchMethodology{}, methodFile(long)),
			"Folder rules: .watchtower/workflow.md (1201 chars) — read it before you start working."},
		{"a cut file", workbenchmethod.Combine(db.WorkbenchMethodology{}, cut),
			"Folder rules: .watchtower/workflow.md (1201 chars, cut at 64 KiB) — read it before you start working."},
		{"a broken file", workbenchmethod.Combine(db.WorkbenchMethodology{},
			workbenchmethod.File{Present: true, Err: errors.New(`line 2: unknown key "mode"`)}),
			`Folder rules: .watchtower/workflow.md was ignored: line 2: unknown key "mode". Built-in defaults apply.`},
		{"finish check off only", workbenchmethod.Combine(db.WorkbenchMethodology{FinishCheck: workbenchmethod.FinishOff}, workbenchmethod.File{}),
			"Checks: finish check off (personal)."},
	} {
		assert.Equal(t, tc.want, briefMethodSection(tc.e, ""), tc.name)
	}
}

// The slot never passes 1400 runes and never pushes the brief past 4000;
// the board never cuts it. Runes, not bytes: the body is Cyrillic.
func TestBriefMethodSection_CapsHold(t *testing.T) {
	body := strings.Repeat("я", briefFolderRulesInline)
	e := workbenchmethod.Combine(db.WorkbenchMethodology{AskGuard: workbenchmethod.AskGuardOff, FinishCheck: workbenchmethod.FinishOff},
		methodFile(body))
	section := briefMethodSection(e, "")
	assert.LessOrEqual(t, utf8.RuneCountInString(section), briefMethodChars)
	assert.Contains(t, section, body, "1200 runes and the Checks line fit inline")

	var board []db.BoardNode
	for i := 1; i <= 200; i++ {
		board = append(board, briefNode(i, "todo", strings.Repeat("Implement the next part of the plan ", 8)))
	}
	out := renderSessionBrief(board, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), briefRules,
		section, "Cleanup: /usr/local/bin/watchtower workbench cleanup --session 3", "")
	assert.LessOrEqual(t, utf8.RuneCountInString(out), briefMaxChars)
	assert.Contains(t, out, body, "the board never cuts the folder rules")
	assert.Contains(t, out, "more targets (workbench_board)", "the board is what gives way")
}

// Spec §5: the brief reads the session's own folder — a session worktree's
// copy — and the workbench folder outside a Desktop row.
func TestWorkbenchBrief_FolderRulesFromTheSessionsFolder(t *testing.T) {
	database := writeActionsConfig(t)
	main, worktree := t.TempDir(), t.TempDir()
	pid, err := database.CreateWorkbench("acme", main)
	require.NoError(t, err)
	for folder, rules := range map[string]string{main: "Main folder rules.", worktree: "Worktree rules."} {
		require.NoError(t, os.MkdirAll(filepath.Join(folder, ".watchtower"), 0o755))
		require.NoError(t, os.WriteFile(filepath.Join(folder, workbenchmethod.FileRel), []byte(rules), 0o644))
	}
	unsetTerminalEnv(t)
	out, _ := runBriefHook(t, pid, "")
	assert.Contains(t, out, "Main folder rules.")

	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id) VALUES (?, 'claude', 's', ?, 'sess-1')`, pid, worktree)
	require.NoError(t, err)
	row, err := res.LastInsertId()
	require.NoError(t, err)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	out, _ = runBriefHook(t, pid, "")
	assert.Contains(t, out, "Worktree rules.")
	assert.NotContains(t, out, "Main folder rules.")
}

// The mismatch line shares the 1400-rune slot: with it, a 1200-rune body
// no longer fits inline and becomes the pointer.
func TestBriefMethodSection_MismatchStaysWithinTheSlot(t *testing.T) {
	body := strings.Repeat("я", briefFolderRulesInline)
	e := workbenchmethod.Combine(db.WorkbenchMethodology{AskGuard: workbenchmethod.AskGuardOff, FinishCheck: workbenchmethod.FinishOff},
		methodFile(body))
	const mismatch = "Methodology preset: none is set, but watchtower-flow is still installed — run 'watchtower workbench resync 7'."

	section := briefMethodSection(e, mismatch)

	assert.LessOrEqual(t, utf8.RuneCountInString(section), briefMethodChars)
	assert.Contains(t, section, mismatch)
	assert.Contains(t, section, "Folder rules: .watchtower/workflow.md (1200 chars) — read it before you start working.")
}

// The kept-preset line (preset none beside an owner-edited watchtower-flow)
// shares the slot the same way.
func TestBriefMethodSection_KeptPresetLineStaysWithinTheSlot(t *testing.T) {
	folder := t.TempDir()
	_, core := devpack.WorkbenchSkill()
	_, flow := devpack.FlowSkill()
	require.NoError(t, os.MkdirAll(filepath.Dir(coreFileIn(folder)), 0o755))
	require.NoError(t, os.WriteFile(coreFileIn(folder), core, 0o644))
	require.NoError(t, os.MkdirAll(filepath.Dir(flowFileIn(folder)), 0o755))
	require.NoError(t, os.WriteFile(flowFileIn(folder), append(flow, []byte("\nMine.\n")...), 0o644))
	e := workbenchmethod.Combine(db.WorkbenchMethodology{Preset: workbenchmethod.PresetNone, AskGuard: workbenchmethod.AskGuardOff,
		FinishCheck: workbenchmethod.FinishOff}, methodFile(strings.Repeat("я", briefFolderRulesInline)))
	mismatch := briefPresetMismatch(e, folder, 7)
	require.Contains(t, mismatch, "your edited watchtower-flow skill is kept")

	section := briefMethodSection(e, mismatch)

	assert.LessOrEqual(t, utf8.RuneCountInString(section), briefMethodChars)
	assert.Contains(t, section, mismatch)
	assert.Contains(t, section, "Folder rules: .watchtower/workflow.md (1200 chars) — read it before you start working.")
}

// F15: with the preset none the fixed board rules drop the review step and
// the comment convention (watchtower-flow's), keeping the status, ask_owner
// and plain-text question clauses; watchtower-flow keeps today's sentence.
func TestBriefRulesFor_PresetNoneDropsTheMethodologyClauses(t *testing.T) {
	assert.Equal(t, briefRules, briefRulesFor(workbenchmethod.PresetFlow))
	rules := strings.Join(briefRulesFor(workbenchmethod.PresetNone), "\n")
	for _, kept := range []string{"in_progress (update_target)", "done", "ask_owner", "plain text"} {
		assert.Contains(t, rules, kept)
	}
	for _, dropped := range []string{"in_review", "comments are for blockers and done summaries"} {
		assert.NotContains(t, rules, dropped)
	}

	out := renderSessionBrief(nil, briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(),
		briefRulesFor(workbenchmethod.PresetNone), "", "", "")
	assert.True(t, strings.HasSuffix(out, rules))
	assert.NotContains(t, out, "in_review")
}

// F15 through the hook: the owner's preset none reaches the brief's rules.
func TestWorkbenchBrief_PresetNoneRules(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	unsetTerminalEnv(t)
	out, _ := runBriefHook(t, pid, "")
	assert.Contains(t, out, briefRules[0])

	require.NoError(t, database.SetWorkbenchMethodology(pid, db.WorkbenchMethodology{Preset: workbenchmethod.PresetNone}))
	out, _ = runBriefHook(t, pid, "")
	assert.Contains(t, out, briefRulesNoPreset[0])
	assert.NotContains(t, out, "in_review")
}
