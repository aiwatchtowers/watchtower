package sessionreport

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// loadFixture opens a fresh DB holding testdata/<name>.
func loadFixture(t *testing.T, name string) *db.DB {
	t.Helper()
	d := db.OpenTestDB(t)
	script, err := os.ReadFile(filepath.Join("testdata", name))
	require.NoError(t, err)
	_, err = d.Exec(string(script))
	require.NoError(t, err)
	return d
}

func build(t *testing.T, d *db.DB, sessionID int64) Report {
	t.Helper()
	r, err := Build(context.Background(), d, 1, sessionID, Options{})
	require.NoError(t, err)
	return r
}

func ids[T any](items []T, id func(T) int64) []int64 {
	out := []int64{}
	for _, it := range items {
		out = append(out, id(it))
	}
	return out
}

func itemIDs(items []Item) []int64 { return ids(items, func(i Item) int64 { return i.ID }) }

func phaseByID(t *testing.T, phases []Phase, id int64) Phase {
	t.Helper()
	for _, p := range phases {
		if p.TargetID == id {
			return p
		}
	}
	require.Failf(t, "phase missing", "no phase %d in %+v", id, phases)
	return Phase{}
}

func TestBuild_FinishedSessionWithOneBlockedLeaf(t *testing.T) {
	d := loadFixture(t, "board_314.sql")
	r := build(t, d, 1)

	assert.Equal(t, Progress{Done: 14, Total: 15}, r.Progress)
	require.NotNil(t, r.Session.TargetID)
	assert.EqualValues(t, 314, *r.Session.TargetID)
	assert.Equal(t, "Session report", r.Session.Title)
	assert.Equal(t, "waiting", r.Session.AgentState)
	assert.Empty(t, r.Session.FinishedAt)

	assert.Equal(t, []int64{320, 330, 340}, ids(r.Phases, func(p Phase) int64 { return p.TargetID }),
		"one phase per parent of a leaf, in board order; the session target with sub-parents is none")
	a := phaseByID(t, r.Phases, 320)
	assert.Equal(t, Phase{TargetID: 320, Text: "Phase A: data layer", Done: 7, Total: 7,
		StartedAt: "2026-09-29T09:01:00Z", FinishedAt: "2026-09-29T11:07:00Z", Items: a.Items}, a)
	assert.Len(t, a.Items, 7)
	b := phaseByID(t, r.Phases, 330)
	assert.Equal(t, 5, b.Done)
	assert.Equal(t, 5, b.Total)
	assert.Equal(t, "2026-09-30T09:01:00Z", b.StartedAt)
	assert.Equal(t, "2026-09-30T12:05:00Z", b.FinishedAt)
	c := phaseByID(t, r.Phases, 340)
	assert.Equal(t, 1, c.Done)
	assert.Equal(t, 2, c.Total)
	assert.Equal(t, "2026-10-01T09:00:00Z", c.StartedAt)
	assert.Empty(t, c.FinishedAt)

	require.Len(t, r.Now, 1)
	assert.Equal(t, NowItem{Item: Item{ID: 342, Text: "Task C2", Status: "blocked"},
		Branch: "feature/session-report-ui", Since: "2026-10-02T15:00:00Z"}, r.Now[0])
	assert.Empty(t, r.Next)
	assert.Empty(t, r.OnYou)
}

