package devpack

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestRender_FixedPosition(t *testing.T) {
	s := skillWithDigest("x", "# X\nbody\n")
	got := Render(s, []string{"Be brief.", "Cite ids."})
	want := "---\nname: x\nx-watchtower-pack: v1\n---\n\n## Owner additions (approved by the owner)\n\nBe brief.\nCite ids.\n\n# X\nbody\n"
	if got.Content != want {
		t.Fatalf("rendered:\n%q\nwant:\n%q", got.Content, want)
	}
	sum := sha256.Sum256([]byte(want))
	if got.SHA256 != hex.EncodeToString(sum[:]) || got.Name != "x" {
		t.Fatalf("digest/name not of the rendered bytes: %+v", got)
	}
	if !HasMarker(got.Content) {
		t.Fatal("the rendered skill must still carry the marker")
	}
	if Render(s, nil) != s || Render(s, []string{"", "  "}) != s {
		t.Fatal("no lines must leave the skill unchanged")
	}
}

func TestPackSkillNames_CoverThePackAndTheWorkbenchSkills(t *testing.T) {
	names := PackSkillNames()
	if !slices.IsSorted(names) {
		t.Fatalf("not sorted: %v", names)
	}
	for _, s := range Skills() {
		if !slices.Contains(names, s.Name) {
			t.Fatalf("%s missing from %v", s.Name, names)
		}
	}
	for _, n := range []string{WorkbenchSkillName, FlowSkillName} {
		if !slices.Contains(names, n) {
			t.Fatalf("%s missing from %v", n, names)
		}
	}
	for _, n := range names {
		s, ok := PackSkill(n)
		if !ok || s.Name != n {
			t.Fatalf("PackSkill(%q) = %+v, %v", n, s, ok)
		}
		// Every pack skill renders at the fixed position (it has a frontmatter).
		if r := Render(s, []string{"Be brief."}); r.Content == s.Content {
			t.Fatalf("%s did not render an overlay", n)
		}
	}
	if _, ok := PackSkill("acme-unknown"); ok {
		t.Fatal("an unknown name must not resolve")
	}
}

func TestInstall_OverlayIsNotDrift(t *testing.T) {
	dir := t.TempDir()
	name := Skills()[0].Name
	ov := Overlays{name: {"Be brief."}}
	got, err := Install(dir, ov)
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	if got[0].State != StateInstalled {
		t.Fatalf("first install: %+v", got[0])
	}
	rendered := Render(Skills()[0], ov[name])
	if readTestFile(t, got[0].Path) != rendered.Content {
		t.Fatal("the installed copy must be the rendered skill")
	}
	st, err := Status(dir, ov)
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if st[0].State != StateUnchanged {
		t.Fatalf("a rendered copy must not read as drift: %+v", st[0])
	}
	digest, err := readShippedDigest(filepath.Dir(got[0].Path))
	if err != nil || digest != rendered.SHA256 {
		t.Fatalf("sidecar = %q (%v), want the rendered digest", digest, err)
	}
}

func TestInstall_UpgradeCarriesOverlay(t *testing.T) {
	dir := t.TempDir()
	lines := []string{"Be brief."}
	v1 := Render(skillWithDigest("acme", "# Acme v1\n"), lines)
	if _, err := installSkill(dir, v1); err != nil {
		t.Fatalf("v1: %v", err)
	}
	v2 := Render(skillWithDigest("acme", "# Acme v2\n"), lines)
	st, err := installSkill(dir, v2)
	if err != nil {
		t.Fatalf("v2: %v", err)
	}
	if st.State != StateUpdated {
		t.Fatalf("upgrade: %+v", st)
	}
	if readTestFile(t, st.Path) != v2.Content {
		t.Fatal("the upgraded copy must be the new shipped skill with the overlay block")
	}
}

func TestRerenderSkill_OverlayChangeUpdates(t *testing.T) {
	dir := t.TempDir()
	if _, err := Install(dir, nil); err != nil {
		t.Fatalf("install: %v", err)
	}
	name := Skills()[0].Name
	st, err := RerenderSkill(dir, name, []string{"Be brief."})
	if err != nil || st != StateUpdated {
		t.Fatalf("rerender: %v %v", st, err)
	}
	file := filepath.Join(dir, name, "SKILL.md")
	want := Render(Skills()[0], []string{"Be brief."})
	if readTestFile(t, file) != want.Content {
		t.Fatal("the copy must hold the overlay")
	}
	if d, _ := readShippedDigest(filepath.Dir(file)); d != want.SHA256 {
		t.Fatalf("sidecar %q, want the rendered digest", d)
	}
	if st, err = RerenderSkill(dir, name, []string{"Be brief."}); err != nil || st != StateUnchanged {
		t.Fatalf("same lines again: %v %v", st, err)
	}
	// Removing the last line renders the shipped skill back.
	if st, err = RerenderSkill(dir, name, nil); err != nil || st != StateUpdated {
		t.Fatalf("rerender without lines: %v %v", st, err)
	}
	if readTestFile(t, file) != Skills()[0].Content {
		t.Fatal("the copy must be the shipped skill again")
	}
}

