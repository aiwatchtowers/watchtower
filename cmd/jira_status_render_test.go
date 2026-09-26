package cmd

import (
	"bytes"
	"strings"
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
)

func renderSyncStates(states ...db.JiraSyncState) string {
	var buf bytes.Buffer
	printJiraSyncStates(&buf, states)
	return buf.String()
}

// TestPrintJiraSyncStates_ShowsTheError is the render half of the fix.
// Populating jira_sync_state.last_error changes nothing an operator can see
// unless `jira status` prints it — before this, the renderer never touched the
// column, so the failure was invisible on two independent counts.
func TestPrintJiraSyncStates_ShowsTheError(t *testing.T) {
	out := renderSyncStates(db.JiraSyncState{
		AccountID: 1, ProjectKey: "OPS",
		LastSyncedAt: "2026-09-12T00:00:00Z", IssuesSynced: 42,
		LastError: "GET /rest/api/3/search/jql: status 500", LastErrorAt: "2026-09-13T08:00:00Z",
	})

	assert.Contains(t, out, "Last sync (1:OPS): 2026-09-12T00:00:00Z")
	assert.Contains(t, out, "status 500", "the reason must reach the operator")
	assert.Contains(t, out, "2026-09-13T08:00:00Z", "without the time, a stale error reads as a current one")
}

// A project that has failed every pass since it was added has an empty
// last_synced_at, and the old renderer skipped its line entirely — which reads
// exactly like "that project is not configured".
func TestPrintJiraSyncStates_ShowsNeverSyncedProject(t *testing.T) {
	out := renderSyncStates(db.JiraSyncState{
		AccountID: 2, ProjectKey: "SEC",
		LastError: "jira is down", LastErrorAt: "2026-09-13T08:00:00Z",
	})

	assert.Contains(t, out, "2:SEC", "a project that never synced must still appear")
	assert.Contains(t, out, "never")
	assert.Contains(t, out, "jira is down")
}

// A healthy project must not grow a scary second line.
func TestPrintJiraSyncStates_HealthyProjectHasNoErrorLine(t *testing.T) {
	out := renderSyncStates(db.JiraSyncState{
		AccountID: 1, ProjectKey: "OPS", LastSyncedAt: "2026-09-13T00:00:00Z", IssuesSynced: 7,
	})

	assert.Contains(t, out, "Last sync (1:OPS): 2026-09-13T00:00:00Z")
	assert.NotContains(t, out, "Last error")
}

// Client.do folds the whole HTTP response body into the error, so an HTML
// error page must not flood the status output or break its one-line-per-fact
// layout. The untruncated text stays in the daemon log.
func TestPrintJiraSyncStates_BoundsAndFlattensTheErrorText(t *testing.T) {
	out := renderSyncStates(db.JiraSyncState{
		AccountID: 1, ProjectKey: "OPS",
		LastError:   "status 503:\n<html>\n<body>" + strings.Repeat("x", 5000) + "</body>\n</html>",
		LastErrorAt: "2026-09-13T08:00:00Z",
	})

	assert.Equal(t, 2, strings.Count(strings.TrimSuffix(out, "\n"), "\n")+1,
		"one project renders one sync line and one error line, whatever the body contained")
	assert.Less(t, len(out), 400, "a multi-KB response body must not flood the status output")
	assert.Contains(t, out, "status 503:")
}

// The degenerate case: nothing synced yet at all renders nothing.
func TestPrintJiraSyncStates_NoStates(t *testing.T) {
	assert.Empty(t, renderSyncStates())
}
