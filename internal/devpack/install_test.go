package devpack

import (
	"crypto/sha256"
	"encoding/hex"
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

	// A companion resource dropped next to a skill we DO own (scripts/,
	// references/, a user's own note) — Remove must delete only SKILL.md
	// and its sidecar, never sweep the whole directory.
	ownedDir := filepath.Join(dir, "watchtower-why-decision")
	companion := filepath.Join(ownedDir, "notes.txt")
	if err := os.WriteFile(companion, []byte("do not delete me"), 0o644); err != nil {
		t.Fatalf("write companion: %v", err)
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
	if _, err := os.Stat(companion); err != nil {
		t.Fatalf("remove deleted a companion file next to an owned skill: %v", err)
	}
	if _, err := os.Stat(ownedDir); err != nil {
		t.Fatalf("remove deleted the skill directory even though a companion file remained: %v", err)
	}
}

// TestInstallSelfHealsASidecarLostToACrash covers the case where a previous
// Install wrote SKILL.md but crashed before writing the shipped-digest
// sidecar. It uses installSkill directly with two synthetic Skill versions,
// since the real embedded pack has no second version to upgrade to.
func TestInstallSelfHealsASidecarLostToACrash(t *testing.T) {
	dir := t.TempDir()

	v1 := skillWithDigest("crash-test", "version one\n")

	// Simulate the crash: the file landed on disk exactly as we would have
	// written it, but the sidecar never got written.
	skillDir := filepath.Join(dir, v1.Name)
	if err := os.MkdirAll(skillDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	skillFile := filepath.Join(skillDir, "SKILL.md")
	if err := os.WriteFile(skillFile, []byte(v1.Content), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := os.Stat(filepath.Join(skillDir, shippedDigestFile)); !os.IsNotExist(err) {
		t.Fatalf("test setup: sidecar should not exist yet, got err=%v", err)
	}

	// An ordinary Install run against the SAME version sees Unchanged, and —
	// this is the fix — must repair the missing sidecar as a side effect.
	status, err := installSkill(dir, v1)
	if err != nil {
		t.Fatalf("installSkill v1: %v", err)
	}
	if status.State != StateUnchanged {
		t.Fatalf("expected unchanged, got %s", status.State)
	}
	if _, err := os.Stat(filepath.Join(skillDir, shippedDigestFile)); err != nil {
		t.Fatalf("sidecar was not repaired: %v", err)
	}

	// Now the pack ships a new version. Without the repair above, the
	// missing sidecar would make this untouched file look user-edited
	// (Drifted) forever, instead of being safely upgraded.
	v2 := skillWithDigest("crash-test", "version two\n")

	status, err = installSkill(dir, v2)
	if err != nil {
		t.Fatalf("installSkill v2: %v", err)
	}
	if status.State != StateUpdated {
		t.Fatalf("expected updated (not drifted — DEV-04's false positive), got %s", status.State)
	}
	after, err := os.ReadFile(skillFile)
	if err != nil {
		t.Fatalf("reading back: %v", err)
	}
	if string(after) != v2.Content {
		t.Fatalf("file was not upgraded to the new version's content")
	}
}

// skillWithDigest builds a synthetic Skill whose content carries a real
// frontmatter marker, matching what the actual pack ships (HasMarker only
// matches within the frontmatter block).
func skillWithDigest(name, body string) Skill {
	content := "---\nname: " + name + "\n" + MarkerKey + ": v1\n---\n\n" + body
	sum := sha256.Sum256([]byte(content))
	return Skill{Name: name, Content: content, SHA256: hex.EncodeToString(sum[:])}
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
