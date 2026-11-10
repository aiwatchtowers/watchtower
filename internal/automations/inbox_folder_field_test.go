package automations_test

import (
	"context"
	"strings"
	"testing"

	"github.com/dop251/goja"

	"watchtower/internal/automations"
	"watchtower/internal/db"
	"watchtower/internal/inboxfolders"
)

// folderFixture is an executor fixture with between(): a script calls it
// after output.inbox and before the run's commit, and it runs the test's
// closure (a folder write racing the run).
type folderFixture struct {
	*exFixture
	store   *inboxfolders.Store
	between func(t *testing.T)
}

func newFolderFixture(t *testing.T) *folderFixture {
	t.Helper()
	ff := &folderFixture{}
	ff.exFixture = newExFixture(t, exOpts{modules: func(*exFixture) []automations.Module {
		return []automations.Module{exModule{name: "between", fns: map[string]automations.SDKFunc{
			"between": func(*automations.Env, goja.FunctionCall, *goja.Runtime) (any, error) {
				if ff.between != nil {
					ff.between(t)
				}
				return nil, nil
			},
		}}}
	}})
	ff.store = inboxfolders.NewStore(ff.d)
	return ff
}

// create adds an owner folder under the root through the folder store.
func (ff *folderFixture) create(t *testing.T, title string) inboxfolders.Folder {
	t.Helper()
	tree, err := ff.store.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	_, f, err := ff.store.Create(context.Background(), inboxfolders.CreateRequest{Title: title, ExpectRevision: tree.Revision})
	if err != nil {
		t.Fatalf("create folder %q: %v", title, err)
	}
	return f
}

func (ff *folderFixture) route(t *testing.T, automationID, folderID int64) {
	t.Helper()
	tree, err := ff.store.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := ff.store.Route(context.Background(), automationID,
		inboxfolders.RouteRequest{FolderID: &folderID, ExpectRevision: tree.Revision}); err != nil {
		t.Fatalf("route %d → %d: %v", automationID, folderID, err)
	}
}

// runOnce seeds slug with script, runs it once and wants it succeeded; it
// returns the automation and the run id.
func (ff *folderFixture) runOnce(t *testing.T, slug, script string) (db.Automation, int64) {
	t.Helper()
	a := ff.seed(t, slug, script, false)
	id := ff.enqueue(t, a, db.TriggerManual)
	ff.step(t, 1)
	ff.wantRun(t, id, db.RunSucceeded, "")
	return a, id
}

// artifact is run id's one inbox output: its explicit folder_id (0 = NULL)
// and its effective folder from inbox_artifact_folders.
func (ff *folderFixture) artifact(t *testing.T, runID int64) (explicit, effective int64) {
	t.Helper()
	outs, err := ff.d.ListAutomationOutputsForRun(runID, 0)
	if err != nil || len(outs) != 1 {
		t.Fatalf("outputs of run %d = %d, %v; want 1", runID, len(outs), err)
	}
	if outs[0].FolderID != nil {
		explicit = *outs[0].FolderID
	}
	if effective, err = ff.d.InboxArtifactFolder(context.Background(), outs[0].ID); err != nil {
		t.Fatal(err)
	}
	return explicit, effective
}

// logLines are run id's log steps' texts.
func (ff *folderFixture) logLines(t *testing.T, runID int64) []string {
	t.Helper()
	var lines []string
	for _, s := range ff.steps(t, runID) {
		if s.Kind == automations.StepKindLog {
			lines = append(lines, s.ArgsJSON)
		}
	}
	return lines
}

