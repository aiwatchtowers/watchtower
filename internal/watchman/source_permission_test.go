package watchman

import (
	"context"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func seedPermission(t *testing.T, d *db.DB, session, wb int64, tool, summary, status string, decidedAt *time.Time) int64 {
	t.Helper()
	var at any
	if decidedAt != nil {
		at = db.AgentStateStamp(*decidedAt)
	}
	res, err := d.Exec(`INSERT INTO permission_requests (terminal_session_id, workbench_id, tool_name, summary, status, created_at, decided_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, session, wb, tool, summary, status, db.AgentStateStamp(srcT0), at)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func TestPermissionSource_MapsRows(t *testing.T) {
	d := openSourceDB(t)
	s := seedSession(t, d, 1, nil)
	t1, t2 := srcT0.Add(1500*time.Millisecond), srcT0.Add(time.Hour)
	allow := seedPermission(t, d, s, 1, "Bash", "go test ./internal/importer", "allowed", &t1)
	deny := seedPermission(t, d, s, 1, "Bash", "curl -H 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789' https://example.com", "denied", &t2) // leak-check:allow

	ps, _, done, err := (&permissionSource{}).Next(context.Background(), d, 1, "", 10)
	require.NoError(t, err)
	require.True(t, done)
	require.Equal(t, []string{strconv.FormatInt(deny, 10), strconv.FormatInt(allow, 10)}, keys(ps))
	require.Equal(t, "deny", ps[0].Choice)
	require.NotContains(t, ps[0].Situation, "abcdefghijklmnopqrstuvwxyz0123456789")
	require.Equal(t, "allow", ps[1].Choice)
	require.Equal(t, "permission", ps[1].Category)
	require.Equal(t, "permission", ps[1].Source)
	require.Equal(t, "Tool: Bash\ngo test ./internal/importer", ps[1].Situation)
	require.Equal(t, t1, ps[1].DecidedAt, "the millisecond stamp is kept")
}

func TestPermissionSource_SkipsPendingExpiredAndAnsweredOnMac(t *testing.T) {
	d := openSourceDB(t)
	s := seedSession(t, d, 1, nil)
	at := srcT0
	keep := seedPermission(t, d, s, 1, "Edit", "a.go", "allowed", &at)
	seedPermission(t, d, s, 1, "Edit", "b.go", "pending", nil)
	seedPermission(t, d, s, 1, "Edit", "c.go", "expired", &at)
	seedPermission(t, d, s, 1, "Edit", "d.go", "answered_on_mac", &at)
	s2 := seedSession(t, d, 2, nil)
	seedPermission(t, d, s2, 2, "Edit", "e.go", "denied", &at)

	ps, _, _, err := (&permissionSource{}).Next(context.Background(), d, 1, "", 10)
	require.NoError(t, err)
	require.Equal(t, []string{strconv.FormatInt(keep, 10)}, keys(ps))
}

func TestPermissionSource_CursorNewestFirst(t *testing.T) {
	d := openSourceDB(t)
	s := seedSession(t, d, 1, nil)
	checkNewestFirst(t, d, &permissionSource{}, func(_ int, at time.Time) string {
		return strconv.FormatInt(seedPermission(t, d, s, 1, "Bash", "ls", "allowed", &at), 10)
	})
}

func TestPermissionSource_MissingStampCounted(t *testing.T) {
	d := openSourceDB(t)
	logs := captureLog(t)
	s := seedSession(t, d, 1, nil)
	at := srcT0
	keep := seedPermission(t, d, s, 1, "Bash", "ls", "allowed", &at)
	bad := seedPermission(t, d, s, 1, "Bash", "ls", "denied", nil) // decided, but no decided_at

	src := &permissionSource{}
	ps, _, done, err := src.Next(context.Background(), d, 1, "", 10)
	require.NoError(t, err)
	require.True(t, done)
	require.Equal(t, []string{strconv.FormatInt(keep, 10)}, keys(ps))
	require.Equal(t, 1, src.Skipped())
	require.Contains(t, logs.String(), "watchman: permission "+strconv.FormatInt(bad, 10)+" skipped: no readable decided_at")
}
