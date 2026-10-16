package automations_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
)

// wbRecipe is a manual workbench recipe; DESC and SCRIPT are replaced.
const wbRecipe = "---\nname: Release notes\ntrigger:\n  manual: true\npermissions:\n  - llm:light\n" +
	"outputs: [report]\n---\nDESC\n\n```js\nSCRIPT\n```\n"

func wbRecipeText(desc, script string) string {
	return strings.NewReplacer("DESC", desc, "SCRIPT", script).Replace(wbRecipe)
}

// newWorkbench binds a workbench to a fresh, resolved temp folder.
func newWorkbench(t *testing.T, d *db.DB) (int64, string) {
	t.Helper()
	folder, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	id, err := d.CreateWorkbench("acme", folder)
	if err != nil {
		t.Fatalf("create workbench: %v", err)
	}
	return id, folder
}

// writeWorkbenchRecipe puts slug's recipe in the workbench's recipe folder.
func writeWorkbenchRecipe(t *testing.T, folder, slug, text string) {
	t.Helper()
	dir := automations.WorkbenchDir(folder)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, slug+".md"), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func rescanWorkbench(t *testing.T, ix *automations.Indexer, id int64, folder string) automations.RescanReport {
	t.Helper()
	rep, err := ix.RescanFolder(context.Background(), automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: id},
		automations.WorkbenchDir(folder))
	if err != nil {
		t.Fatalf("rescan workbench %d: %v", id, err)
	}
	return rep
}

func workbenchRow(t *testing.T, d *db.DB, id int64, slug string) db.Automation {
	t.Helper()
	a, err := d.GetAutomationBySlug("workbench", id, slug)
	if err != nil {
		t.Fatalf("get workbench %d/%s: %v", id, slug, err)
	}
	return *a
}

func TestRescan_WorkbenchRecipeNeedsConfirmation(t *testing.T) {
	d := db.OpenTestDB(t)
	ix := automations.NewIndexer(d, t.TempDir(), automationstest.NewFakeClock(exStart))
	wb, folder := newWorkbench(t, d)
	writeWorkbenchRecipe(t, folder, "release", wbRecipeText("Drafts release notes.", `log("v1")`))

	rep := rescanWorkbench(t, ix, wb, folder)
	a := workbenchRow(t, d, wb, "release")
	if a.Scope != "workbench" || a.ProjectID != wb || a.ParseError != "" {
		t.Fatalf("row = scope %q project %d parse_error %q", a.Scope, a.ProjectID, a.ParseError)
	}
	if a.Runnable() || !slices.Equal(rep.NeedConfirmation, []int64{a.ID}) {
		t.Fatalf("a new workbench recipe: runnable=%v need_confirmation=%v; want not runnable, [%d]", a.Runnable(), rep.NeedConfirmation, a.ID)
	}
	confirmEnable := func(a db.Automation) {
		t.Helper()
		if err := d.ConfirmAutomation(a.ID, a.ApprovalHash, exStart); err != nil {
			t.Fatal(err)
		}
		if err := d.SetAutomationEnabled(a.ID, true, exStart); err != nil {
			t.Fatal(err)
		}
	}
	confirmEnable(a)
	rescanWorkbench(t, ix, wb, folder)
	if a = workbenchRow(t, d, wb, "release"); !a.Runnable() {
		t.Fatal("confirmed and enabled, the recipe is not runnable")
	}

	// A "git pull" rewrites the script: it needs the owner again.
	writeWorkbenchRecipe(t, folder, "release", wbRecipeText("Drafts release notes.", `log("v2")`))
	rep = rescanWorkbench(t, ix, wb, folder)
	if a = workbenchRow(t, d, wb, "release"); a.Runnable() || !slices.Contains(rep.NeedConfirmation, a.ID) {
		t.Fatalf("a pulled script change: runnable=%v need_confirmation=%v", a.Runnable(), rep.NeedConfirmation)
	}
	confirmEnable(a)

	// A description-only change binds nothing (D5).
	writeWorkbenchRecipe(t, folder, "release", wbRecipeText("Drafts the release notes from merged PRs.", `log("v2")`))
	rep = rescanWorkbench(t, ix, wb, folder)
	if a = workbenchRow(t, d, wb, "release"); !a.Runnable() || len(rep.NeedConfirmation) != 0 {
		t.Fatalf("a description-only change: runnable=%v need_confirmation=%v; want runnable, none", a.Runnable(), rep.NeedConfirmation)
	}
}

