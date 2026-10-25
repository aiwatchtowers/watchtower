package tools

import (
	"context"
	"encoding/json"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func targetsRegistry(t *testing.T, d *db.DB) *Registry {
	t.Helper()
	reg := New(d)
	require.NoError(t, reg.Register(NewListTargets()))
	require.NoError(t, reg.Register(NewGetTarget()))
	return reg
}

func seedTarget(t *testing.T, d *db.DB, text, status string) int {
	t.Helper()
	id, err := d.CreateTarget(db.Target{Text: text, Intent: "x", Level: "week", Status: status, Priority: "high", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)
	return int(id)
}

// list_targets filters by status: a matching target is returned, a non-matching
// one excluded.
func TestListTargets_FiltersByStatus(t *testing.T) {
	d := openDB(t)
	seedTarget(t, d, "Ship MCP server", "todo")
	seedTarget(t, d, "Unrelated in-progress item", "in_progress")

	got := callReadString(t, targetsRegistry(t, d), "list_targets", `{"status":"todo"}`)
	assert.Contains(t, got, "Ship MCP server")
	assert.NotContains(t, got, "Unrelated in-progress item", "status filter must exclude the in_progress target")
}

// Filtering by status=done returns done targets — GetTargets hides done rows
// unless IncludeDone is set, so a naive filter would return nothing.
func TestListTargets_ByDoneStatus(t *testing.T) {
	d := openDB(t)
	seedTarget(t, d, "Finished work", "done")

	got := callReadString(t, targetsRegistry(t, d), "list_targets", `{"status":"done"}`)
	assert.Contains(t, got, "Finished work")
}

// An empty result is a JSON array, not an error.
func TestListTargets_EmptyIsNotError(t *testing.T) {
	got := callReadString(t, targetsRegistry(t, openDB(t)), "list_targets", `{"status":"done"}`)
	assert.Equal(t, "[]", got)
}

func TestGetTarget_ReturnsTarget(t *testing.T) {
	d := openDB(t)
	id := seedTarget(t, d, "Ship MCP server", "todo")

	got := callReadString(t, targetsRegistry(t, d), "get_target", `{"id":`+strconv.Itoa(id)+`}`)
	assert.Contains(t, got, "Ship MCP server")
}

// A missing target is a friendly not-found error, not a raw sql error.
func TestGetTarget_NotFound(t *testing.T) {
	_, err := targetsRegistry(t, openDB(t)).CallRead(context.Background(), "get_target", json.RawMessage(`{"id":999}`), Binding{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no target with id 999")
	assert.NotContains(t, err.Error(), "sql: no rows")
}

func TestListTargets_RejectsInvalidEnums(t *testing.T) {
	reg := targetsRegistry(t, openDB(t))
	cases := []struct{ field, value, wantAllowed string }{
		{"status", "in-progress", "todo|in_progress|in_review|blocked|done|dismissed|snoozed"},
		{"priority", "urgent", "high|medium|low"},
		{"level", "year", "quarter|month|week|day|custom"},
		{"ownership", "theirs", "mine|delegated|watching"},
	}
	for _, c := range cases {
		_, err := reg.CallRead(context.Background(), "list_targets", json.RawMessage(`{"`+c.field+`":"`+c.value+`"}`), Binding{})
		var verr *ValidationError
		require.ErrorAs(t, err, &verr, "%s=%s", c.field, c.value)
		assert.Contains(t, verr.Msg, c.value)
		assert.Contains(t, verr.Msg, c.wantAllowed)
	}
}

func TestGetTarget_ImageDescription(t *testing.T) {
	d := openDB(t)
	wb := seedWorkbench(t, d, "acme")
	res, err := d.Exec(`INSERT INTO targets (text, level, custom_label, period_start, period_end, source_type, project_id)
		VALUES ('Fix login', 'custom', 'project', '2026-09-29', '2026-09-29', 'chat', ?)`, wb)
	require.NoError(t, err)
	tid, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO project_target_images (project_id, target_id, file_name, mime, size, sha256, path)
		VALUES (?, ?, 'shot.png', 'image/png', 3, 'aa', '/ws/project_files/1/aa.png')`, wb, tid)
	require.NoError(t, err)

	imageOf := func() map[string]any {
		res, err := targetsRegistry(t, d).CallRead(context.Background(), "get_target",
			json.RawMessage(`{"id":`+strconv.FormatInt(tid, 10)+`}`), Binding{Surface: "project", WorkbenchID: wb})
		require.NoError(t, err)
		raw, err := json.Marshal(res)
		require.NoError(t, err)
		var out struct {
			Images []map[string]any `json:"images"`
		}
		require.NoError(t, json.Unmarshal([]byte(raw), &out))
		require.Len(t, out.Images, 1)
		return out.Images[0]
	}
	assert.NotContains(t, imageOf(), "description", "absent while the image is pending")

	_, err = d.Exec(`UPDATE media_items SET status = 'ok', title = 'Login screen', body = 'two fields' WHERE target_image_id IS NOT NULL`)
	require.NoError(t, err)
	assert.Equal(t, "Login screen — two fields", imageOf()["description"])
}
