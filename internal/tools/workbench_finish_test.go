package tools

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func linkedTargets(t *testing.T, d *db.DB, sessionID int64) []int64 {
	t.Helper()
	ids, err := d.SessionLinkedTargets(sessionID)
	require.NoError(t, err)
	return ids
}

func countSessionLinks(t *testing.T, d *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM terminal_session_targets`).Scan(&n))
	return n
}

// finishState is a session's finished_at ("" = NULL) and finish_summary.
func finishState(t *testing.T, d *db.DB, sessionID int64) (finishedAt, summary string) {
	t.Helper()
	var at sql.NullString
	require.NoError(t, d.QueryRow(`SELECT finished_at, finish_summary FROM terminal_sessions WHERE id = ?`, sessionID).
		Scan(&at, &summary))
	return at.String, summary
}

func seedOwnerComment(t *testing.T, d *db.DB, projectID, targetID int64) int64 {
	t.Helper()
	id, err := d.AddWorkbenchComment(db.WorkbenchComment{WorkbenchID: projectID,
		TargetID: sql.NullInt64{Int64: targetID, Valid: true}, Author: "owner", Body: "why?"})
	require.NoError(t, err)
	return id
}

func createdIDs(t *testing.T, out map[string]any) []int64 {
	t.Helper()
	created, ok := out["created"].([]any)
	require.True(t, ok, "created %T", out["created"])
	var ids []int64
	for _, c := range created {
		ids = append(ids, int64(c.(map[string]any)["target_id"].(float64)))
	}
	return ids
}

// Spec 2026-10-03-workbench-session-report Part 3: each of the five write
// tools links exactly its targets to the calling session.
func TestSessionLinks_EachWriteToolLinksItsTargets(t *testing.T) {
	for name, call := range map[string]func(t *testing.T, fx workbenchFixture, reg *Registry) []int64{
		"update_target": func(t *testing.T, fx workbenchFixture, reg *Registry) []int64 {
			mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"status":"in_progress","reason":"r"}`, fx.aTarget))
			return []int64{fx.aTarget}
		},
		"create_targets": func(t *testing.T, fx workbenchFixture, reg *Registry) []int64 {
			out := mustApply(t, reg, fx.a, "create_targets",
				`{"items":[{"key":"f","text":"Feature"},{"text":"Task","parent_key":"f"}],"reason":"plan"}`)
			return createdIDs(t, out)
		},
		"add_comment on a target": func(t *testing.T, fx workbenchFixture, reg *Registry) []int64 {
			mustApply(t, reg, fx.a, "add_comment", fmt.Sprintf(`{"target_id":%d,"body":"done","reason":"r"}`, fx.aTarget))
			return []int64{fx.aTarget}
		},
		"add_comment reply links its root's target": func(t *testing.T, fx workbenchFixture, reg *Registry) []int64 {
			other := db.SeedTestWorkbenchTarget(t, fx.d, fx.a, sql.NullInt64{}, "Other")
			root := seedOwnerComment(t, fx.d, fx.a, other)
			reply, err := fx.d.AddWorkbenchComment(db.WorkbenchComment{WorkbenchID: fx.a,
				ParentID: sql.NullInt64{Int64: root, Valid: true}, Author: "owner", Body: "and?"})
			require.NoError(t, err)
			// A reply to the reply still lands on the root's target.
			mustApply(t, reg, fx.a, "add_comment", fmt.Sprintf(`{"parent_id":%d,"body":"answered","reason":"r"}`, reply))
			return []int64{other}
		},
		"ask_owner": func(t *testing.T, fx workbenchFixture, reg *Registry) []int64 {
			mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(`{"kind":"check","title":"Run it","target_id":%d,`+
				`"checklist":[{"text":"Open the app"}],"reason":"r"}`, fx.aTarget))
			return []int64{fx.aTarget}
		},
		"ask_owner without a target": func(t *testing.T, fx workbenchFixture, reg *Registry) []int64 {
			mustApply(t, reg, fx.a, "ask_owner", questionAsk)
			return nil
		},
		"finish_session": func(t *testing.T, fx workbenchFixture, reg *Registry) []int64 {
			mustApply(t, reg, fx.a, "finish_session", fmt.Sprintf(`{"summary":"Done.","target_id":%d,"reason":"r"}`, fx.aTarget))
			return []int64{fx.aTarget}
		},
		"finish_session without a target": func(t *testing.T, fx workbenchFixture, reg *Registry) []int64 {
			mustApply(t, reg, fx.a, "finish_session", `{"summary":"Done.","reason":"r"}`)
			return nil
		},
	} {
		t.Run(name, func(t *testing.T) {
			fx := newWorkbenchFixture(t)
			session := seedTerminalSession(t, fx.d, fx.a)
			want := call(t, fx, askRegistry(t, fx.d, strconv.FormatInt(session, 10)))
			assert.ElementsMatch(t, want, linkedTargets(t, fx.d, session))
			assert.Equal(t, len(want), countSessionLinks(t, fx.d), "no other session gets a row")
		})
	}
}

