package skills

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// statesByName indexes a Deploy result for assertions.
func statesByName(statuses []DeployStatus) map[string]DeployState {
	m := map[string]DeployState{}
	for _, s := range statuses {
		m[s.Name] = s.State
	}
	return m
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading %s: %v", path, err)
	}
	return string(b)
}

func readSidecarMap(t *testing.T, dir string) map[string]string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, sidecarFile))
	if err != nil {
		t.Fatalf("reading sidecar: %v", err)
	}
	m := map[string]string{}
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("decoding sidecar: %v", err)
	}
	return m
}

// TestDeployFreshInstall: an empty (or missing) directory gets the whole pack,
// and the catalog can list it afterwards.
func TestDeployFreshInstall(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "skills")

	statuses, err := Deploy(dir)
	if err != nil {
		t.Fatalf("deploy: %v", err)
	}
	pack := Shipped()
	if len(statuses) != len(pack) {
		t.Fatalf("expected %d statuses, got %d", len(pack), len(statuses))
	}
	states := statesByName(statuses)
	sidecar := readSidecarMap(t, dir)
	for _, s := range pack {
		if states[s.Name] != StateInstalled {
			t.Errorf("%s = %s, want installed", s.Name, states[s.Name])
		}
		if got := readFile(t, filepath.Join(dir, s.Name+fileExt)); got != s.Content {
			t.Errorf("%s content on disk differs from the shipped bytes", s.Name)
		}
		if sidecar[s.Name] != s.SHA256 {
			t.Errorf("sidecar digest for %s = %q, want %q", s.Name, sidecar[s.Name], s.SHA256)
		}
	}

	list, skipped, err := ListWithSkips(dir)
	if err != nil {
		t.Fatalf("listing after deploy: %v", err)
	}
	if len(list) != len(pack) || len(skipped) != 0 {
		t.Fatalf("expected the deployed pack to list cleanly, got %d skills / %d skips", len(list), len(skipped))
	}
}

// TestDeployIdempotent: a second run changes nothing and reports unchanged.
func TestDeployIdempotent(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "skills")
	if _, err := Deploy(dir); err != nil {
		t.Fatalf("first deploy: %v", err)
	}
	statuses, err := Deploy(dir)
	if err != nil {
		t.Fatalf("second deploy: %v", err)
	}
	for _, s := range statuses {
		if s.State != StateUnchanged {
			t.Errorf("%s = %s on a repeat deploy, want unchanged", s.Name, s.State)
		}
	}
}

// TestDeployCleanUpgradeReplaces: a file we shipped and the owner never
// touched is replaced by the new version.
func TestDeployCleanUpgradeReplaces(t *testing.T) {
	dir := t.TempDir()
	old := ShippedSkill{Name: "demo", Content: "---\ndescription: v1.\npersona: secretary\n---\nold body\n"}
	old.SHA256 = digestOf(old.Content)
	file := filepath.Join(dir, "demo.md")
	if err := os.WriteFile(file, []byte(old.Content), 0o644); err != nil {
		t.Fatalf("seeding old version: %v", err)
	}
	if err := writeSidecar(dir, map[string]string{"demo": old.SHA256}); err != nil {
		t.Fatalf("seeding sidecar: %v", err)
	}

	next := ShippedSkill{Name: "demo", Content: "---\ndescription: v2.\npersona: secretary\n---\nnew body\n"}
	next.SHA256 = digestOf(next.Content)
	recorded, err := readSidecar(dir)
	if err != nil {
		t.Fatalf("reading sidecar: %v", err)
	}
	state, err := planFor(file, next, recorded)
	if err != nil {
		t.Fatalf("planFor: %v", err)
	}
	if state != StateUpdated {
		t.Fatalf("state = %s, want updated", state)
	}
}

