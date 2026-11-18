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

// credentialMarkerHits reports "path: marker" for every non-test .go file
// under root and every .swift file under root/swiftDirs that contains a
// marker. Directories named testdata, node_modules or vendor, or starting with
// ".", are skipped (nested worktrees live under .claude/worktrees, build
// output under .build).
func credentialMarkerHits(root string, swiftDirs []string) ([]string, error) {
	fsRoot, err := os.OpenRoot(root)
	if err != nil {
		return nil, err
	}
	defer func() { _ = fsRoot.Close() }()
	var hits []string
	scan := func(start string, want func(name string) bool) error {
		return filepath.WalkDir(start, func(path string, d fs.DirEntry, err error) error {
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
			if !want(name) {
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
	}
	isGo := func(name string) bool { return strings.HasSuffix(name, ".go") && !strings.HasSuffix(name, "_test.go") }
	if err := scan(root, isGo); err != nil {
		return nil, err
	}
	for _, dir := range swiftDirs {
		if err := scan(filepath.Join(root, dir), func(name string) bool { return strings.HasSuffix(name, ".swift") }); err != nil {
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
		"tools/t.go":                               "package tools // api/oauth/usage",
		"WatchtowerDesktop/Sources/App/a.swift":    "// find-generic-password",
		"internal/a/a_test.go":                     all,
		"internal/a/testdata/x.go":                 all,
		".claude/worktrees/w/internal/b.go":        all,
		"internal/.hidden/c.go":                    all,
		"node_modules/n/n.go":                      all,
		"WatchtowerDesktop/Tests/t.swift":          all,
		"WatchtowerDesktop/Sources/.build/x.swift": all,
		"WatchtowerDesktop/Sources/vendor/v.swift": all,
		"WatchtowerDesktop/Sources/App/notes.txt":  all,
	} {
		p := filepath.Join(synthetic, filepath.FromSlash(rel))
		require.NoError(t, os.MkdirAll(filepath.Dir(p), 0o700))
		require.NoError(t, os.WriteFile(p, []byte(body), 0o600))
	}
	hits, err := credentialMarkerHits(synthetic, []string{"WatchtowerDesktop/Sources"})
	require.NoError(t, err)
	want := []string{"WatchtowerDesktop/Sources/App/a.swift: find-generic-password", "tools/t.go: api/oauth/usage"}
	for _, m := range credentialMarkers {
		want = append(want, "internal/a/a.go: "+m)
	}
	sort.Strings(want)
	require.Equal(t, want, hits, "the scan must see every marker in ordinary source and nothing in skipped places")

	root := moduleRoot(t)
	for _, dir := range []string{"cmd", "internal"} {
		info, err := os.Stat(filepath.Join(root, dir))
		require.NoError(t, err, "the module must have %s/ — the scan would prove nothing", dir)
		require.True(t, info.IsDir())
	}
	swiftDirs, err := filepath.Glob(filepath.Join(root, "*", "Sources"))
	require.NoError(t, err)
	for i, dir := range swiftDirs {
		swiftDirs[i], err = filepath.Rel(root, dir)
		require.NoError(t, err)
	}
	for _, dir := range []string{"WatchtowerDesktop/Sources", "WatchtowerKit/Sources", "WatchtowerMobile/Sources", "WatchtowerChat/Sources"} {
		require.Contains(t, swiftDirs, filepath.FromSlash(dir))
	}
	hits, err = credentialMarkerHits(root, swiftDirs)
	require.NoError(t, err)
	assert.Empty(t, hits, "production source names a Claude credential store or the token usage endpoint")
}