func rootFolderID(t *testing.T, d *db.DB) int64 {
	t.Helper()
	var id int64
	if err := d.QueryRow(`SELECT id FROM inbox_folders WHERE kind = 'root'`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func TestInboxFolderField_ExistingSlugSetsFolder(t *testing.T) {
	ff := newFolderFixture(t)
	release := ff.create(t, "Release")
	_, id := ff.runOnce(t, "digest", `output.inbox({title: "t", body: "b", folder: "release"}); return 1`)
	explicit, effective := ff.artifact(t, id)
	if explicit != release.ID || effective != release.ID {
		t.Fatalf("folder = explicit %d, effective %d; want %d", explicit, effective, release.ID)
	}
	if lines := ff.logLines(t, id); len(lines) != 0 {
		t.Fatalf("journal lines %q; want none for a folder that exists", lines)
	}
}

func TestInboxFolderField_UnknownSlugFollowsRouteAndJournals(t *testing.T) {
	ff := newFolderFixture(t)
	weekly := ff.create(t, "Weekly")
	a := ff.seed(t, "digest", `output.inbox({title: "t", body: "b", folder: "nope"}); return 1`, false)
	ff.route(t, a.ID, weekly.ID)
	id := ff.enqueue(t, a, db.TriggerManual)
	ff.step(t, 1)
	ff.wantRun(t, id, db.RunSucceeded, "")
	explicit, effective := ff.artifact(t, id)
	if explicit != 0 || effective != weekly.ID {
		t.Fatalf("folder = explicit %d, effective %d; want NULL on the route %d", explicit, effective, weekly.ID)
	}
	want := []string{`folder "nope" not found — shown in Weekly`}
	if lines := ff.logLines(t, id); strings.Join(lines, "\n") != strings.Join(want, "\n") {
		t.Fatalf("journal lines %q; want %q", lines, want)
	}
}

func TestInboxFolderField_UnroutedMissShowsInTheRoot(t *testing.T) {
	ff := newFolderFixture(t)
	_, id := ff.runOnce(t, "digest", `output.inbox({title: "t", body: "b", folder: "nope"}); return 1`)
	explicit, effective := ff.artifact(t, id)
	if explicit != 0 || effective != rootFolderID(t, ff.d) {
		t.Fatalf("folder = explicit %d, effective %d; want the root", explicit, effective)
	}
	if lines := ff.logLines(t, id); len(lines) != 1 || lines[0] != `folder "nope" not found — shown in Inbox` {
		t.Fatalf("journal lines %q", lines)
	}
}

// Needs approval holds only its own approvals: an owner recipe naming it
// lands on its route, like a missing folder.
func TestInboxFolderField_NeedsApprovalRefusedForOwnerRecipe(t *testing.T) {
	ff := newFolderFixture(t)
	_, id := ff.runOnce(t, "digest", `output.inbox({title: "t", body: "b", folder: "needs-approval"}); return 1`)
	explicit, effective := ff.artifact(t, id)
	if explicit != 0 || effective != rootFolderID(t, ff.d) {
		t.Fatalf("folder = explicit %d, effective %d; want the root", explicit, effective)
	}
	if lines := ff.logLines(t, id); len(lines) != 1 || lines[0] != `folder "needs-approval" not found — shown in Inbox` {
		t.Fatalf("journal lines %q", lines)
	}
}

// The race: the folder is deleted after output.inbox and before the commit.
// The slug is resolved in the commit transaction, so the run succeeds with
// no foreign-key error and the artifact follows its route.
func TestInboxFolderField_FolderDeletedBeforeCommit(t *testing.T) {
	ff := newFolderFixture(t)
	release := ff.create(t, "Release")
	weekly := ff.create(t, "Weekly")
	a := ff.seed(t, "digest", `output.inbox({title: "t", body: "b", folder: "release"}); between(); return 1`, false)
	ff.route(t, a.ID, weekly.ID)
	ff.between = func(t *testing.T) {
		tree, err := ff.store.List(context.Background())
		if err != nil {
			t.Error(err)
			return
		}
		if _, _, err := ff.store.Delete(context.Background(), release.ID, tree.Revision); err != nil {
			t.Errorf("delete: %v", err)
		}
	}
	id := ff.enqueue(t, a, db.TriggerManual)
	ff.step(t, 1)
	ff.wantRun(t, id, db.RunSucceeded, "")
	explicit, effective := ff.artifact(t, id)
	if explicit != 0 || effective != weekly.ID {
		t.Fatalf("folder = explicit %d, effective %d; want NULL on the route %d", explicit, effective, weekly.ID)
	}
	if lines := ff.logLines(t, id); len(lines) != 1 || lines[0] != `folder "release" not found — shown in Weekly` {
		t.Fatalf("journal lines %q", lines)
	}
}

// A folder with the slug created between the call and the commit is used.
func TestInboxFolderField_FolderCreatedBeforeCommit(t *testing.T) {
	ff := newFolderFixture(t)
	var created inboxfolders.Folder
	ff.between = func(t *testing.T) { created = ff.create(t, "Release") }
	_, id := ff.runOnce(t, "digest", `output.inbox({title: "t", body: "b", folder: "release"}); between(); return 1`)
	explicit, _ := ff.artifact(t, id)
	if created.ID == 0 || explicit != created.ID {
		t.Fatalf("folder = %d; want the folder created mid-run %d", explicit, created.ID)
	}
	if lines := ff.logLines(t, id); len(lines) != 0 {
		t.Fatalf("journal lines %q; want none", lines)
	}
}

// AUTO-04: a failed run writes no folder_id, no artifact and no journal line
// about the folder.
func TestAuto04_FailedRunWritesNoFolder(t *testing.T) {
	ff := newFolderFixture(t)
	ff.create(t, "Release")
	a := ff.seed(t, "digest", `output.inbox({title: "t", body: "b", folder: "release"});
output.inbox({title: "u", body: "b", folder: "nope"}); throw new Error("boom")`, false)
	id := ff.enqueue(t, a, db.TriggerManual)
	ff.step(t, 1)
	if r := ff.run(t, id); r.Status != db.RunFailed {
		t.Fatalf("run = %s (%s); want failed", r.Status, r.Error)
	}
	if n := ff.count(t, "automation_outputs"); n != 0 {
		t.Fatalf("outputs = %d; want none", n)
	}
	if lines := ff.logLines(t, id); len(lines) != 0 {
		t.Fatalf("journal lines %q; want none", lines)
	}
}

func TestInboxFolderField_RefusesANonName(t *testing.T) {
	for name, v := range map[string]string{
		"empty": `""`, "number": `3`, "null": `null`, "object": `{}`,
		"81 bytes": `"` + strings.Repeat("a", automations.MaxFolderSlugBytes+1) + `"`,
		"newline":  `"rel\nease"`, "tab": `"rel\tease"`, "nul": `"rel\u0000ease"`,
	} {
		t.Run(name, func(t *testing.T) {
			wantRefusal(t, `output.inbox({title: "t", body: "b", folder: `+v+`})`, feedCase(),
				"ValidationError", "output.inbox(): folder must be a folder name")
		})
	}
}

// A dry run buffers the slug and writes nothing (resolution is the
// commit's, and a dry run never commits).
func TestInboxFolderField_DryRunBuffersTheSlug(t *testing.T) {
	c := feedCase()
	c.dryRun = true
	r := runSDK(t, `output.inbox({title: "t", body: "b", folder: "release"}); return 1`, c)
	if r.err != nil {
		t.Fatal(r.err)
	}
	outs := r.env.Buffer.Outputs()
	if len(outs) != 1 || outs[0].FolderSlug != "release" || outs[0].FolderID != nil {
		t.Fatalf("buffered %+v; want the slug only", outs)
	}
}

// A slug at the cap is a name (it may name no folder; that is the commit's
// business).
func TestInboxFolderField_SlugAtTheCap(t *testing.T) {
	slug := strings.Repeat("a", automations.MaxFolderSlugBytes)
	r := mustReturn(t, try(`output.inbox({title: "t", body: "b", folder: "`+slug+`"})`), feedCase(), "ok")
	if got := r.env.Buffer.Outputs()[0].FolderSlug; got != slug {
		t.Fatalf("FolderSlug = %q", got)
	}
}

// The journal clips the steps it writes and the db clips the miss line to
// the same size: one constant.
func TestInboxFolderField_ClipSizeIsTheJournals(t *testing.T) {
	if automations.StepClipBytes != db.StepClipBytes {
		t.Fatalf("automations.StepClipBytes %d != db.StepClipBytes %d", automations.StepClipBytes, db.StepClipBytes)
	}
}