// The same file in two workbenches binds two different approvals: a confirm
// in one never runs the other's copy. TestRecipe_RejectsWorkbenchKey (D15)
// keeps the scope out of the recipe's own hands.
func TestApprovalHash_WorkbenchScopeDiffersPerWorkbench(t *testing.T) {
	d := db.OpenTestDB(t)
	ix := automations.NewIndexer(d, t.TempDir(), automationstest.NewFakeClock(exStart))
	text := wbRecipeText("Drafts release notes.", `log("v1")`)
	wb1, folder1 := newWorkbench(t, d)
	wb2, folder2 := newWorkbench(t, d)
	writeWorkbenchRecipe(t, folder1, "release", text)
	writeWorkbenchRecipe(t, folder2, "release", text)
	rescanWorkbench(t, ix, wb1, folder1)
	rescanWorkbench(t, ix, wb2, folder2)
	a1, a2 := workbenchRow(t, d, wb1, "release"), workbenchRow(t, d, wb2, "release")
	if a1.ContentHash != a2.ContentHash {
		t.Fatal("fixture: the two files differ")
	}
	if a1.ApprovalHash == a2.ApprovalHash {
		t.Fatalf("both workbenches' copies share approval_hash %s", a1.ApprovalHash)
	}
}

func TestScheduler_RescansUnprotectedWorkbenches(t *testing.T) {
	f := newSchedFixture(t, exStart)
	wb, folder := newWorkbench(t, f.d)
	f.tick(t, exStart)
	writeWorkbenchRecipe(t, folder, "release", wbRecipeText("Drafts release notes.", `log("v1")`))
	f.tick(t, exStart.Add(1*time.Minute))
	if a := workbenchRow(t, f.d, wb, "release"); a.Scope != "workbench" || a.Runnable() {
		t.Fatalf("indexed row = scope %q runnable %v", a.Scope, a.Runnable())
	}

	// A workbench whose folder is gone is skipped quietly: no tick error, its
	// rows stay as they were.
	gone, goneFolder := newWorkbench(t, f.d)
	writeWorkbenchRecipe(t, goneFolder, "release", wbRecipeText("Drafts release notes.", `log("v1")`))
	f.tick(t, exStart.Add(2*time.Minute))
	if err := os.RemoveAll(goneFolder); err != nil {
		t.Fatal(err)
	}
	f.tick(t, exStart.Add(3*time.Minute))
	if a := workbenchRow(t, f.d, gone, "release"); a.RemovedAt != nil {
		t.Fatal("a missing workbench folder's rows were marked removed")
	}
}

// Review focus 4: the daemon never stats, lists or reads a protected folder —
// the predicate is checked before any filesystem call; the rows stay as the
// Desktop indexed them.
func TestScheduler_NeverStatsProtectedWorkbench(t *testing.T) {
	f := newSchedFixture(t, exStart)
	wb1, folder1 := newWorkbench(t, f.d)
	wb2, folder2 := newWorkbench(t, f.d)
	writeWorkbenchRecipe(t, folder1, "release", wbRecipeText("Drafts release notes.", `log("v1")`))
	// The Desktop indexed workbench 2 (an explicit, owner-started pass).
	writeWorkbenchRecipe(t, folder2, "release", wbRecipeText("Drafts release notes.", `log("v1")`))
	rescanWorkbench(t, f.ix, wb2, folder2)

	var touched []string
	automations.SetIndexerProbe(f.ix, func(path string) { touched = append(touched, path) })
	automations.SetSchedulerProtected(f.s, func(folder string) bool { return folder == folder2 })
	if err := os.Remove(filepath.Join(automations.WorkbenchDir(folder2), "release.md")); err != nil {
		t.Fatal(err)
	}
	for i := range 3 {
		f.tick(t, exStart.Add(time.Duration(i)*time.Minute))
	}
	for _, p := range touched {
		if strings.HasPrefix(p, folder2) {
			t.Fatalf("the scheduler touched the protected folder: %s (all: %v)", p, touched)
		}
	}
	if !slices.ContainsFunc(touched, func(p string) bool { return strings.HasPrefix(p, folder1) }) {
		t.Fatalf("fixture: the unprotected folder was never looked at (touched %v)", touched)
	}
	workbenchRow(t, f.d, wb1, "release")
	if a := workbenchRow(t, f.d, wb2, "release"); a.RemovedAt != nil {
		t.Fatal("the protected workbench's row was rescanned (marked removed)")
	}
}

