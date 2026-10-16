package reviewdiff

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func lensIDs(ls []Lens) []string {
	ids := make([]string, 0, len(ls))
	for _, l := range ls {
		ids = append(ids, l.ID)
	}
	return ids
}

func findLens(t *testing.T, ls []Lens, id string) Lens {
	t.Helper()
	for _, l := range ls {
		if l.ID == id {
			return l
		}
	}
	t.Fatalf("lens %q not found", id)
	return Lens{}
}

func TestParseLenses_BuiltinsOnly(t *testing.T) {
	ls, notes := ParseLenses(nil)
	assert.Empty(t, notes)
	assert.Equal(t, []string{"correctness", "tests", "security", "simplicity", "house_rules"}, lensIDs(ls))
	counts := []int{}
	for _, l := range ls {
		assert.True(t, l.Builtin)
		counts = append(counts, len(l.Items))
	}
	assert.Equal(t, []int{5, 4, 4, 4, 0}, counts)
	q := "Does the change do what the intent asks, including its edge cases?"
	assert.Equal(t, ItemKey(q), ls[0].Items[0].Key)
	assert.Equal(t, q, ls[0].Items[0].Text)
	assert.Regexp(t, `^[0-9a-f]{16}$`, ls[0].Items[0].Key)
}

func TestParseLenses_ExtendsCaseInsensitivelyAndAddsNew(t *testing.T) {
	ls, notes := ParseLenses([]byte("## tests\n- Is there a fuzz test?\n## House Rules\n- Git runs only in Go.\n## Docs\n- Is the feature note updated?\n"))
	assert.Empty(t, notes)
	require.Len(t, ls, 6)
	tests := findLens(t, ls, "tests")
	require.Len(t, tests.Items, 5)
	assert.Equal(t, "Is there a fuzz test?", tests.Items[4].Text)
	assert.Equal(t, "Tests", tests.Name)
	assert.Len(t, findLens(t, ls, "house_rules").Items, 1)
	assert.Equal(t, "docs", ls[5].ID)
	assert.Equal(t, "Docs", ls[5].Name)
	assert.False(t, ls[5].Builtin)
	assert.Len(t, ls[5].Items, 1)
}

func TestParseLenses_SkipsAndReportsBadLines(t *testing.T) {
	ls, notes := ParseLenses([]byte("intro\n## Tests\n- a\n* b\n\n- a\n- \n"))
	bad := `not a "## lens" heading or a "- question"`
	require.Len(t, notes, 3)
	assert.Equal(t, "line 1: "+bad, notes[0])
	assert.Equal(t, "line 4: "+bad, notes[1])
	assert.Contains(t, notes[2], "line 7")
	tests := findLens(t, ls, "tests")
	require.Len(t, tests.Items, 5)
	assert.Equal(t, "a", tests.Items[4].Text)
}

func TestLensID(t *testing.T) {
	assert.Equal(t, "house_rules", LensID("House rules"))
	assert.Equal(t, "api_cli", LensID("  API / CLI  "))
	assert.Equal(t, "", LensID("Тесты"))

	ls, notes := ParseLenses([]byte("## Тесты\n- x\n## Docs\n- y\n"))
	assert.Equal(t, []string{"line 1: lens name has no latin letters or digits"}, notes)
	assert.Len(t, ls, 6)
	assert.Equal(t, "docs", ls[5].ID)
	assert.Len(t, ls[5].Items, 1)
}

func TestLoadLenses_RefusesUnsafeFiles(t *testing.T) {
	writeReview := func(t *testing.T, dir string, data []byte) string {
		t.Helper()
		require.NoError(t, os.MkdirAll(filepath.Join(dir, ".watchtower"), 0o755))
		p := filepath.Join(dir, ".watchtower", "review.md")
		require.NoError(t, os.WriteFile(p, data, 0o644))
		return p
	}
	cases := []struct {
		name     string
		setup    func(t *testing.T, dir string)
		wantNote string // "" = no note
		merged   bool
	}{
		{"no .watchtower", func(t *testing.T, dir string) {}, "", false},
		{"symlinked file", func(t *testing.T, dir string) {
			target := filepath.Join(dir, "real.md")
			require.NoError(t, os.WriteFile(target, []byte("## Docs\n- q\n"), 0o644))
			require.NoError(t, os.MkdirAll(filepath.Join(dir, ".watchtower"), 0o755))
			require.NoError(t, os.Symlink(target, filepath.Join(dir, ".watchtower", "review.md")))
		}, "not a regular file", false},
		{"symlinked dir", func(t *testing.T, dir string) {
			other := filepath.Join(dir, "other")
			require.NoError(t, os.MkdirAll(other, 0o755))
			require.NoError(t, os.WriteFile(filepath.Join(other, "review.md"), []byte("## Docs\n- q\n"), 0o644))
			require.NoError(t, os.Symlink(other, filepath.Join(dir, ".watchtower")))
		}, ".watchtower", false},
		{"fifo", func(t *testing.T, dir string) {
			require.NoError(t, os.MkdirAll(filepath.Join(dir, ".watchtower"), 0o755))
			require.NoError(t, syscall.Mkfifo(filepath.Join(dir, ".watchtower", "review.md"), 0o644))
		}, "not a regular file", false},
		{"too large", func(t *testing.T, dir string) {
			writeReview(t, dir, []byte(strings.Repeat("x", MaxLensFileBytes+1)))
		}, "larger than 64 KB", false},
		{"not utf-8", func(t *testing.T, dir string) {
			writeReview(t, dir, []byte("## Docs\n- \xff\xfe\n"))
		}, "not UTF-8", false},
		{"valid", func(t *testing.T, dir string) {
			writeReview(t, dir, []byte("## Docs\n- q\n"))
		}, "", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			tc.setup(t, dir)
			type result struct {
				ls    []Lens
				notes []string
			}
			done := make(chan result, 1)
			go func() {
				ls, notes := LoadLenses(dir)
				done <- result{ls, notes}
			}()
			var r result
			select {
			case r = <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("LoadLenses did not return")
			}
			if tc.wantNote == "" {
				assert.Empty(t, r.notes)
			} else {
				require.Len(t, r.notes, 1)
				assert.True(t, strings.HasPrefix(r.notes[0], ".watchtower/review.md: "), r.notes[0])
				assert.Contains(t, r.notes[0], tc.wantNote)
			}
			if tc.merged {
				require.Len(t, r.ls, 6)
				assert.Equal(t, "docs", r.ls[5].ID)
			} else {
				assert.Equal(t, []string{"correctness", "tests", "security", "simplicity", "house_rules"}, lensIDs(r.ls))
			}
		})
	}
}
