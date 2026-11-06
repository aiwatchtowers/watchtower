package cmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/spf13/pflag"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// foldersCLI is a temp workspace for the `inbox folders` tests: a fresh
// database with the seeded root and Needs approval, every agent marker unset.
type foldersCLI struct {
	t *testing.T
	d *db.DB
}

func newFoldersCLI(t *testing.T) *foldersCLI {
	t.Helper()
	return &foldersCLI{t: t, d: writeActionsConfig(t)}
}

// runFolders runs `inbox folders <args>` and returns stdout and stderr apart:
// the Desktop decodes stdout alone.
func runFolders(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	var out, errOut bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&errOut)
	rootCmd.SetArgs(append([]string{"inbox", "folders"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	ifFlags = inboxFoldersFlags{}
	for _, c := range inboxFoldersCmd.Commands() {
		c.Flags().VisitAll(func(f *pflag.Flag) { f.Changed = false })
	}
	return out.String(), errOut.String(), err
}

// json runs a --json verb that must succeed and decodes its last stdout line,
// which must be the only one.
func (c *foldersCLI) json(args ...string) map[string]any {
	c.t.Helper()
	out, _, err := runFolders(c.t, append(args, "--json")...)
	require.NoError(c.t, err, out)
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	require.Len(c.t, lines, 1, "--json prints one line: %q", out)
	var m map[string]any
	require.NoError(c.t, json.Unmarshal([]byte(lines[0]), &m), out)
	return m
}

func (c *foldersCLI) rev() string {
	c.t.Helper()
	return strconv.FormatInt(int64(c.json("list")["revision"].(float64)), 10)
}

// create makes an owner folder and returns its id.
func (c *foldersCLI) create(title string, extra ...string) string {
	c.t.Helper()
	m := c.json(append([]string{"create", "--title", title, "--expect-revision", c.rev()}, extra...)...)
	return idString(m["folder"].(map[string]any)["id"])
}

// folderByID finds a folder of the current list by id.
func (c *foldersCLI) folderByID(id string) map[string]any {
	c.t.Helper()
	for _, f := range c.json("list")["folders"].([]any) {
		m := f.(map[string]any)
		if idString(m["id"]) == id {
			return m
		}
	}
	c.t.Fatalf("no folder %s in the list", id)
	return nil
}

// approvalsID is the seeded Needs approval folder's id.
func (c *foldersCLI) approvalsID() string {
	c.t.Helper()
	for _, f := range c.json("list")["folders"].([]any) {
		m := f.(map[string]any)
		if m["kind"] == "approvals" {
			return idString(m["id"])
		}
	}
	c.t.Fatal("no Needs approval folder")
	return ""
}

func (c *foldersCLI) automation(slug, builtinID string) string {
	c.t.Helper()
	var id int64
	var err error
	if builtinID == "" {
		err = c.d.QueryRow(`INSERT INTO automations (slug, scope, path, approval_hash) VALUES (?, 'personal', ?, 'h-1')
			RETURNING id`, slug, "/acme/automations/"+slug+".md").Scan(&id)
	} else {
		err = c.d.QueryRow(`INSERT INTO automations (slug, scope, path, origin, builtin_id) VALUES (?, 'personal', ?, 'builtin', ?)
			RETURNING id`, slug, "builtin:"+builtinID, builtinID).Scan(&id)
	}
	require.NoError(c.t, err)
	return strconv.FormatInt(id, 10)
}

func (c *foldersCLI) output(automationID, folderID string) {
	c.t.Helper()
	var run int64
	require.NoError(c.t, c.d.QueryRow(`INSERT INTO automation_runs (automation_id, trigger, status) VALUES (?, 'manual', 'succeeded')
		RETURNING id`, automationID).Scan(&run))
	_, err := c.d.Exec(`INSERT INTO automation_outputs (automation_id, run_id, kind, title, body, folder_id)
		VALUES (?, ?, 'inbox', 't', 'b', ?)`, automationID, run, folderID)
	require.NoError(c.t, err)
}

func idString(v any) string { return strconv.FormatInt(int64(v.(float64)), 10) }

func wantFolderKeys(t *testing.T, v any) {
	t.Helper()
	wantKeys(t, v.(map[string]any), "id", "kind", "slug", "title", "icon", "parent_id", "position", "hidden", "automation_ids")
}

func TestInboxFoldersCLI_ListJSONKeys(t *testing.T) {
	c := newFoldersCLI(t)
	m := c.json("list")
	wantKeys(t, m, "revision", "folders")
	assert.EqualValues(t, 1, m["revision"])
	folders := m["folders"].([]any)
	require.Len(t, folders, 2, "the seeded root and Needs approval")
	for _, f := range folders {
		wantFolderKeys(t, f)
	}
	root := folders[0].(map[string]any)
	assert.Equal(t, "root", root["kind"])
	assert.Equal(t, "inbox", root["slug"])
	assert.Nil(t, root["parent_id"], "the root's parent_id is null")
	assert.Equal(t, []any{}, root["automation_ids"], "automation_ids is an array, never null")
	assert.Equal(t, "approvals", folders[1].(map[string]any)["kind"])
}

func TestInboxFoldersCLI_ListIsPreOrder(t *testing.T) {
	c := newFoldersCLI(t)
	a := c.create("Alpha")
	b := c.create("Beta")
	a1 := c.create("Alpha one", "--parent", a)
	var ids []string
	for _, f := range c.json("list")["folders"].([]any) {
		ids = append(ids, idString(f.(map[string]any)["id"]))
	}
	assert.Equal(t, []string{ids[0], c.approvalsID(), a, a1, b}, ids)
}

func TestInboxFoldersCLI_CreateJSONKeys(t *testing.T) {
	c := newFoldersCLI(t)
	m := c.json("create", "--title", "Release", "--icon", "flag", "--expect-revision", "1")
	wantKeys(t, m, "revision", "folder")
	assert.EqualValues(t, 2, m["revision"], "the new revision")
	f := m["folder"].(map[string]any)
	wantFolderKeys(t, f)
	assert.Equal(t, "owner", f["kind"])
	assert.Equal(t, "release", f["slug"])
	assert.Equal(t, "Release", f["title"])
	assert.Equal(t, "flag", f["icon"])
	assert.Equal(t, false, f["hidden"])
}

func TestInboxFoldersCLI_UpdateJSONKeys(t *testing.T) {
	c := newFoldersCLI(t)
	id := c.create("Release")
	m := c.json("update", id, "--title", "Releases", "--hidden=true", "--expect-revision", c.rev())
	wantKeys(t, m, "revision", "folder")
	f := m["folder"].(map[string]any)
	wantFolderKeys(t, f)
	assert.Equal(t, "Releases", f["title"])
	assert.Equal(t, "release", f["slug"], "a rename keeps the slug")
	assert.Equal(t, true, f["hidden"])
}

func TestInboxFoldersCLI_HiddenFalseUnhides(t *testing.T) {
	c := newFoldersCLI(t)
	id := c.create("Release")
	c.json("update", id, "--hidden=true", "--expect-revision", c.rev())
	m := c.json("update", id, "--hidden=false", "--expect-revision", c.rev())
	assert.Equal(t, false, m["folder"].(map[string]any)["hidden"])

	// A rename alone leaves hidden as it is.
	c.json("update", id, "--hidden=true", "--expect-revision", c.rev())
	m = c.json("update", id, "--title", "Renamed", "--expect-revision", c.rev())
	assert.Equal(t, true, m["folder"].(map[string]any)["hidden"])
}

func TestInboxFoldersCLI_MoveJSONKeys(t *testing.T) {
	c := newFoldersCLI(t)
	a := c.create("Alpha")
	b := c.create("Beta")
	m := c.json("move", b, "--parent", a, "--position", "0", "--expect-revision", c.rev())
	wantKeys(t, m, "revision", "folder")
	f := m["folder"].(map[string]any)
	wantFolderKeys(t, f)
	assert.Equal(t, a, idString(f["parent_id"]))
	assert.EqualValues(t, 0, f["position"])
}

func TestInboxFoldersCLI_DeleteJSONKeys(t *testing.T) {
	c := newFoldersCLI(t)
	parent := c.create("Parent")
	gone := c.create("Gone", "--parent", parent)
	c.create("Child", "--parent", gone)
	c.create("Clash", "--parent", gone)
	c.create("clash", "--parent", parent)
	routed := c.automation("acme-digest", "")
	c.json("route", routed, "--folder", gone, "--expect-revision", c.rev())
	c.output(routed, gone)

	m := c.json("delete", gone, "--expect-revision", c.rev())
	wantKeys(t, m, "revision", "moved")
	moved := m["moved"].(map[string]any)
	wantKeys(t, moved, "folders", "automations", "artifacts", "renamed")
	assert.EqualValues(t, 2, moved["folders"])
	assert.EqualValues(t, 1, moved["automations"])
	assert.EqualValues(t, 1, moved["artifacts"])
	renamed := moved["renamed"].([]any)
	require.Len(t, renamed, 1)
	r := renamed[0].(map[string]any)
	wantKeys(t, r, "id", "from", "to")
	assert.Equal(t, "Clash", r["from"])
	assert.Equal(t, "Clash (2)", r["to"])

	// FOLDER-01 through the CLI: the route moved up to the parent.
	assert.Equal(t, []any{float64(mustAtoi(t, routed))}, c.folderByID(parent)["automation_ids"])
}

func TestInboxFoldersCLI_DeleteRenamedIsEmptyArray(t *testing.T) {
	c := newFoldersCLI(t)
	id := c.create("Empty")
	m := c.json("delete", id, "--expect-revision", c.rev())
	assert.Equal(t, []any{}, m["moved"].(map[string]any)["renamed"])
}

func TestInboxFoldersCLI_RouteJSONKeys(t *testing.T) {
	c := newFoldersCLI(t)
	a := c.automation("acme-digest", "")
	existing := c.create("Release")

	m := c.json("route", a, "--folder", existing, "--expect-revision", c.rev())
	wantKeys(t, m, "revision", "automation_id", "folder", "created")
	wantFolderKeys(t, m["folder"])
	assert.Equal(t, a, idString(m["automation_id"]))
	assert.Equal(t, false, m["created"])
	assert.Equal(t, existing, idString(m["folder"].(map[string]any)["id"]))

	m = c.json("route", a, "--new-title", "Digests", "--new-icon", "bell", "--parent", existing, "--expect-revision", c.rev())
	assert.Equal(t, true, m["created"])
	f := m["folder"].(map[string]any)
	assert.Equal(t, "Digests", f["title"])
	assert.Equal(t, "bell", f["icon"])
	assert.Equal(t, existing, idString(f["parent_id"]))
	assert.Equal(t, []any{float64(mustAtoi(t, a))}, f["automation_ids"])
}

func TestInboxFoldersCLI_RouteNeedsOneTarget(t *testing.T) {
	c := newFoldersCLI(t)
	a := c.automation("acme-digest", "")
	rev := c.rev()
	for _, args := range [][]string{
		{"route", a, "--expect-revision", rev},
		{"route", a, "--folder", c.approvalsID(), "--new-title", "Both", "--expect-revision", rev},
	} {
		out, _, err := runFolders(t, args...)
		require.Error(t, err, args)
		assert.Contains(t, err.Error(), "a route names either an existing folder or a new title")
		assert.Empty(t, out)
	}
	assert.Equal(t, rev, c.rev(), "nothing written")
}

func TestInboxFoldersCLI_RouteRefusals(t *testing.T) {
	c := newFoldersCLI(t)
	other := c.create("Other")
	builtin := c.automation("needs-approval", "needs-approval")
	_, _, err := runFolders(t, "route", builtin, "--folder", other, "--expect-revision", c.rev())
	require.Error(t, err)
	assert.Equal(t, "Needs approval's automation stays in Needs approval", err.Error())

	_, _, err = runFolders(t, "route", "9999", "--new-title", "Lost", "--expect-revision", c.rev())
	require.Error(t, err)
	assert.Equal(t, "no automation 9999", err.Error())
	for _, f := range c.json("list")["folders"].([]any) {
		assert.NotEqual(t, "Lost", f.(map[string]any)["title"], "no folder created for a missing automation")
	}
}

func TestInboxFoldersCLI_ConflictExitAndMessage(t *testing.T) {
	c := newFoldersCLI(t)
	id := c.create("Release") // revision 2
	out, _, err := runFolders(t, "update", id, "--title", "Stale", "--expect-revision", "1", "--json")
	require.Error(t, err)
	assert.Equal(t, "the Inbox menu changed — reload it and try again (revision 2, you had 1)", err.Error())
	assert.Empty(t, out, "a refusal prints nothing on stdout")
	var ec *exitCodeError
	assert.False(t, errors.As(err, &ec), "a conflict exits 1, like every refusal")
	assert.Equal(t, "Release", c.folderByID(id)["title"], "nothing written, no retry")
	assert.Equal(t, "2", c.rev())
}

func TestInboxFoldersCLI_MissingExpectRevision(t *testing.T) {
	c := newFoldersCLI(t)
	id := c.create("Release")
	rev := c.rev()
	for _, args := range [][]string{
		{"create", "--title", "New"},
		{"update", id, "--title", "New"},
		{"move", id, "--parent", id, "--position", "0"},
		{"delete", id},
		{"route", "1", "--folder", id},
		// Checked before the id: nothing about the call is read first.
		{"update", "x", "--title", "New"},
	} {
		out, _, err := runFolders(t, append(args, "--json")...)
		require.Error(t, err, args)
		assert.Equal(t, "--expect-revision is required", err.Error(), args)
		assert.Empty(t, out, args)
	}
	assert.Equal(t, rev, c.rev())
}

func TestInboxFoldersCLI_AgentMarkerRefusesWritesNotList(t *testing.T) {
	c := newFoldersCLI(t)
	id := c.create("Release")
	rev := c.rev()
	for _, marker := range agentEnvMarkers {
		t.Run(marker, func(t *testing.T) {
			t.Setenv(marker, "1")
			for _, args := range [][]string{
				{"create", "--title", "New", "--expect-revision", rev},
				{"update", id, "--title", "New", "--expect-revision", rev},
				{"move", id, "--parent", id, "--position", "0", "--expect-revision", rev},
				{"delete", id, "--expect-revision", rev},
				{"route", "1", "--folder", id, "--expect-revision", rev},
				// The refusal comes before the revision check.
				{"delete", id},
			} {
				out, _, err := runFolders(t, append(args, "--json")...)
				require.Error(t, err, args)
				assert.Contains(t, err.Error(), "refusing to change the Inbox menu under an AI agent", args)
				assert.Empty(t, out, args)
			}
			out, _, err := runFolders(t, "list", "--json")
			require.NoError(t, err, "list is free under an agent")
			assert.Contains(t, out, `"revision":`+rev)
		})
	}
	assert.Equal(t, rev, c.rev(), "nothing written")
	assert.Equal(t, "Release", c.folderByID(id)["title"])
}

func TestInboxFoldersCLI_NonNumericID(t *testing.T) {
	c := newFoldersCLI(t)
	rev := c.rev()
	for _, args := range [][]string{
		{"update", "abc", "--title", "New"},
		{"move", "1x", "--parent", "1", "--position", "0"},
		{"delete", "0"},
		{"route", "x", "--folder", "1"},
	} {
		out, _, err := runFolders(t, append(args, "--expect-revision", rev, "--json")...)
		require.Error(t, err, args)
		assert.Contains(t, err.Error(), "invalid", args)
		assert.Contains(t, err.Error(), "id", args)
		assert.Empty(t, out, args)
	}
	assert.Equal(t, rev, c.rev())
}

// TestInboxFoldersCLI_ErrorPrintsNoJSON: every refusal and a database open
// failure leave stdout empty (the error goes to stderr through Execute, exit
// 1), so the Desktop never decodes a half answer.
func TestInboxFoldersCLI_ErrorPrintsNoJSON(t *testing.T) {
	c := newFoldersCLI(t)
	id := c.create("Release")
	c.create("Taken")
	rev := c.rev()
	cases := []struct {
		args []string
		want string
	}{
		{[]string{"create", "--title", "Taken"}, `a folder named "Taken" already exists here`},
		{[]string{"create", "--title", "X", "--icon", "rocket.nope"}, `unknown icon "rocket.nope"`},
		{[]string{"create", "--title", "   "}, "a folder title is 1 to 60 characters on one line"},
		{[]string{"update", "1", "--title", "Mine"}, "the Inbox folder can't be changed"},
		{[]string{"delete", c.approvalsID()}, "Needs approval can't be moved, renamed, hidden or deleted"},
		{[]string{"delete", "9999"}, "no folder 9999"},
		{[]string{"move", id, "--parent", id, "--position", "0"}, "a folder can't move into itself or a folder inside it"},
	}
	for _, tc := range cases {
		out, _, err := runFolders(t, append(tc.args, "--expect-revision", rev, "--json")...)
		require.Error(t, err, tc.args)
		assert.Equal(t, tc.want, err.Error(), tc.args)
		assert.Empty(t, out, tc.args)
		var ec *exitCodeError
		assert.False(t, errors.As(err, &ec), "exit 1: %v", tc.args)
	}
	assert.Equal(t, rev, c.rev(), "nothing written")

	// Too deep.
	a := c.create("A")
	b := c.create("B", "--parent", a)
	d3 := c.create("C", "--parent", b)
	out, _, err := runFolders(t, "create", "--title", "D", "--parent", d3, "--expect-revision", c.rev(), "--json")
	require.Error(t, err)
	assert.Equal(t, "folders nest at most 3 deep", err.Error())
	assert.Empty(t, out)

	// The database cannot be opened: a workspace whose database path is a folder.
	root, err := config.DataRoot()
	require.NoError(t, err)
	require.NoError(t, os.MkdirAll(filepath.Join(root, "broken", "watchtower.db"), 0o700))
	orig := flagWorkspace
	flagWorkspace = "broken"
	t.Cleanup(func() { flagWorkspace = orig })
	for _, args := range [][]string{
		{"list", "--json"},
		{"create", "--title", "New", "--expect-revision", "1", "--json"},
	} {
		out, _, err := runFolders(t, args...)
		require.Error(t, err, args)
		assert.Empty(t, out, args)
	}
}

func TestInboxFoldersCLI_TextOutput(t *testing.T) {
	c := newFoldersCLI(t)
	a := c.create("Alpha")
	c.create("Alpha one", "--parent", a)
	out, _, err := runFolders(t, "list")
	require.NoError(t, err)
	assert.Contains(t, out, "Revision 3")
	assert.Contains(t, out, "\n  Alpha  #"+a+" alpha\n")
	assert.Contains(t, out, "\n    Alpha one  #")
}

func mustAtoi(t *testing.T, s string) int {
	t.Helper()
	n, err := strconv.Atoi(s)
	require.NoError(t, err)
	return n
}