func TestWorkbenchDelete_MidRunExecutorDropsRun(t *testing.T) {
	gen := newBlockingGen()
	f := newExFixture(t, exOpts{gen: gen})
	wb, folder := newWorkbench(t, f.d)
	writeWorkbenchRecipe(t, folder, "release", exRecipeText(`llm("x"); return 1`, ""))
	rescanWorkbench(t, f.ix, wb, folder)
	a := workbenchRow(t, f.d, wb, "release")
	if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, exStart); err != nil {
		t.Fatal(err)
	}
	if err := f.d.SetAutomationEnabled(a.ID, true, exStart); err != nil {
		t.Fatal(err)
	}
	id := f.enqueue(t, a, db.TriggerManual)
	f.stepNoWait(t, 1)
	gen.waitEntered(t)

	if err := f.d.DeleteWorkbench(wb); err != nil {
		t.Fatalf("delete workbench: %v", err)
	}
	f.e.Wake()
	close(gen.release)
	f.e.Wait()

	if _, err := f.d.GetAutomationRun(id); !errors.Is(err, db.ErrAutomationRunNotFound) {
		t.Fatalf("the run outlived its workbench: %v", err)
	}
	if logs := f.logs.String(); strings.Contains(logs, "automations: run") {
		t.Fatalf("a run its workbench delete removed logged errors:\n%s", logs)
	}
}

func TestWorkbenchResolver_ResolvesFolderProtectionAndAgent(t *testing.T) {
	d := db.OpenTestDB(t)
	wb, folder := newWorkbench(t, d)
	agent := "codex"
	r := automations.NewWorkbenchResolver(d, func() string { return agent }, func(f string) bool { return f == folder })
	got, err := r.Workbench(context.Background(), wb)
	if err != nil {
		t.Fatal(err)
	}
	want := automations.WorkbenchInfo{ID: wb, Folder: folder, Protected: true, DefaultAgent: "codex"}
	if got != want {
		t.Fatalf("Workbench(%d) = %+v; want %+v", wb, got, want)
	}
	agent = "shell"
	if got, _ = r.Workbench(context.Background(), wb); got.DefaultAgent != "claude" {
		t.Fatalf("an invalid default_agent resolved to %q; want claude", got.DefaultAgent)
	}
	if _, err := r.Workbench(context.Background(), wb+1); !errors.Is(err, db.ErrWorkbenchNotFound) {
		t.Fatalf("unknown workbench err = %v; want ErrWorkbenchNotFound", err)
	}
}

// Review focus 4, symlink-resolved: a recipe path that links into a
// protected folder — the bound folder itself, its .watchtower or its
// automations folder — is never followed by the scheduler. The target is
// made unreadable, so any access through the link fails the tick; the
// workbench is skipped and its rows stay as the Desktop indexed them.
func TestScheduler_NeverFollowsALinkIntoAProtectedFolder(t *testing.T) {
	text := wbRecipeText("Drafts release notes.", `log("v1")`)
	for _, tc := range []struct {
		name string
		link func(t *testing.T, folder, target string) // replaces a path under folder with a link to target
	}{
		{"folder", func(t *testing.T, folder, target string) {
			mustReplaceWithLink(t, folder, target)
		}},
		{".watchtower", func(t *testing.T, folder, target string) {
			mustReplaceWithLink(t, filepath.Join(folder, ".watchtower"), target)
		}},
		{"automations", func(t *testing.T, folder, target string) {
			mustReplaceWithLink(t, automations.WorkbenchDir(folder), target)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newSchedFixture(t, exStart)
			wb, folder := newWorkbench(t, f.d)
			writeWorkbenchRecipe(t, folder, "release", text)
			rescanWorkbench(t, f.ix, wb, folder) // the Desktop's pass
			target, err := filepath.EvalSymlinks(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			writeWorkbenchRecipe(t, target, "release", text)
			if err := os.WriteFile(filepath.Join(target, "release.md"), []byte(text), 0o644); err != nil {
				t.Fatal(err)
			}
			tc.link(t, folder, target)
			if err := os.Chmod(target, 0o000); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.Chmod(target, 0o755) })

			var touched []string
			automations.SetIndexerProbe(f.ix, func(path string) { touched = append(touched, path) })
			automations.SetSchedulerProtected(f.s, func(p string) bool { return strings.HasPrefix(p, target) })
			for i := range 2 {
				f.tick(t, exStart.Add(time.Duration(i)*time.Minute))
			}
			for _, p := range touched {
				if strings.HasPrefix(p, target) {
					t.Fatalf("the scheduler touched the protected target: %s", p)
				}
			}
			if a := workbenchRow(t, f.d, wb, "release"); a.RemovedAt != nil {
				t.Fatal("the linked workbench's row was rescanned (marked removed)")
			}
		})
	}
}

// mustReplaceWithLink replaces path (a directory) with a symlink to target.
func mustReplaceWithLink(t *testing.T, path, target string) {
	t.Helper()
	if err := os.RemoveAll(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
}
