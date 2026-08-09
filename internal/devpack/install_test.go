package devpack

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInstallWritesThePackAndIsIdempotent(t *testing.T) {
	dir := t.TempDir()

	first, err := Install(dir)
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	if len(first) != len(Skills()) {
		t.Fatalf("expected a status per skill, got %d", len(first))
	}
	for _, s := range first {
		if s.State != StateInstalled {
			t.Fatalf("%s: expected installed on a fresh dir, got %s", s.Name, s.State)
		}
		if _, err := os.Stat(s.Path); err != nil {
			t.Fatalf("%s: file not written: %v", s.Name, err)
		}
	}

	second, err := Install(dir)
	if err != nil {
		t.Fatalf("reinstall: %v", err)
	}
	for _, s := range second {
		if s.State != StateUnchanged {
			t.Fatalf("%s: re-running install must be a no-op, got %s", s.Name, s.State)
		}
	}
}

func TestInstallNeverClobbersAUserEditedSkill(t *testing.T) {
	dir := t.TempDir()
	if _, err := Install(dir); err != nil {
		t.Fatalf("install: %v", err)
	}

	target := filepath.Join(dir, "watchtower-who-to-ask", "SKILL.md")
	edited := "---\nname: watchtower-who-to-ask\ndescription: mine now\n" +
		MarkerKey + ": v1\n---\n\nMy own instructions.\n"
	if err := os.WriteFile(target, []byte(edited), 0o644); err != nil {
		t.Fatalf("editing: %v", err)
	}

	got, err := Install(dir)
	if err != nil {
		t.Fatalf("reinstall: %v", err)
	}
	for _, s := range got {
		if s.Name == "watchtower-who-to-ask" && s.State != StateDrifted {
			t.Fatalf("expected drifted, got %s", s.State)
		}
	}
	after, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("reading back: %v", err)
	}
	if string(after) != edited {
		t.Fatalf("DEV-04 violated: a user-edited skill was overwritten")
	}
}

func TestRemoveDeletesOnlyMarkedFiles(t *testing.T) {
	dir := t.TempDir()
	if _, err := Install(dir); err != nil {
		t.Fatalf("install: %v", err)
	}

	// A neighbouring skill that is not ours, in the same directory.
	foreignDir := filepath.Join(dir, "someones-own-skill")
	if err := os.MkdirAll(foreignDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	foreign := filepath.Join(foreignDir, "SKILL.md")
	if err := os.WriteFile(foreign, []byte("---\nname: someones-own-skill\n---\n"), 0o644); err != nil {
		t.Fatalf("write foreign: %v", err)
	}

	// A skill with our name but no marker — must be treated as foreign.
	unmarked := filepath.Join(dir, "watchtower-task-context", "SKILL.md")
	if err := os.WriteFile(unmarked, []byte("---\nname: watchtower-task-context\n---\nmine\n"), 0o644); err != nil {
		t.Fatalf("write unmarked: %v", err)
	}

	if _, err := Remove(dir); err != nil {
		t.Fatalf("remove: %v", err)
	}

	if _, err := os.Stat(foreign); err != nil {
		t.Fatalf("remove deleted a foreign skill: %v", err)
	}
	if _, err := os.Stat(unmarked); err != nil {
		t.Fatalf("remove deleted an unmarked file bearing our name: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "watchtower-why-decision", "SKILL.md")); !os.IsNotExist(err) {
		t.Fatalf("expected our marked skill to be gone, got err=%v", err)
	}
}

func TestStatusReportsMissingWithoutWriting(t *testing.T) {
	dir := t.TempDir()

	got, err := Status(dir)
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	for _, s := range got {
		if s.State != StateMissing {
			t.Fatalf("%s: expected missing, got %s", s.Name, s.State)
		}
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("status must not write anything, found %d entries", len(entries))
	}
}