func TestRerenderSkill_HandEditedCopyUntouched(t *testing.T) {
	dir := t.TempDir()
	name := Skills()[0].Name
	if _, err := Install(dir, Overlays{name: {"Be brief."}}); err != nil {
		t.Fatalf("install: %v", err)
	}
	file := filepath.Join(dir, name, "SKILL.md")
	edited := readTestFile(t, file) + "\nMy own note.\n"
	if err := os.WriteFile(file, []byte(edited), 0o644); err != nil {
		t.Fatal(err)
	}
	st, err := RerenderSkill(dir, name, []string{"Be brief.", "Cite ids."})
	if err != nil || st != StateDrifted {
		t.Fatalf("rerender: %v %v", st, err)
	}
	if readTestFile(t, file) != edited {
		t.Fatal("a hand-edited copy must stay byte-identical (DEV-04)")
	}
}

func TestRerenderSkill_MissingCopyNotCreated(t *testing.T) {
	dir := t.TempDir()
	st, err := RerenderSkill(dir, WorkbenchSkillName, []string{"Be brief."})
	if err != nil || st != StateMissing {
		t.Fatalf("rerender: %v %v", st, err)
	}
	if _, err := os.Stat(filepath.Join(dir, WorkbenchSkillName)); !os.IsNotExist(err) {
		t.Fatalf("nothing may be created: %v", err)
	}
	if _, err := RerenderSkill(dir, "acme-unknown", nil); err == nil {
		t.Fatal("an unknown skill must be an error")
	}
}

func TestInstallWorkbench_OverlaysRenderedIntoBothSkills(t *testing.T) {
	folder := fakeRepo(t)
	o := workbenchOpts(folder, newFakeClaude())
	o.Overlays = Overlays{WorkbenchSkillName: {"Be brief."}, FlowSkillName: {"Plan first."}}
	rep, err := InstallWorkbench(context.Background(), o)
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	if readTestFile(t, rep.Skill.Path) != Render(workbenchSkill(), []string{"Be brief."}).Content {
		t.Fatal("the core copy must carry its overlay")
	}
	if readTestFile(t, rep.Flow.Path) != Render(flowSkill(), []string{"Plan first."}).Content {
		t.Fatal("the preset copy must carry its overlay")
	}
	st, err := StatusWorkbench(context.Background(), o)
	if err != nil || st.Skill.State != StateUnchanged {
		t.Fatalf("status: %+v %v", st.Skill, err)
	}
}

func TestInstallWorkbench_OverlaysUnreadKeepsCopies(t *testing.T) {
	folder := fakeRepo(t)
	f := newFakeClaude()
	o := workbenchOpts(folder, f)
	o.Overlays = Overlays{WorkbenchSkillName: {"Be brief."}, FlowSkillName: {"Plan first."}}
	rep, err := InstallWorkbench(context.Background(), o)
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	core, flow := readTestFile(t, rep.Skill.Path), readTestFile(t, rep.Flow.Path)

	unread := workbenchOpts(folder, f)
	unread.OverlaysUnread = true
	if _, err := InstallWorkbench(context.Background(), unread); err != nil {
		t.Fatalf("resync: %v", err)
	}
	unread.PresetNone = true // not even a preset removal writes
	if _, err := SyncMethodology(unread); err != nil {
		t.Fatalf("methodology: %v", err)
	}
	if readTestFile(t, rep.Skill.Path) != core || readTestFile(t, rep.Flow.Path) != flow {
		t.Fatal("with unread overlays the copies must stay byte-identical")
	}
}

func TestInstallMissing_InstallsAbsentKeepsExisting(t *testing.T) {
	dir := t.TempDir()
	skills := Skills()
	name := skills[0].Name
	if _, err := Install(dir, Overlays{name: {"Be brief."}}); err != nil {
		t.Fatalf("install: %v", err)
	}
	rendered := readTestFile(t, filepath.Join(dir, name, "SKILL.md"))
	if len(skills) > 1 {
		if err := os.RemoveAll(filepath.Join(dir, skills[1].Name)); err != nil {
			t.Fatal(err)
		}
	}
	got, err := InstallMissing(dir)
	if err != nil {
		t.Fatalf("install missing: %v", err)
	}
	if readTestFile(t, filepath.Join(dir, name, "SKILL.md")) != rendered {
		t.Fatal("an existing copy must keep its overlay lines")
	}
	if len(skills) > 1 && got[1].State != StateInstalled {
		t.Fatalf("a missing skill must be installed: %+v", got[1])
	}
}

func TestInstallWorkbench_OverlaysUnreadInstallsAFreshFolder(t *testing.T) {
	folder := fakeRepo(t)
	o := workbenchOpts(folder, newFakeClaude())
	o.OverlaysUnread = true
	rep, err := InstallWorkbench(context.Background(), o)
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	if rep.Skill.State != StateInstalled || rep.Flow.State != StateInstalled {
		t.Fatalf("a fresh folder must get both skills: %+v %+v", rep.Skill, rep.Flow)
	}
}
