package planusage

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// credentialMarkers name the Claude Code credential stores and the token
// endpoint. Production source must contain none of them.
var credentialMarkers = []string{
	"Claude Code-credentials",
	"claudeAiOauth",
	".credentials.json",
	"api/oauth/usage",
	"oauth-2025-04-20",
	"find-generic-password",
}

// credentialMarkerHits reports "path: marker" for every non-test .go file and
// every .swift file under root/dirs that contains a marker. Directories named
// testdata, node_modules or vendor, or starting with ".", are skipped (nested
// worktrees live under .claude/worktrees, build output under .build).
func credentialMarkerHits(root string, dirs []string) ([]string, error) {
	fsRoot, err := os.OpenRoot(root)
	if err != nil {
		return nil, err
	}
	defer func() { _ = fsRoot.Close() }()
	var hits []string
	for _, dir := range dirs {
		start := filepath.Join(root, dir)
		if _, err := os.Stat(start); os.IsNotExist(err) {
			continue
		}
		err := filepath.WalkDir(start, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			name := d.Name()
			if d.IsDir() {
				if path != start && (name == "testdata" || name == "node_modules" || name == "vendor" || strings.HasPrefix(name, ".")) {
					return filepath.SkipDir
				}
				return nil
			}
			goSource := strings.HasSuffix(name, ".go") && !strings.HasSuffix(name, "_test.go")
			if !goSource && !strings.HasSuffix(name, ".swift") {
				return nil
			}
			rel, err := filepath.Rel(root, path)
			if err != nil {
				return err
			}
			b, err := fsRoot.ReadFile(rel)
			if err != nil {
				return err
			}
			for _, m := range credentialMarkers {
				if strings.Contains(string(b), m) {
					hits = append(hits, filepath.ToSlash(rel)+": "+m)
				}
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	sort.Strings(hits)
	return hits, nil
}

func moduleRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	require.NoError(t, err)
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		require.NotEqual(t, dir, parent, "go.mod not found")
		dir = parent
	}
}

// PLANUSAGE-01 guard: no production source reads Claude credentials or calls
// the token usage endpoint. The walker first proves it sees a hit.
func TestPlanUsage01_NoClaudeCredentialReader(t *testing.T) {
	synthetic := t.TempDir()
	all := strings.Join(credentialMarkers, "\n")
	for rel, body := range map[string]string{
		"internal/a/a.go":                          "package a\n/*\n" + all + "\n*/\n",
		"internal/a/a_test.go":                     all,
		"internal/a/testdata/x.go":                 all,
		".claude/worktrees/w/internal/b.go":        all,
		"internal/.hidden/c.go":                    all,
		"WatchtowerDesktop/.build/x.swift":         all,
		"WatchtowerDesktop/Sources/vendor/v.swift": all,
	} {
		p := filepath.Join(synthetic, filepath.FromSlash(rel))
		require.NoError(t, os.MkdirAll(filepath.Dir(p), 0o700))
		require.NoError(t, os.WriteFile(p, []byte(body), 0o600))
	}
	hits, err := credentialMarkerHits(synthetic, []string{"."})
	require.NoError(t, err)
	want := make([]string, 0, len(credentialMarkers))
	for _, m := range credentialMarkers {
		want = append(want, "internal/a/a.go: "+m)
	}
	sort.Strings(want)
	require.Equal(t, want, hits, "the scan must see every marker in an ordinary package and nothing in skipped places")

	hits, err = credentialMarkerHits(moduleRoot(t), []string{"cmd", "internal", "WatchtowerDesktop/Sources", "WatchtowerKit/Sources", "WatchtowerMobile/Sources"})
	require.NoError(t, err)
	assert.Empty(t, hits, "production source names a Claude credential store or the token usage endpoint")
}