func TestBuild_SessionTargetIsAPhaseOnlyWhenFlat(t *testing.T) {
	d := loadFixture(t, "board_314.sql")
	r := build(t, d, 1)
	assert.NotContains(t, ids(r.Phases, func(p Phase) int64 { return p.TargetID }), int64(314),
		"with sub-parents the session target's phase would repeat the progress")
	assert.Equal(t, Progress{Done: 14, Total: 15}, r.Progress, "its own review leaf still counts")

	// Without its sub-parents the same ticket is flat: one phase, itself.
	_, err := d.Exec(`DELETE FROM targets WHERE parent_id IN (320, 330, 340); DELETE FROM targets WHERE id IN (320, 330, 340)`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO targets (id, text, period_start, period_end, parent_id, status, project_id)
		VALUES (316, 'Write the report', '2026-09-28', '2026-10-05', 314, 'todo', 1)`)
	require.NoError(t, err)
	r = build(t, d, 1)
	require.Len(t, r.Phases, 1)
	assert.EqualValues(t, 314, r.Phases[0].TargetID)
	assert.Equal(t, 1, r.Phases[0].Done)
	assert.Equal(t, 2, r.Phases[0].Total)
	assert.ElementsMatch(t, []int64{315, 316}, itemIDs(r.Phases[0].Items))
	assert.Equal(t, []int64{316}, itemIDs(r.Next), "its leaves are in next")
}

func TestBuild_NowNextAndNestedParent(t *testing.T) {
	d := loadFixture(t, "board_257.sql")
	r := build(t, d, 2)

	assert.Equal(t, Progress{Done: 1, Total: 7}, r.Progress)
	assert.Equal(t, []int64{269, 273}, ids(r.Now, func(n NowItem) int64 { return n.ID }))
	assert.Equal(t, "feat/inbox-list", r.Now[0].Branch)
	assert.Equal(t, "2026-10-01T10:00:00Z", r.Now[0].Since)
	assert.Equal(t, []int64{263, 264, 270}, itemIDs(r.Next), "the first three todo leaves in board order")

	assert.Equal(t, []int64{261}, ids(r.Phases, func(p Phase) int64 { return p.TargetID }),
		"the session target 257 has a sub-parent, so it is no phase")
	nested := phaseByID(t, r.Phases, 261)
	assert.Equal(t, 1, nested.Done)
	assert.Equal(t, 3, nested.Total)
	assert.Equal(t, []int64{263, 264, 262}, itemIDs(nested.Items))
}

func TestBuild_ScopeTakesLinkedTargetsAndSkipsDismissed(t *testing.T) {
	d := loadFixture(t, "scope.sql")
	r := build(t, d, 3)

	assert.Equal(t, Progress{Done: 2, Total: 4}, r.Progress,
		"401, the linked 411, and 420's 421 and 422; the dismissed 402 counts in neither number")
	assert.Equal(t, []int64{422}, ids(r.Now, func(n NowItem) int64 { return n.ID }))
	assert.Equal(t, []int64{401}, itemIDs(r.Next), "412 is not in scope")

	root := phaseByID(t, r.Phases, 400) // a flat session target stays a phase
	assert.Equal(t, 0, root.Done)
	assert.Equal(t, 1, root.Total)
	assert.Equal(t, []int64{401}, itemIDs(root.Items))
	other := phaseByID(t, r.Phases, 410)
	assert.Equal(t, 1, other.Done)
	assert.Equal(t, 2, other.Total, "a phase counts all its leaves, not only the touched one")
	linked := phaseByID(t, r.Phases, 420)
	assert.Equal(t, 1, linked.Done)
	assert.Equal(t, 2, linked.Total)
	assert.Len(t, r.Phases, 3)
}

func TestBuild_TargetlessSessionLinkedToATopLevelLeaf(t *testing.T) {
	d := loadFixture(t, "scope.sql")
	_, err := d.Exec(`INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at)
		VALUES (6, 430, '2026-10-02T10:00:00Z', '2026-10-02T10:00:00Z')`)
	require.NoError(t, err)

	r := build(t, d, 6)
	assert.Nil(t, r.Session.TargetID)
	assert.Equal(t, Progress{Done: 1, Total: 1}, r.Progress, "the linked top-level leaf counts")
	assert.Empty(t, r.Phases, "a top-level leaf has no parent, so no phase")
}

func TestBuild_OnYouHoldsOnlyThisSessionsOpenAsks(t *testing.T) {
	d := loadFixture(t, "scope.sql")
	r := build(t, d, 3)

	require.Len(t, r.OnYou, 1, "not the answered ask, not another session's, not a session-less one")
	ask := r.OnYou[0]
	assert.EqualValues(t, 1, ask.ID)
	assert.Equal(t, "question", ask.Kind)
	assert.Equal(t, "Which store?", ask.Title)
	require.NotNil(t, ask.TargetID)
	assert.EqualValues(t, 401, *ask.TargetID)
	assert.Equal(t, "2026-10-02T09:00:00Z", ask.CreatedAt)
}

func TestBuild_PRsMergeSharedRefsAndKnownBranches(t *testing.T) {
	d := loadFixture(t, "board_257.sql")
	r, err := Build(context.Background(), d, 1, 2, Options{PRNote: "gh CLI not found"})
	require.NoError(t, err)
	assert.Equal(t, "gh CLI not found", r.PRNote)

	byRef := map[string]PR{}
	for _, pr := range r.PRs {
		byRef[pr.Ref] = pr
	}
	require.Len(t, byRef, 3, "%+v", r.PRs)

	pr140 := byRef["pr:140"]
	assert.ElementsMatch(t, []int64{262, 269}, pr140.Targets, "two targets with the same PR share one entry")
	require.NotNil(t, pr140.PRNumber)
	assert.EqualValues(t, 140, *pr140.PRNumber)
	assert.Equal(t, "merged", pr140.State)
	assert.Equal(t, "Inbox list", pr140.Title)
	require.NotNil(t, pr140.Additions)
	assert.EqualValues(t, 300, *pr140.Additions)
	require.NotNil(t, pr140.Deletions)
	assert.EqualValues(t, 20, *pr140.Deletions)
	assert.Equal(t, "2026-10-01T18:00:00Z", pr140.MergedAt)
	assert.Equal(t, "2026-10-02T10:00:00Z", pr140.CheckedAt)

	pr146 := byRef["pr:146"]
	assert.ElementsMatch(t, []int64{263, 273}, pr146.Targets, "a branch whose PR is known joins that PR's entry")
	assert.Equal(t, "merged", pr146.State)

	unknown := byRef["branch:feat/detector-c"]
	assert.Equal(t, "unknown", unknown.State, "a ref never cached")
	assert.Nil(t, unknown.PRNumber)
	assert.Empty(t, unknown.CheckedAt)
	assert.Equal(t, []int64{264}, unknown.Targets)
}

func TestBuild_BranchNamingAnUncachedPRUsesTheBranchRow(t *testing.T) {
	d := loadFixture(t, "board_257.sql")
	_, err := d.Exec(`DELETE FROM workbench_pr_states WHERE ref = 'pr:146'`)
	require.NoError(t, err)

	r := build(t, d, 2)
	var pr146 *PR
	for i := range r.PRs {
		if r.PRs[i].Ref == "pr:146" {
			pr146 = &r.PRs[i]
		}
	}
	require.NotNil(t, pr146, "%+v", r.PRs)
	assert.Equal(t, "merged", pr146.State, "the branch row's state stands in for the PR's")
	assert.Equal(t, "2026-10-02T19:00:00Z", pr146.CheckedAt)
}

func TestBuild_UnknownOrForeignSessionIsNotFound(t *testing.T) {
	d := loadFixture(t, "scope.sql")
	for _, id := range []int64{7, 99} {
		_, err := Build(context.Background(), d, 1, id, Options{})
		assert.ErrorIs(t, err, db.ErrTerminalSessionNotFound, "session %d", id)
	}
}

func TestSessionRefs_InScopeTargetsPRsAndBranches(t *testing.T) {
	d := loadFixture(t, "board_257.sql")
	refs, err := SessionRefs(context.Background(), d, 1, 2)
	require.NoError(t, err)
	assert.ElementsMatch(t, []string{"pr:140", "pr:146", "branch:feat/detector-b", "branch:feat/detector-c",
		"branch:feat/inbox-list", "branch:feat/inbox-detail"}, refs)

	d = loadFixture(t, "scope.sql")
	refs, err = SessionRefs(context.Background(), d, 1, 4)
	require.NoError(t, err)
	assert.Empty(t, refs)
}

func TestPRRef_ReadsNumbersAndURLs(t *testing.T) {
	for raw, want := range map[string]string{
		"147":                                  "pr:147",
		"#147":                                 "pr:147",
		"https://github.com/acme/app/pull/147": "pr:147",
		"https://github.com/acme/app/pull/147/files": "pr:147",
		"draft": "pr:draft",
	} {
		got, number := prRef(raw)
		assert.Equal(t, want, got, raw)
		assert.Equal(t, want != "pr:draft", number.Valid, raw)
	}
}

// TestProj14_ReportNeverWritesTheBoard: Build, Summaries and SessionRefs run on
// a DB whose triggers fail any write to the board, the asks, the sessions and
// the PR cache.
func TestProj14_ReportNeverWritesTheBoard(t *testing.T) {
	d := loadFixture(t, "board_257.sql")
	for _, table := range []string{"targets", "project_comments", "target_status_history", "owner_asks",
		"terminal_sessions", "terminal_session_targets", "workbench_pr_states"} {
		for _, op := range []string{"INSERT", "UPDATE", "DELETE"} {
			_, err := d.Exec(`CREATE TRIGGER proj14_` + table + `_` + op + ` BEFORE ` + op + ` ON ` + table +
				` BEGIN SELECT RAISE(ABORT, 'PROJ-14: the report wrote ` + table + `'); END`)
			require.NoError(t, err)
		}
	}
	_, err := d.Exec(`UPDATE targets SET text = 'x' WHERE id = 257`)
	require.ErrorContains(t, err, "PROJ-14", "the guard triggers fire")

	ctx := context.Background()
	r, err := Build(ctx, d, 1, 2, Options{})
	require.NoError(t, err)
	assert.Equal(t, 7, r.Progress.Total)
	summaries, err := Summaries(ctx, d, 1)
	require.NoError(t, err)
	assert.Len(t, summaries, 1)
	_, err = SessionRefs(ctx, d, 1, 2)
	require.NoError(t, err)
}
