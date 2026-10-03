package sessionreport

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func summaries(t *testing.T, fixture string) map[int64]Summary {
	t.Helper()
	d := loadFixture(t, fixture)
	list, err := Summaries(context.Background(), d, 1)
	require.NoError(t, err)
	out := map[int64]Summary{}
	for _, s := range list {
		out[s.SessionID] = s
	}
	return out
}

func TestSummaries_OnePROpen(t *testing.T) {
	s := summaries(t, "board_314.sql")
	require.Len(t, s, 1)
	assert.Equal(t, 14, s[1].Done)
	assert.Equal(t, 15, s[1].Total)
	assert.Equal(t, "PR #147 open", s[1].PRLine)
	require.NotNil(t, s[1].TargetID)
	assert.EqualValues(t, 314, *s[1].TargetID)
	assert.Empty(t, s[1].FinishedAt)
}

func TestSummaries_SeveralPRsMergedAndNoShells(t *testing.T) {
	s := summaries(t, "board_257.sql")
	require.Len(t, s, 1, "the shell session 5 has no row")
	assert.Equal(t, "2 PRs merged", s[2].PRLine)
	assert.Equal(t, 1, s[2].Done)
	assert.Equal(t, 7, s[2].Total)
}

func TestSummaries_NoPRYetAndEmpty(t *testing.T) {
	d := loadFixture(t, "scope.sql")
	_, err := d.Exec(`UPDATE terminal_sessions SET finished_at = '2026-10-02T12:00:00.000Z' WHERE id = 4`)
	require.NoError(t, err)
	list, err := Summaries(context.Background(), d, 1)
	require.NoError(t, err)
	require.Equal(t, []int64{3, 4, 6}, ids(list, func(s Summary) int64 { return s.SessionID }),
		"the workbench's claude sessions in id order, not another workbench's")

	assert.Equal(t, "not checked", list[0].PRLine, "a never-checked branch with done work may still carry a PR")
	assert.Equal(t, 2, list[0].Done)
	assert.Equal(t, 4, list[0].Total)
	assert.Equal(t, "", list[1].PRLine)
	assert.Equal(t, "2026-10-02T12:00:00.000Z", list[1].FinishedAt)
	assert.Equal(t, "", list[2].PRLine)
	assert.Nil(t, list[2].TargetID)
	assert.Equal(t, 0, list[2].Total)

	_, err = d.Exec(`INSERT INTO workbench_pr_states (project_id, ref, state, checked_at)
		VALUES (1, 'branch:feat/linked', 'none', '2026-10-02T12:00:00.000Z')`)
	require.NoError(t, err)
	list, err = Summaries(context.Background(), d, 1)
	require.NoError(t, err)
	assert.Equal(t, "no PR yet", list[0].PRLine, "a checked branch with done work and no PR")
}

func TestPRLine_Texts(t *testing.T) {
	n := func(v int64) *int64 { return &v }
	b := &board{byID: map[int64]*boardEntry{}}
	b.byID[1] = &boardEntry{}
	b.byID[1].target.ID, b.byID[1].target.Status = 1, "done"
	b.byID[2] = &boardEntry{}
	b.byID[2].target.ID, b.byID[2].target.Status = 2, "todo"
	sc := scope{b: b}
	for name, tc := range map[string]struct {
		prs  []PR
		want string
	}{
		"one open":              {[]PR{{Ref: "pr:147", PRNumber: n(147), State: "open"}}, "PR #147 open"},
		"one unchecked":         {[]PR{{Ref: "pr:147", PRNumber: n(147), State: "unknown"}}, "PR #147"},
		"two merged":            {[]PR{{Ref: "pr:1", PRNumber: n(1), State: "merged"}, {Ref: "pr:2", PRNumber: n(2), State: "merged"}}, "2 PRs merged"},
		"mixed":                 {[]PR{{Ref: "pr:1", PRNumber: n(1), State: "merged"}, {Ref: "pr:2", PRNumber: n(2), State: "open"}, {Ref: "pr:3", PRNumber: n(3), State: "unknown"}}, "1 PR open, 1 PR merged, 1 PR not checked"},
		"PR beats branch":       {[]PR{{Ref: "branch:a", State: "unknown", Targets: []int64{1}}, {Ref: "pr:2", PRNumber: n(2), State: "closed"}}, "PR #2 closed"},
		"no PR yet":             {[]PR{{Ref: "branch:a", State: "none", Targets: []int64{1}}}, "no PR yet"},
		"branch merged":         {[]PR{{Ref: "branch:a", State: "merged", Targets: []int64{1}}}, ""},
		"branch no done":        {[]PR{{Ref: "branch:a", State: "unknown", Targets: []int64{2}}}, ""},
		"branch unchecked":      {[]PR{{Ref: "branch:a", State: "unknown", Targets: []int64{1}}}, "not checked"},
		"open branch":           {[]PR{{Ref: "branch:a", State: "open", Targets: []int64{1}}}, "no PR yet"},
		"known beats unchecked": {[]PR{{Ref: "branch:a", State: "unknown", Targets: []int64{1}}, {Ref: "branch:b", State: "none", Targets: []int64{1}}}, "no PR yet"},
		"nothing":               {nil, ""},
	} {
		assert.Equal(t, tc.want, sc.prLine(tc.prs), name)
	}
}
