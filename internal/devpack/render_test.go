package devpack

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
)

// RenderWorkbenchFiles is byte for byte what InstallWorkbench writes into a
// fresh folder for the same options: the .claude files of a real install
// all appear in the render, unchanged, and nothing is written to o.Folder.
func TestRenderWorkbenchFiles_MatchesAFreshInstall(t *testing.T) {
	folder := fakeRepo(t)
	o := workbenchOpts(folder, newFakeClaude())
	other := t.TempDir()
	ro := o
	ro.Folder = other

	files, err := RenderWorkbenchFiles(ro)
	if err != nil {
		t.Fatal(err)
	}
	if entries, _ := os.ReadDir(other); len(entries) != 0 {
		t.Fatalf("the render wrote into o.Folder: %v", entries)
	}
	if _, err := InstallWorkbench(context.Background(), o); err != nil {
		t.Fatalf("install: %v", err)
	}
	installed := 0
	err = filepath.WalkDir(filepath.Join(folder, ".claude"), func(p string, d os.DirEntry, err error) error {
		if err != nil || !d.Type().IsRegular() {
			return err
		}
		rel, _ := filepath.Rel(folder, p)
		got, err := os.ReadFile(p) //nolint:gosec // G122: the test's own temp folder
		if err != nil {
			return err
		}
		want, ok := files[filepath.ToSlash(rel)]
		if !ok || !bytes.Equal(got, want) {
			t.Errorf("%s: installed and rendered differ (rendered: %v)", rel, ok)
		}
		installed++
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if installed == 0 {
		t.Fatal("the install wrote no .claude files")
	}
	for _, rel := range []string{
		".claude/settings.local.json",
		".claude/skills/" + WorkbenchSkillName + "/SKILL.md",
		".claude/skills/" + FlowSkillName + "/SKILL.md",
		".agents/skills/" + WorkbenchSkillName + "/SKILL.md",
	} {
		if _, ok := files[rel]; !ok {
			t.Errorf("%s not rendered; got %d files", rel, len(files))
		}
	}
}
