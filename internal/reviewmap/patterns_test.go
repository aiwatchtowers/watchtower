package reviewmap

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestParsePatterns(t *testing.T) {
	text := "\xef\xbb\xbf# Review map\n" +
		"## Breaking\n- docs/inventory/**\n- **/*guard*_test.go\n\n" +
		"## significant\n-   internal/tools/**  \n- [bad\n" +
		"## Can skip\n- WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift\n-\n" +
		"## Other\n- ignored/**\n" +
		"free text\n"
	p := ParsePatterns(text)
	if !slices.Equal(p.Breaking, []string{"docs/inventory/**", "**/*guard*_test.go"}) {
		t.Errorf("Breaking = %v", p.Breaking)
	}
	if !slices.Equal(p.Significant, []string{"internal/tools/**"}) {
		t.Errorf("Significant = %v", p.Significant)
	}
	if !slices.Equal(p.Skip, []string{"WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift"}) {
		t.Errorf("Skip = %v", p.Skip)
	}
	wantNotes := []string{
		`.watchtower/review-map.md: line 1: unknown section "Review map"`,
		`.watchtower/review-map.md: line 8: bad glob "[bad"`,
		`.watchtower/review-map.md: line 11: empty glob`,
		`.watchtower/review-map.md: line 12: unknown section "Other"`,
		`.watchtower/review-map.md: line 14: not a "## Breaking|Significant|Can skip" heading or a "- glob"`,
	}
	if !slices.Equal(p.Notes, wantNotes) {
		t.Errorf("Notes =\n%s\nwant\n%s", strings.Join(p.Notes, "\n"), strings.Join(wantNotes, "\n"))
	}
}

func TestParsePatterns_NeverMatchingGlobsAndSubheadings(t *testing.T) {
	p := ParsePatterns("## Breaking\n- a/**\n- /cmd/**\n- docs/\n- a//b\n- ./x/*.go\n- ../y\n" +
		"### Sub\n- b/**\n")
	if !slices.Equal(p.Breaking, []string{"a/**"}) {
		t.Errorf("Breaking = %v, want only a/**", p.Breaking)
	}
	wantNotes := []string{
		`.watchtower/review-map.md: line 3: bad glob "/cmd/**"`,
		`.watchtower/review-map.md: line 4: bad glob "docs/"`,
		`.watchtower/review-map.md: line 5: bad glob "a//b"`,
		`.watchtower/review-map.md: line 6: bad glob "./x/*.go"`,
		`.watchtower/review-map.md: line 7: bad glob "../y"`,
		`.watchtower/review-map.md: line 8: unknown section "Sub"`,
	}
	if !slices.Equal(p.Notes, wantNotes) {
		t.Errorf("Notes =\n%s\nwant\n%s", strings.Join(p.Notes, "\n"), strings.Join(wantNotes, "\n"))
	}
}

func TestPatternsMatch(t *testing.T) {
	p := ParsePatterns("## Breaking\n- docs/inventory/**\n- **/*guard*_test.go\n- internal/prompts/defaults.go\n" +
		"## Significant\n- internal/tools/**\n- cmd/*.go\n" +
		"## Can skip\n- internal/db/testdata/schema_golden*\n- docs/**\n")
	cases := []struct {
		path  string
		level Level
		skip  bool
		ok    bool
	}{
		{"docs/inventory/review.md", Breaking, false, true},
		{"docs/inventory/deep/a.md", Breaking, false, true},
		{"internal/review/review_guard_test.go", Breaking, false, true},
		{"x_guard_test.go", Breaking, false, true},
		{"internal/prompts/defaults.go", Breaking, false, true},
		{"internal/tools/registry.go", Significant, false, true},
		{"cmd/root.go", Significant, false, true},
		{"cmd/sub/root.go", Normal, false, false},
		{"internal/db/testdata/schema_golden.sql", Normal, true, true},
		{"docs/guide/README.md", Normal, true, true},
		{"internal/x/a.go", Normal, false, false},
	}
	for _, c := range cases {
		level, skip, ok := p.Match(c.path)
		if level != c.level || skip != c.skip || ok != c.ok {
			t.Errorf("Match(%q) = (%v, %v, %v), want (%v, %v, %v)", c.path, level, skip, ok, c.level, c.skip, c.ok)
		}
	}
	many := Patterns{Breaking: []string{strings.Repeat("**/", 30) + "z"}}
	if _, _, ok := many.Match(strings.Repeat("a/", 40) + "y"); ok {
		t.Error("a many-** glob must not match a path without its last segment")
	}
	if _, _, ok := many.Match(strings.Repeat("a/", 40) + "z"); !ok {
		t.Error("a many-** glob must match a path ending in its last segment")
	}
	if _, _, ok := (Patterns{}).Match("a.go"); ok {
		t.Error("empty patterns must match nothing")
	}
}

