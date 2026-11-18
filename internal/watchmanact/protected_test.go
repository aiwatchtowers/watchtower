package watchmanact

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fixtureInventory writes an inventory directory with the contract headings
// the §13 phrasings name.
func fixtureInventory(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "docs", "inventory")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		"workbench.md": "# Workbench\n\n## PROJ-12 — Ask answer delivery\n\nx\n\n## PROJ-13 — Ask guard\n\n" +
			"## PROJ-14 — Finish gate\n\n## PROJ-21 — Permission answers\n\n## Changelog\n",
		"review.md": "# Review\n\n## REVIEW-01 — Rounds\n",
		"README.md": "# Inventory\n\nModule → file mapping.\n",
	}
	for name, text := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func spec13(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "spec13_contracts.md"))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// spec13Line is the line of the §13 copy that starts with prefix.
func spec13Line(t *testing.T, prefix string) string {
	t.Helper()
	for line := range strings.SplitSeq(spec13(t), "\n") {
		if strings.HasPrefix(line, prefix) {
			return line
		}
	}
	t.Fatalf("no §13 line starts with %q", prefix)
	return ""
}

func TestProtectedDoc(t *testing.T) {
	inv := fixtureInventory(t)
	cases := []struct {
		name, doc string
		parked    bool
	}{
		{"finish gate change", "PROJ-14 (finish_session): in an armed session the finish gate waits for the twin's review Approve", true},
		{"third decider", "PROJ-21 (permission answers): a third decider besides Mac and phone", true},
		{"follows unchanged", "The answer follows PROJ-12 unchanged.", false},
		{"not changed", "PROJ-13 is the ask guard and is not changed", false},
		{"id without a marker", "see PROJ-12", true},
		{"table row unchanged", "| Contract | State |\n|---|---|\n| PROJ-21 | unchanged |", false},
		{"family wildcard", "REVIEW-0x gains a twin Approve", true},
		{"marker on the next line", "The delivery follows PROJ-12\nunchanged, as before.", true},
		{"bullet list without blank lines", "- PROJ-13 (the ask guard) is not changed\n- PROJ-21: a third decider", true},
		{"spec §13 PROJ-12 line", spec13Line(t, "- **PROJ-12**"), true},
		{"two ids unchanged", "PROJ-12 and PROJ-21 unchanged", true},
		{"shorthand is two ids", "Go hub (PROJ-12/21 on the hub): its phone behaviour is unchanged", true},
		{"spec §13 block", spec13(t), true},
		{"guard test name", "Rename TestWATCHMAN01_X later.", true},
		{"inventory path", "Edit docs/inventory/x.md.", true},
		{"no contract ids", "# Plan\n\n- Task 1: add the export button\n- Task 2: tests", false},
		{"unknown prefix", "See ACME-12 and FOO-0x.", false},
		{"prefix inside a word", "SPECREVIEWS-12 is not one of ours", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			reason, parked := ProtectedDoc(inv, c.doc)
			if parked != c.parked {
				t.Fatalf("ProtectedDoc(%q) = %q, %v; want parked %v", c.doc, reason, parked, c.parked)
			}
			if parked && reason == "" {
				t.Fatal("a park names its reason")
			}
		})
	}
}

func TestProtectedDoc_InventoryDir(t *testing.T) {
	t.Run("absent: ids are not contracts, guard names still park", func(t *testing.T) {
		absent := filepath.Join(t.TempDir(), "docs", "inventory")
		if _, parked := ProtectedDoc(absent, "see PROJ-12"); parked {
			t.Fatal("no inventory: no ids")
		}
		if _, parked := ProtectedDoc(absent, "func TestProj12_Delivery"); !parked {
			t.Fatal("a guard-test name parks without an inventory")
		}
	})
	t.Run("unreadable parks", func(t *testing.T) {
		dir := fixtureInventory(t)
		if err := os.Chmod(dir, 0o000); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })
		if _, err := os.ReadDir(dir); err == nil {
			t.Skip("running with permissions that read a mode-000 directory")
		}
		reason, parked := ProtectedDoc(dir, "a plan with no contract ids")
		if !parked || reason != "inventory unreadable" {
			t.Fatalf("got %q, %v; want inventory unreadable", reason, parked)
		}
	})
	t.Run("files without headings park", func(t *testing.T) {
		dir := filepath.Join(t.TempDir(), "inventory")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "x.md"), []byte("# Nothing here\n\n## Changelog\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		reason, parked := ProtectedDoc(dir, "a plan with no contract ids")
		if !parked || reason != "inventory unreadable" {
			t.Fatalf("got %q, %v; want inventory unreadable", reason, parked)
		}
	})
}

func TestProtectedChange(t *testing.T) {
	hunk := func(path string, lines ...string) string {
		return "diff --git a/" + path + " b/" + path + "\n--- a/" + path + "\n+++ b/" + path + "\n@@ -1,3 +1,3 @@\n" +
			strings.Join(lines, "\n") + "\n"
	}
	cases := []struct {
		name  string
		paths []string
		diff  string
		want  bool
	}{
		{"inventory file", []string{"docs/inventory/watchman.md"}, hunk("docs/inventory/watchman.md", "+x"), true},
		{"adds a guard test", []string{"internal/x/x_test.go"}, hunk("internal/x/x_test.go", "+func TestWATCHMAN07_X(t *testing.T) {", "+}"), true},
		{"changes a guard test's body", []string{"internal/x/x_test.go"},
			hunk("internal/x/x_test.go", " func TestProj21_Decider(t *testing.T) {", "-\tassert(a)", "+\tassert(b)"), true},
		{"guard test in the hunk header", []string{"internal/x/x_test.go"},
			"diff --git a/x_test.go b/x_test.go\n@@ -40,3 +40,3 @@ func TestProj21_Decider(t *testing.T) {\n-\ta\n+\tb\n", true},
		{"deletes a Swift guard test", []string{"Tests/XTests.swift"}, hunk("Tests/XTests.swift", "-    func testProj20_Panel() {", "-    }"), true},
		{"ordinary test", []string{"internal/x/x_test.go"}, hunk("internal/x/x_test.go", " func TestFoo(t *testing.T) {", "-\ta", "+\tb"), false},
		{"feature doc", []string{"docs/features/x.md"}, hunk("docs/features/x.md", "+PROJ-12 is mentioned here"), false},
		{"a guard name outside any hunk", []string{"a.go"}, "diff --git a/a.go b/a.go\n--- a/func TestProj21_X\n", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			reason, got := ProtectedChange(c.paths, c.diff)
			if got != c.want {
				t.Fatalf("ProtectedChange = %q, %v; want %v", reason, got, c.want)
			}
			if got && reason == "" {
				t.Fatal("a protected change names its reason")
			}
		})
	}
}
