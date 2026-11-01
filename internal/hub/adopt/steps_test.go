package adopt

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/state/swiftfixture"
)

var errKilled = errors.New("killed")

// killPoints are every point a kill can land between two commits: after
// each step, and inside the steps that touch several files.
var killPoints = []string{
	"copy", "verify",
	"rename:assets", "rename:transport", "rename:state", "rename",
	"migrate",
	"recordings:files", "recordings",
	"settings", "transport",
	"moved:note", "moved",
	"done",
}

// killAt makes Run stop at point, once, as a kill there would.
func killAt(t *testing.T, point string) {
	t.Helper()
	fired := false
	prev := stepHook
	stepHook = func(p string) error {
		if p == point && !fired {
			fired = true
			return errKilled
		}
		return nil
	}
	t.Cleanup(func() { stepHook = prev })
}

// TestAdoptResumesAfterAKillAtEveryStep (Review Focus 1): a run killed at
// any point leaves no hub id but the Swift one, and the next run finishes
// the same adoption — the end state equals an uninterrupted run's, with one
// copy of every row.
func TestAdoptResumesAfterAKillAtEveryStep(t *testing.T) {
	ref := newFixtureIn(t, filepath.Join(t.TempDir(), "mac"), swiftfixture.Schema)
	ref.mustRun(t)
	want := ref.snapshot(t)

	// Every point fires in an uninterrupted run.
	seen := map[string]bool{}
	prev := stepHook
	stepHook = func(p string) error { seen[p] = true; return nil }
	probe := newFixture(t)
	probe.mustRun(t)
	stepHook = prev
	for _, p := range killPoints {
		if !seen[p] {
			t.Fatalf("kill point %q never reached", p)
		}
	}

	for _, point := range killPoints {
		t.Run(point, func(t *testing.T) {
			f := newFixtureIn(t, filepath.Join(t.TempDir(), "mac"), swiftfixture.Schema)
			killAt(t, point)
			if _, err := f.run(t); !errors.Is(err, errKilled) {
				t.Fatalf("killed run = %v", err)
			}
			// Between the runs: one hub id wherever the state is, no
			// adopted_at before done, and the Swift sidecar still there
			// until the moved step removed it.
			rep, err := Status(f.mobile, f.hub)
			if err != nil {
				t.Fatal(err)
			}
			if rep.HubID != fixtureHubID {
				t.Fatalf("hub_id after a kill at %s = %q", point, rep.HubID)
			}
			if exists(filepath.Join(f.hub, state.FileName)) {
				if v, _ := readMeta(filepath.Join(f.hub, state.FileName), MetaAdoptedAt); v[MetaAdoptedAt] != "" && point != "done" {
					t.Fatalf("adopted_at set after a kill at %s", point)
				}
			}
			res, err := f.run(t)
			if point == "done" {
				// done committed before the kill: the adoption is finished.
				if !errors.Is(err, ErrAlreadyAdopted) {
					t.Fatalf("run after a kill at done = %+v %v", res, err)
				}
			} else if err != nil || res.Step != StepDone {
				t.Fatalf("resumed run = %+v %v", res, err)
			}
			if got := f.snapshot(t); got != want {
				t.Fatalf("end state after a kill at %s differs:\n--- got\n%s\n--- want\n%s", point, got, want)
			}
			if _, err := f.run(t); !errors.Is(err, ErrAlreadyAdopted) {
				t.Fatalf("third run = %v", err)
			}
		})
	}
}

// withoutColumn is the Swift schema of an app without one ALTER column.
func withoutColumn(col string) []string {
	var out []string
	for _, s := range swiftfixture.Schema {
		if !strings.Contains(s, "ADD COLUMN "+col+" ") {
			out = append(out, s)
		}
	}
	return out
}

func TestAdoptRefusesAMissingFoldedInColumn(t *testing.T) {
	f := newFixtureIn(t, t.TempDir(), withoutColumn("last_seq"))
	swift := filepath.Join(f.mobile, state.FileName)
	before, _ := os.ReadFile(swift)
	res, err := f.run(t)
	if !errors.Is(err, ErrSwiftSchema) || res.Error != ClassSwiftSchema || res.Step != StepVerify {
		t.Fatalf("Run = %+v %v", res, err)
	}
	if exists(filepath.Join(f.hub, state.FileName)) || exists(filepath.Join(f.mobile, MovedName)) {
		t.Fatal("something moved")
	}
	if b, _ := os.ReadFile(swift); !bytes.Equal(b, before) {
		t.Fatal("the Swift sidecar changed")
	}
	rep, err := Status(f.mobile, f.hub)
	if err != nil {
		t.Fatal(err)
	}
	if rep.Error != ClassSwiftSchema || rep.SwiftState != "present" || rep.HubID != fixtureHubID {
		t.Fatalf("status = %+v", rep)
	}
	if err := CheckSwiftFile(swift); !errors.Is(err, ErrSwiftSchema) {
		t.Fatalf("CheckSwiftFile = %v", err)
	}
	if err := CheckSwiftFile(filepath.Join(newFixture(t).mobile, state.FileName)); err != nil {
		t.Fatalf("CheckSwiftFile on today's file = %v", err)
	}
}