func writeMap(t *testing.T, folder, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(folder, ".watchtower"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, ".watchtower", "review-map.md"), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLoadPatterns(t *testing.T) {
	t.Run("missing file is no note", func(t *testing.T) {
		p := LoadPatterns(t.TempDir())
		if len(p.Breaking)+len(p.Significant)+len(p.Skip)+len(p.Notes) != 0 {
			t.Errorf("got %+v", p)
		}
	})
	t.Run("reads the file", func(t *testing.T) {
		dir := t.TempDir()
		writeMap(t, dir, "## Breaking\n- docs/inventory/**\n")
		p := LoadPatterns(dir)
		if level, _, ok := p.Match("docs/inventory/a.md"); !ok || level != Breaking {
			t.Errorf("Match = %v %v, patterns %+v", level, ok, p)
		}
		if len(p.Notes) != 0 {
			t.Errorf("Notes = %v", p.Notes)
		}
	})
	t.Run("does not read review.md", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.MkdirAll(filepath.Join(dir, ".watchtower"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, ".watchtower", "review.md"), []byte("## Breaking\n- a/**\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if p := LoadPatterns(dir); len(p.Breaking) != 0 {
			t.Errorf("Breaking = %v", p.Breaking)
		}
	})
	refused := func(t *testing.T, dir, wantNote string) {
		t.Helper()
		p := LoadPatterns(dir)
		if len(p.Breaking)+len(p.Significant)+len(p.Skip) != 0 {
			t.Errorf("a refused file gave patterns %+v", p)
		}
		if !slices.Equal(p.Notes, []string{wantNote}) {
			t.Errorf("Notes = %v, want [%s]", p.Notes, wantNote)
		}
	}
	t.Run("symlinked file refused", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(t.TempDir(), "target.md")
		if err := os.WriteFile(target, []byte("## Breaking\n- a/**\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Join(dir, ".watchtower"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, filepath.Join(dir, ".watchtower", "review-map.md")); err != nil {
			t.Fatal(err)
		}
		refused(t, dir, ".watchtower/review-map.md: not a regular file")
	})
	t.Run("symlinked .watchtower refused", func(t *testing.T) {
		dir := t.TempDir()
		other := t.TempDir()
		writeMap(t, other, "## Breaking\n- a/**\n")
		if err := os.Symlink(filepath.Join(other, ".watchtower"), filepath.Join(dir, ".watchtower")); err != nil {
			t.Fatal(err)
		}
		refused(t, dir, ".watchtower/review-map.md: .watchtower is not a real directory")
	})
	t.Run("70 KB file refused", func(t *testing.T) {
		dir := t.TempDir()
		writeMap(t, dir, "## Breaking\n- a/**\n"+strings.Repeat("- b/**\n", 70*1024/7))
		refused(t, dir, ".watchtower/review-map.md: larger than 64 KB, not read")
	})
	t.Run("non UTF-8 refused", func(t *testing.T) {
		dir := t.TempDir()
		writeMap(t, dir, "## Breaking\n- a/\xff\n")
		refused(t, dir, ".watchtower/review-map.md: not UTF-8, not read")
	})
}

// This repository's own .watchtower/review-map.md (tech spec §2.4) parses
// whole — every line a heading or a glob, no note — and sorts its files.
func TestPatterns_ThisRepositorysFile(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	p := LoadPatterns(root)
	if len(p.Notes) > 0 || len(p.Breaking) == 0 {
		t.Fatalf("notes %v, breaking %v", p.Notes, p.Breaking)
	}
	for path, want := range map[string]Level{
		"docs/inventory/review.md":                Breaking,
		"internal/reviewdiff/guard_test.go":       Breaking,
		"cmd/slack_team_guard_test.go":            Breaking,
		"internal/prompts/defaults.go":            Breaking,
		"internal/db/schema.sql":                  Significant,
		"internal/tools/workbench_finish_gate.go": Significant,
		"cmd/workbench_review_map.go":             Significant,
	} {
		if level, skip, ok := p.Match(path); !ok || skip || level != want {
			t.Errorf("%s: level %v skip %v ok %v, want %v", path, level, skip, ok, want)
		}
	}
	for _, path := range []string{"WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift",
		"internal/db/testdata/schema_v73.golden", "WatchtowerKit/Sources/WatchtowerRelayProto/relay.pb.swift",
		"internal/hub/transport/relay/relayv1/relay.pb.go"} {
		if _, skip, ok := p.Match(path); !ok || !skip {
			t.Errorf("%s: not Can skip", path)
		}
	}
	if _, _, ok := p.Match("internal/reviewmap/map.go"); ok {
		t.Error("an ordinary file matched a pattern")
	}
}