func TestSessionLinks_ReadToolsLinkNothing(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	callReadIn(t, reg, fx.a, "get_target", fmt.Sprintf(`{"id":%d}`, fx.aTarget))
	callReadIn(t, reg, fx.a, "workbench_board", `{}`)
	callReadIn(t, reg, fx.a, "list_asks", `{"session":"mine"}`)
	callReadIn(t, reg, fx.a, "list_comments", fmt.Sprintf(`{"target_id":%d}`, fx.aTarget))
	assert.Zero(t, countSessionLinks(t, fx.d))
}

// PROJ-14: link rows come only from a session of the same workbench, resolved
// from WATCHTOWER_TERMINAL_SESSION_ID.
func TestProj14_OnlyOwnSessionWritesLink(t *testing.T) {
	fx := newWorkbenchFixture(t)
	theirs := seedTerminalSession(t, fx.d, fx.b)
	for _, env := range []string{"", "999999", "garbage", "-3", strconv.FormatInt(theirs, 10)} {
		reg := askRegistry(t, fx.d, env)
		mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"progress":0.5,"reason":"r"}`, fx.aTarget))
		mustApply(t, reg, fx.a, "add_comment", fmt.Sprintf(`{"target_id":%d,"body":"note","reason":"r"}`, fx.aTarget))
		mustApply(t, reg, fx.a, "create_targets", `{"items":[{"text":"New"}],"reason":"r"}`)
		mustApply(t, reg, fx.a, "ask_owner", fmt.Sprintf(`{"kind":"check","title":"Run it","target_id":%d,`+
			`"checklist":[{"text":"Open the app"}],"reason":"r"}`, fx.aTarget))
		assert.Zero(t, countSessionLinks(t, fx.d), "env %q", env)
	}
}

// PROJ-14: only the session itself says it finished — a call from no session
// of this workbench is refused before anything, audit row included, is
// written.
func TestProj14_FinishNeedsATerminalSession(t *testing.T) {
	fx := newWorkbenchFixture(t)
	theirs := seedTerminalSession(t, fx.d, fx.b)
	for _, env := range []string{"", "999999", "garbage", strconv.FormatInt(theirs, 10)} {
		reg := askRegistry(t, fx.d, env)
		_, err := proposeIn(t, reg, fx.a, "finish_session", fmt.Sprintf(`{"summary":"Done.","target_id":%d,"reason":"r"}`, fx.aTarget))
		assert.Equal(t, "finish_session needs a Watchtower terminal session", refusal(t, err), "env %q", env)
	}
	at, summary := finishState(t, fx.d, theirs)
	assert.Empty(t, at, "another workbench's session is never marked")
	assert.Empty(t, summary)
	assert.Zero(t, countActions(t, fx.d), "a refused finish writes no audit row")
	assert.Zero(t, countSessionLinks(t, fx.d))
}

func TestFinishSession_MarksTheSessionWithItsAuditRow(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	out := mustApply(t, reg, fx.a, "finish_session", `{"summary":"  PR #12 merged.\nNothing left.  ","reason":"work done"}`)
	assert.EqualValues(t, session, out["session_id"])
	assert.EqualValues(t, 0, out["open_asks"])
	assert.NotContains(t, out, "session_link_warning")

	at, summary := finishState(t, fx.d, session)
	assert.Equal(t, out["finished_at"], at, "the result names the stored stamp")
	assert.Regexp(t, `^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$`, at)
	assert.Equal(t, "PR #12 merged.\nNothing left.", summary, "stored trimmed")

	var tool, reason, status string
	require.NoError(t, fx.d.QueryRow(`SELECT tool, reason, status FROM agent_actions ORDER BY id DESC LIMIT 1`).
		Scan(&tool, &reason, &status))
	assert.Equal(t, []string{"finish_session", "work done", "applied"}, []string{tool, reason, status})
}

func TestFinishSession_SummaryBounds(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	summaryArgs := func(s string) string {
		b, err := json.Marshal(map[string]string{"summary": s, "reason": "r"})
		require.NoError(t, err)
		return string(b)
	}
	for _, ok := range []string{
		strings.Repeat("ж", 600),
		" " + strings.Repeat("ж", 600) + " \n",
		"one\ntwo\nthree\nfour",
	} {
		mustApply(t, reg, fx.a, "finish_session", summaryArgs(ok))
		_, summary := finishState(t, fx.d, session)
		assert.Equal(t, strings.TrimSpace(ok), summary)
	}
	_, kept := finishState(t, fx.d, session)
	actions := countActions(t, fx.d)
	for bad, want := range map[string]string{
		strings.Repeat("ж", 601):      "summary: at most 600 characters",
		"one\ntwo\nthree\nfour\nfive": "summary: at most 4 lines",
		"  \n\t ":                     "summary: required",
		"":                            "summary: required",
	} {
		_, err := proposeIn(t, reg, fx.a, "finish_session", summaryArgs(bad))
		assert.Equal(t, want, refusal(t, err), "summary %q", bad)
	}
	_, summary := finishState(t, fx.d, session)
	assert.Equal(t, kept, summary, "a refused summary writes nothing")
	assert.Equal(t, actions, countActions(t, fx.d), "nor an audit row")
}

func TestFinishSession_RefusesATargetOutsideTheWorkbench(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	for _, id := range []int64{fx.bTarget, fx.plain, 999999} {
		_, err := proposeIn(t, reg, fx.a, "finish_session", fmt.Sprintf(`{"summary":"Done.","target_id":%d,"reason":"r"}`, id))
		assert.Equal(t, fmt.Sprintf("target_id: no target with id %d in this workbench", id), refusal(t, err))
	}
	at, _ := finishState(t, fx.d, session)
	assert.Empty(t, at)
	assert.Zero(t, countActions(t, fx.d))
	assert.Zero(t, countSessionLinks(t, fx.d))
}

func TestFinishSession_ARepeatCallOverwritesTheSummary(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	first := mustApply(t, reg, fx.a, "finish_session", `{"summary":"First.","reason":"r"}`)
	second := mustApply(t, reg, fx.a, "finish_session", `{"summary":"Second.","reason":"r"}`)
	at, summary := finishState(t, fx.d, session)
	assert.Equal(t, "Second.", summary)
	assert.Equal(t, second["finished_at"], at)
	assert.GreaterOrEqual(t, at, first["finished_at"])
}

func TestFinishSession_OpenAsksCountsOnlyThisSessionsOpenAsks(t *testing.T) {
	fx := newWorkbenchFixture(t)
	mine := seedTerminalSession(t, fx.d, fx.a)
	other := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(mine, 10))
	mustApply(t, reg, fx.a, "ask_owner", questionAsk) // open
	answered := askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAsk))
	answerAsk(t, fx.d, answered, `{"answers":[{"id":"1","labels":["SQLite"]}]}`)
	withdrawn := askID(t, mustApply(t, reg, fx.a, "ask_owner", questionAsk))
	mustApply(t, reg, fx.a, "withdraw_ask", fmt.Sprintf(`{"ask_id":%d,"reason":"r"}`, withdrawn))
	mustApply(t, askRegistry(t, fx.d, strconv.FormatInt(other, 10)), fx.a, "ask_owner", questionAsk)
	mustApply(t, askRegistry(t, fx.d, ""), fx.a, "ask_owner", questionAsk)

	out := mustApply(t, reg, fx.a, "finish_session", `{"summary":"Done, one ask open.","reason":"r"}`)
	assert.EqualValues(t, 1, out["open_asks"])
}

// A failed link write never fails or undoes the tool: its own write stays and
// the result carries session_link_warning.
func TestSessionLinks_AFailedLinkKeepsTheWriteAndWarns(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	_, err := fx.d.Exec(`CREATE TRIGGER fail_links BEFORE INSERT ON terminal_session_targets
		BEGIN SELECT RAISE(FAIL, 'link store is broken'); END`)
	require.NoError(t, err)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))

	out := mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"status":"blocked","reason":"r"}`, fx.aTarget))
	assert.Contains(t, out["session_link_warning"], "link store is broken")
	target, err := fx.d.GetTargetByID(int(fx.aTarget))
	require.NoError(t, err)
	assert.Equal(t, "blocked", target.Status)

	out = mustApply(t, reg, fx.a, "add_comment", fmt.Sprintf(`{"target_id":%d,"body":"note","reason":"r"}`, fx.aTarget))
	assert.Contains(t, out["session_link_warning"], "link store is broken")

	out = mustApply(t, reg, fx.a, "finish_session", fmt.Sprintf(`{"summary":"Done.","target_id":%d,"reason":"r"}`, fx.aTarget))
	assert.Contains(t, out["session_link_warning"], "link store is broken")
	at, summary := finishState(t, fx.d, session)
	assert.NotEmpty(t, at)
	assert.Equal(t, "Done.", summary)
	assert.Zero(t, countSessionLinks(t, fx.d))
}

// The legacy (`mcp --project N`) binding links exactly as the new one does.
func TestSessionLinks_LegacyBindingLinksTheSame(t *testing.T) {
	fx := newWorkbenchFixture(t)
	session := seedTerminalSession(t, fx.d, fx.a)
	reg := askRegistry(t, fx.d, strconv.FormatInt(session, 10))
	legacy := directBinding(fx.a)
	legacy.LegacyNames = true
	for _, c := range []struct{ name, args string }{
		{"update_target", fmt.Sprintf(`{"target_id":%d,"progress":0.5,"reason":"r"}`, fx.aTarget)},
		{"finish_session", fmt.Sprintf(`{"summary":"Done.","target_id":%d,"reason":"r"}`, fx.aTarget)},
	} {
		rc, err := reg.Propose(context.Background(), c.name, json.RawMessage(c.args), legacy)
		require.NoError(t, err, c.name)
		require.Equal(t, "applied", rc.Status, c.name)
	}
	assert.Equal(t, []int64{fx.aTarget}, linkedTargets(t, fx.d, session))
	at, _ := finishState(t, fx.d, session)
	assert.NotEmpty(t, at)
}