// TestDeployOwnerEditedUntouched: once the owner edits a shipped file it is
// theirs — every later Deploy leaves it exactly as it is.
func TestDeployOwnerEditedUntouched(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "skills")
	if _, err := Deploy(dir); err != nil {
		t.Fatalf("first deploy: %v", err)
	}
	victim := Shipped()[0].Name
	file := filepath.Join(dir, victim+fileExt)
	edited := "---\ndescription: My own version.\npersona: secretary\n---\nowner text\n"
	if err := os.WriteFile(file, []byte(edited), 0o644); err != nil {
		t.Fatalf("editing: %v", err)
	}

	statuses, err := Deploy(dir)
	if err != nil {
		t.Fatalf("second deploy: %v", err)
	}
	if got := statesByName(statuses)[victim]; got != StateDrifted {
		t.Errorf("%s = %s, want drifted", victim, got)
	}
	if got := readFile(t, file); got != edited {
		t.Errorf("owner-edited file was overwritten")
	}

	// And it stays theirs on the run after that (the sidecar was not moved).
	statuses, err = Deploy(dir)
	if err != nil {
		t.Fatalf("third deploy: %v", err)
	}
	if got := statesByName(statuses)[victim]; got != StateDrifted {
		t.Errorf("%s = %s on the third run, want drifted", victim, got)
	}
	if got := readFile(t, file); got != edited {
		t.Errorf("owner-edited file was overwritten on the third run")
	}
}

// TestDeployForeignFileUntouched: a file the owner wrote under a name we also
// ship was never ours, so we never write over it.
func TestDeployForeignFileUntouched(t *testing.T) {
	dir := t.TempDir()
	victim := Shipped()[0].Name
	file := filepath.Join(dir, victim+fileExt)
	foreign := "---\ndescription: Mine, written first.\npersona: assistant\n---\nforeign body\n"
	if err := os.WriteFile(file, []byte(foreign), 0o644); err != nil {
		t.Fatalf("seeding foreign file: %v", err)
	}

	statuses, err := Deploy(dir)
	if err != nil {
		t.Fatalf("deploy: %v", err)
	}
	if got := statesByName(statuses)[victim]; got != StateForeign {
		t.Errorf("%s = %s, want foreign", victim, got)
	}
	if got := readFile(t, file); got != foreign {
		t.Errorf("foreign file was overwritten")
	}
	// The other shipped skills still installed normally around it.
	for _, s := range Shipped() {
		if s.Name == victim {
			continue
		}
		if got := statesByName(statuses)[s.Name]; got != StateInstalled {
			t.Errorf("%s = %s, want installed", s.Name, got)
		}
	}
	// The foreign file never enters the sidecar, so it stays foreign forever.
	if _, ours := readSidecarMap(t, dir)[victim]; ours {
		t.Errorf("foreign file must never be recorded as ours")
	}
}

// TestDeployRepairsSidecar: the crash window between writing a file and
// writing the sidecar heals on the next ordinary Deploy, so an untouched file
// is never mislabelled as owner-drifted later.
func TestDeployRepairsSidecar(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "skills")
	if _, err := Deploy(dir); err != nil {
		t.Fatalf("first deploy: %v", err)
	}
	if err := os.Remove(filepath.Join(dir, sidecarFile)); err != nil {
		t.Fatalf("removing sidecar: %v", err)
	}

	statuses, err := Deploy(dir)
	if err != nil {
		t.Fatalf("second deploy: %v", err)
	}
	for _, s := range statuses {
		if s.State != StateUnchanged {
			t.Errorf("%s = %s, want unchanged", s.Name, s.State)
		}
	}
	sidecar := readSidecarMap(t, dir)
	for _, s := range Shipped() {
		if sidecar[s.Name] != s.SHA256 {
			t.Errorf("sidecar was not repaired for %s", s.Name)
		}
	}
}

// TestDeployCorruptSidecar: an unparseable sidecar degrades to "we shipped
// nothing" — files are left alone rather than clobbered — and is rewritten.
func TestDeployCorruptSidecar(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "skills")
	if _, err := Deploy(dir); err != nil {
		t.Fatalf("first deploy: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, sidecarFile), []byte("{not json"), 0o644); err != nil {
		t.Fatalf("corrupting sidecar: %v", err)
	}

	statuses, err := Deploy(dir)
	if err != nil {
		t.Fatalf("second deploy: %v", err)
	}
	for _, s := range statuses {
		if s.State != StateUnchanged {
			t.Errorf("%s = %s, want unchanged", s.Name, s.State)
		}
	}
	if len(readSidecarMap(t, dir)) != len(Shipped()) {
		t.Errorf("sidecar was not rebuilt after corruption")
	}
}
