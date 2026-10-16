package authoring

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// newWorkbenchSaveFixture is newSaveFixture with Deps.Workbench the
// real resolver over a workbench whose folder is a fresh (resolved) temp dir.
func newWorkbenchSaveFixture(t *testing.T) (f *saveFixture, wbID int64, folder string) {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	if err != nil {
		t.Fatalf("db.Open: %v", err)
	}
	t.Cleanup(func() { _ = d.Close() })
	folder, err = filepath.EvalSymlinks(t.TempDir()) // stored resolved, as ResolveWorkbenchFolder does
	if err != nil {
		t.Fatal(err)
	}
	if wbID, err = d.CreateWorkbench("beta", folder); err != nil {
		t.Fatal(err)
	}
	f = &saveFixture{d: d, ws: t.TempDir(), reg: tools.New(d)}
	resolver := automations.NewWorkbenchResolver(d, func() string { return "claude" }, func(string) bool { return false })
	if err := f.reg.Register(NewSaveAutomation(Deps{
		DB: d, WorkspaceDir: f.ws, Enabled: func() bool { return true },
		Clock:     automationstest.NewFakeClock(draftNow),
		Workbench: resolver,
	})); err != nil {
		t.Fatal(err)
	}
	return f, wbID, folder
}

func (f *saveFixture) proposeWorkbench(wbID int64, text string) (tools.Receipt, error) {
	return f.proposeErr(map[string]any{"recipe_text": text, "slug": "foo", "workbench_id": wbID, "reason": "the owner asked for it"})
}

// folderFiles lists every regular file and link under folder, relative.
func folderFiles(t *testing.T, folder string) []string {
	t.Helper()
	var out []string
	err := filepath.WalkDir(folder, func(path string, e fs.DirEntry, err error) error {
		if err != nil || e.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(folder, path)
		out = append(out, rel)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// PROJ-03 (amended, ask #272): an approved workbench save writes exactly
// <folder>/.watchtower/automations/<slug>.md — nothing else in the folder —
// indexes it under the workbench's scope and confirms the pinned hash.
func TestSaveAutomation_WorkbenchWritesIntoItsFolder(t *testing.T) {
	f, wbID, folder := newWorkbenchSaveFixture(t)
	text := recipeText([]string{"llm:light"}, "", `return 1`)
	rc, err := f.proposeWorkbench(wbID, text)
	if err != nil || rc.Status != "pending" {
		t.Fatalf("propose = %+v, %v; want pending", rc, err)
	}
	want := filepath.Join(automations.WorkbenchDir(folder), "foo.md")
	p := f.pinned(t, rc.ActionID)
	if p.Path != want || p.Scope != "workbench:"+strconv.FormatInt(wbID, 10) || !p.IsNew {
		t.Fatalf("pinned path=%q scope=%q new=%v; want %q, workbench:%d, new", p.Path, p.Scope, p.IsNew, want, wbID)
	}
	if _, err := os.Lstat(filepath.Join(folder, ".watchtower")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("propose touched the folder: %v", err)
	}

	row := f.approveApply(t, rc.ActionID)
	if row.Status != "applied" {
		t.Fatalf("Apply = %s %q; want applied", row.Status, row.Error)
	}
	assertWorkbenchFolderWritten(t, folder, want, text)
	a, err := f.d.GetAutomationBySlug(string(automations.ScopeWorkbench), wbID, "foo")
	if err != nil {
		t.Fatal(err)
	}
	assertWorkbenchRecipeRow(t, a, want, wbID)
	if save, err := f.d.LatestAppliedAutomationSave(a.Path, p.Scope, a.ApprovalHash); err != nil || save == nil {
		t.Errorf("LatestAppliedAutomationSave = %v, %v; want the applied save", save, err)
	}
}

func assertWorkbenchFolderWritten(t *testing.T, folder, want, text string) {
	t.Helper()
	if got, err := os.ReadFile(want); err != nil || string(got) != text {
		t.Fatalf("recipe file = %q, %v; want the text byte for byte", got, err)
	}
	if info, err := os.Stat(automations.WorkbenchDir(folder)); err != nil || info.Mode().Perm() != 0o755 {
		t.Errorf("recipe folder = %v, %v; want a 0755 directory", info, err)
	}
	if files := folderFiles(t, folder); len(files) != 1 || files[0] != filepath.Join(".watchtower", "automations", "foo.md") {
		t.Errorf("folder files = %v; want only .watchtower/automations/foo.md", files)
	}
}

func assertWorkbenchRecipeRow(t *testing.T, a *db.Automation, want string, wbID int64) {
	t.Helper()
	if a.Path != want || a.ProjectID != wbID || a.ConfirmedHash == "" || a.ConfirmedHash != a.ApprovalHash || a.Enabled {
		t.Errorf("row = path %q project %d confirmed %q approval %q enabled %v; want the workbench recipe, confirmed, off",
			a.Path, a.ProjectID, a.ConfirmedHash, a.ApprovalHash, a.Enabled)
	}
}

func TestSaveAutomation_WorkbenchUnknownRefused(t *testing.T) {
	f, wbID, _ := newWorkbenchSaveFixture(t)
	for _, id := range []int64{wbID + 100, -1} {
		_, err := f.proposeWorkbench(id, recipeText([]string{"llm:light"}, "", `return 1`))
		var ve *tools.ValidationError
		if !errors.As(err, &ve) {
			t.Fatalf("propose workbench %d = %v; want a ValidationError", id, err)
		}
	}
	var n int
	if err := f.d.QueryRow(`SELECT COUNT(*) FROM agent_actions`).Scan(&n); err != nil || n != 0 {
		t.Errorf("agent_actions rows = %d (%v); want 0", n, err)
	}
}

// A symlink anywhere in the recipe folder's existing path is refused at
// propose (no row) and, when swapped in after propose, at Execute — nothing
// is written through the link.
func TestSaveAutomation_WorkbenchSymlinkedRecipeDirRefused(t *testing.T) {
	text := recipeText([]string{"llm:light"}, "", `return 1`)
	link := func(t *testing.T, folder string) string {
		t.Helper()
		outside := t.TempDir()
		if err := os.Symlink(outside, filepath.Join(folder, ".watchtower")); err != nil {
			t.Fatal(err)
		}
		return outside
	}
	t.Run("at propose", func(t *testing.T) {
		f, wbID, folder := newWorkbenchSaveFixture(t)
		link(t, folder)
		_, err := f.proposeWorkbench(wbID, text)
		var ve *tools.ValidationError
		if !errors.As(err, &ve) {
			t.Fatalf("propose = %v; want a ValidationError", err)
		}
	})
	t.Run("after propose", func(t *testing.T) {
		f, wbID, folder := newWorkbenchSaveFixture(t)
		rc, err := f.proposeWorkbench(wbID, text)
		if err != nil {
			t.Fatal(err)
		}
		outside := link(t, folder)
		assertFailedWith(t, f.approveApply(t, rc.ActionID), "has a symlink in its path")
		if files := folderFiles(t, outside); len(files) != 0 {
			t.Errorf("written through the link: %v", files)
		}
		if _, err := f.d.GetAutomationBySlug(string(automations.ScopeWorkbench), wbID, "foo"); err == nil {
			t.Error("an automation was indexed")
		}
	})
}
